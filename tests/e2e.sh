#!/usr/bin/env bash
# Сквозная проверка: установка с нуля -> очистка -> диагностика -> вход администратора -> откат очистки.
# Запускается из корня проекта (в CI и локально; перед этим окружение должно быть пустым):
#   EDITION=standard DB=mysql-8.4 PHP=8.3 bash tests/e2e.sh
# EDITION: start|standard|small_business|business, DB: mysql-8.4|mysql-8.0|mariadb-11.4|mariadb-10.11, PHP: 8.3|8.2
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

EDITION=${EDITION:-standard}; DB=${DB:-mysql-8.4}; PHPV=${PHP:-8.3}
HTTP_PORT=${HTTP_PORT:-8080}; HTTPS_PORT=${HTTPS_PORT:-8443}
LOG=$(mktemp)
FAILS=0
ok()   { echo "  [ok]   $1"; }
fail() { echo "  [FAIL] $1"; FAILS=$((FAILS+1)); }

echo "== $EDITION / $DB / PHP $PHPV =="
if ./bx setup --defaults --edition "$EDITION" --db "$DB" --php "$PHPV" --install --clean \
     --http-port "$HTTP_PORT" --https-port "$HTTPS_PORT" 2>&1 | tee "$LOG"; then ok "setup --install --clean"; else fail "setup --install --clean"; fi

mods=$(./bx sql "select group_concat(ID order by ID) from b_module" 2>/dev/null | sed -n 4p | tr -d '| ')
[ "$mods" = "fileman,main,security,ui" ] && ok "после очистки остались модули: $mods" || fail "модули после очистки: ${mods:-пусто}"

[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$HTTP_PORT/")" = 200 ] && ok "сайт отвечает 200" || fail "сайт не отвечает 200"
[ "$(curl -s "http://localhost:$HTTP_PORT/" | grep -c CurrentStepID)" = 0 ] && ok "на главной нет мастера установки" || fail "на главной остался мастер"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$HTTP_PORT/bitrix/admin/")" = 200 ] && ok "админка отвечает 200" || fail "админка не отвечает 200"
[ "$(curl -sk -o /dev/null -w '%{http_code}' "https://localhost:$HTTPS_PORT/bitrix/admin/")" = 200 ] && ok "HTTPS отвечает 200" || fail "HTTPS не отвечает 200"

if ./bx doctor >/tmp/doctor.out 2>&1; then ok "bx doctor без замечаний"; else fail "bx doctor:"; grep -a '\[!!\]' /tmp/doctor.out | sed 's/^/         /'; fi

# вход администратора через API Битрикса (пароль — последняя строка «Пароль:» в выводе мастера)
AP=$(grep -a 'Пароль:' "$LOG" | tail -1 | awk '{print $2}')
r=$(docker compose exec -T -e AP="$AP" php php 2>&1 <<'PHP' | grep -ao 'LOGIN_[A-Z]*'
<?php
$_SERVER['DOCUMENT_ROOT']='/var/www/html'; define('NOT_CHECK_PERMISSIONS',true); define('NO_KEEP_STATISTIC',true); define('NO_AGENT_CHECK',true);
require '/var/www/html/bitrix/modules/main/include/prolog_before.php';
global $USER; $ok = $USER->Login('admin', getenv('AP'), 'N'); echo ($ok === true && $USER->IsAdmin()) ? 'LOGIN_OK' : 'LOGIN_FAIL';
PHP
)
[ "$r" = LOGIN_OK ] && ok "вход администратора через API" || fail "вход администратора: ${r:-нет ответа}"

# откат очистки одной командой
snap=$(./bx backup list | grep before-clean | head -1 | awk '{print $1}')
if [ -n "$snap" ]; then
  if echo yes | ./bx restore "$snap" >/tmp/restore.out 2>&1; then
    n=$(./bx sql "select count(*) from b_module" 2>/dev/null | sed -n 4p | tr -d '| ')
    if [ "${n:-0}" -gt 4 ] && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$HTTP_PORT/")" = 200 ]; then ok "откат: модулей $n, сайт 200"; else fail "откат: модулей ${n:-?}"; fi
  else fail "bx restore завершился с ошибкой"; tail -5 /tmp/restore.out | sed 's/^/         /'; fi
else fail "снимок before-clean не найден"; fi

echo
if [ "$FAILS" = 0 ]; then echo "Всё в порядке: $EDITION / $DB / PHP $PHPV"; else echo "Провалено проверок: $FAILS"; docker compose logs --tail 60 2>&1 | tail -80; fi
rm -f "$LOG"
[ "$FAILS" = 0 ]

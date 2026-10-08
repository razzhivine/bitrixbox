#!/usr/bin/env bash
# Сквозная проверка переноса сайта: «боевой» сайт → резервная копия Битрикса → bx import (+ обезличивание);
# затем bx import по SSH (с прокси для upload) и bx pull. Запускается из корня проекта, окружение должно быть пустым:
#   bash tests/import.sh
# «Боевой» сайт ставится в соседнюю папку ../bitrixbox-src (проект bxsrc), SSH-сервер — контейнер bxbox-sshsrv.
# Порты: HTTP_PORT … для проверяемого окружения, SRC_HTTP_PORT … для «боевого», SSH_PORT (по умолчанию 2222).
# shellcheck disable=SC2034  # переменные проверок используются внутри check '…' (через eval)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
SRC=$(dirname "$ROOT")/bitrixbox-src
WORK=$(mktemp -d)

HTTP_PORT=${HTTP_PORT:-8080}; HTTPS_PORT=${HTTPS_PORT:-8443}
DB_PORT=${DB_PORT:-3306}; MAIL_PORT=${MAIL_PORT:-8025}; ADMINER_PORT=${ADMINER_PORT:-8081}
SRC_HTTP_PORT=${SRC_HTTP_PORT:-18080}; SSH_PORT=${SSH_PORT:-2222}
FAILS=0
ok()   { echo "  [ok]   $1"; }
fail() { echo "  [FAIL] $1"; FAILS=$((FAILS+1)); }
check() { if eval "$2"; then ok "$1"; else fail "$1"; fi; }
src()  { (cd "$SRC" && "$@"); }
sql1() { ./bx sql "$1" 2>/dev/null | sed -n 4p | sed 's/^| *//; s/ *|$//'; }
login() { # login <логин> <пароль> → LOGIN_OK / LOGIN_FAIL
  docker compose exec -T -e L="$1" -e P="$2" php php 2>&1 <<'PHP' | grep -ao 'LOGIN_[A-Z]*' | tail -1
<?php
$_SERVER['DOCUMENT_ROOT']='/var/www/html'; define('NOT_CHECK_PERMISSIONS',true); define('NO_KEEP_STATISTIC',true); define('NO_AGENT_CHECK',true);
require '/var/www/html/bitrix/modules/main/include/prolog_before.php';
global $USER; $ok = $USER->Login(getenv('L'), getenv('P'), 'N'); echo ($ok === true && $USER->IsAdmin()) ? 'LOGIN_OK' : 'LOGIN_FAIL';
PHP
}
cleanup() {
  docker rm -f bxbox-sshsrv >/dev/null 2>&1
  [ -d "$SRC" ] && (cd "$SRC" && docker compose down -v >/dev/null 2>&1)
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== «Боевой» сайт =="
rm -rf "$SRC"; mkdir -p "$SRC"
tar -C "$ROOT" --exclude=./.git --exclude=./.env --exclude=./backups -cf - . | tar -C "$SRC" -xf -
if src ./bx setup --defaults --edition standard --project bxsrc --no-https --install \
     --http-port "$SRC_HTTP_PORT" --https-port $((SRC_HTTP_PORT+1)) --db-port $((DB_PORT+10000)) \
     --mail-port $((MAIL_PORT+10000)) --adminer-port $((ADMINER_PORT+10000)) >"$WORK/src.log" 2>&1; then ok "установлен"
else fail "установка «боевого» сайта"; tail -20 "$WORK/src.log"; exit 1; fi

# Данные, по которым видно, что перенос и обезличивание сработали
mkdir -p "$SRC/local/php_interface" && echo '<?php // marker-local' > "$SRC/local/php_interface/init.php"
src docker compose exec -T -u www-data php php <<'PHP' >/dev/null
<?php
$_SERVER['DOCUMENT_ROOT']='/var/www/html'; define('NOT_CHECK_PERMISSIONS',true); define('NO_AGENT_CHECK',true);
require '/var/www/html/bitrix/modules/main/include/prolog_before.php';
$u = new CUser;
$u->Add(['LOGIN'=>'ivan@mail.ru','EMAIL'=>'ivan@mail.ru','NAME'=>'Иван','LAST_NAME'=>'Петров','PERSONAL_PHONE'=>'+79161234567',
         'PASSWORD'=>'Secret123!x','CONFIRM_PASSWORD'=>'Secret123!x','ACTIVE'=>'Y','GROUP_ID'=>[2]]);
COption::SetOptionString('main', 'server_name', 'shop.example.ru');
COption::SetOptionString('main', 'bxbox_marker', 'v1');
// резервная копия: сжатая, частями по 50 МБ (как из админки, только мельче — чтобы проверить склейку частей)
COption::SetOptionInt('main', 'dump_use_compression_auto', 1);
COption::SetOptionInt('main', 'dump_archive_size_limit_auto', 50 * 1024 * 1024);
PHP
src docker compose exec -T php sh -c 'mkdir -p /var/www/html/upload/marker && echo marker-upload > /var/www/html/upload/marker/m.txt && chown -R 33:33 /var/www/html/upload/marker'
src docker compose exec -T -u www-data php php -d short_open_tag=1 /var/www/html/bitrix/modules/main/tools/backup.php >"$WORK/backup.log" 2>&1
src docker compose exec -T php sh -c 'cd /var/www/html/bitrix/backup && tar cf - *.tar.gz*' | tar -C "$WORK" -xf -
src docker compose exec -T php sh -c 'rm -f /var/www/html/bitrix/backup/*.tar.gz*'
parts=$(ls "$WORK"/*.tar.gz* 2>/dev/null | wc -l | tr -d ' ')
check "резервная копия Битрикса: частей $parts" '[ "$parts" -ge 2 ]'

echo
echo "== bx import <архив> --anonymize =="
ARCH=$(ls "$WORK"/*.tar.gz | head -1)
./bx import "$ARCH" --anonymize --http-port "$HTTP_PORT" --https-port "$HTTPS_PORT" --db-port "$DB_PORT" \
  --mail-port "$MAIL_PORT" --adminer-port "$ADMINER_PORT" 2>&1 | tee "$WORK/import1.log" | grep -E '^(==|  -|Готово|Вход|ОШИБКА)'
check "импорт завершился" 'grep -q "^Готово" "$WORK/import1.log"'
check "главная 200" '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$HTTP_PORT/")" = 200 ]'
check "админка 200" '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$HTTP_PORT/bitrix/admin/")" = 200 ]'
check "данные перенесены (bxbox_marker=v1)" '[ "$(sql1 "select VALUE from b_option where NAME=\"bxbox_marker\"")" = v1 ]'
check "local/ перенесена" 'grep -q marker-local local/php_interface/init.php'
check "upload перенесён" '[ "$(curl -s "http://localhost:$HTTP_PORT/upload/marker/m.txt")" = marker-upload ]'
check "адрес сайта заменён на localhost" '[ "$(sql1 "select VALUE from b_option where MODULE_ID=\"main\" and NAME=\"server_name\"")" = "localhost:$HTTP_PORT" ]'
check "дамп удалён из bitrix/backup" '! docker compose exec -T php sh -c "ls /var/www/html/bitrix/backup/*.sql" >/dev/null 2>&1'
check "bitrix/backup закрыт в nginx" '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$HTTP_PORT/bitrix/backup/")" = 403 ]'
check "почта обезличена" '[ "$(sql1 "select count(*) from b_user where EMAIL not like \"%@example.test\"")" = 0 ]'
check "логин-почта заменён" '[ "$(sql1 "select count(*) from b_user where LOGIN like \"%@%\"")" = 0 ]'
check "телефоны очищены" '[ "$(sql1 "select count(*) from b_user where PERSONAL_PHONE<>\"\"")" = 0 ]'
AL=$(sed -n 's/.*логин: \([^ ]*\) .*/\1/p' "$WORK/import1.log" | tail -1); AP=$(sed -n 's/.*пароль: \([^ ]*\).*/\1/p' "$WORK/import1.log" | tail -1)
check "вход администратора с новым паролем ($AL)" '[ "$(login "$AL" "$AP")" = LOGIN_OK ]'
check "старый пароль не действует" '[ "$(login ivan@mail.ru "Secret123!x")" != LOGIN_OK ]'
if ./bx doctor >"$WORK/doctor.out" 2>&1; then ok "bx doctor без замечаний"; else fail "bx doctor:"; grep -a '\[!!\]' "$WORK/doctor.out" | sed 's/^/         /'; fi

echo
echo "== bx import по SSH + bx upload-proxy =="
ssh-keygen -q -t ed25519 -N '' -f "$WORK/key"
cat > "$WORK/Dockerfile" <<'EOF'
FROM bxsrc-php
RUN apt-get update -qq && apt-get install -y -qq openssh-server default-mysql-client >/dev/null && mkdir -p /run/sshd /root/.ssh
COPY key.pub /root/.ssh/authorized_keys
RUN chmod 600 /root/.ssh/authorized_keys
CMD ["/usr/sbin/sshd", "-D", "-e"]
EOF
docker build -q -t bxbox-sshsrv "$WORK" >/dev/null
docker run -d --name bxbox-sshsrv --network bxsrc_default -v bxsrc_www:/var/www/html -v "$SRC/local:/var/www/html/local" \
  -p "127.0.0.1:$SSH_PORT:22" bxbox-sshsrv >/dev/null
# «боевой» nginx виден из проверяемого окружения под именем bxsrc-web (как настоящий сайт в интернете)
docker network connect --alias bxsrc-web "$(docker compose ps -q nginx | xargs docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')" bxsrc-nginx-1
for _ in $(seq 1 15); do nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null && break; sleep 1; done
src ./bx sql "update b_option set VALUE='v2' where NAME='bxbox_marker'" >/dev/null
SSHO="-i $WORK/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
./bx import "ssh://root@127.0.0.1:$SSH_PORT/var/www/html" --ssh-opts "$SSHO" --upload-proxy http://bxsrc-web \
  --admin-password Test12345 --yes 2>&1 | tee "$WORK/import2.log" | grep -E '^(==|  -|Готово|Вход|ОШИБКА)'
check "импорт по SSH завершился" 'grep -q "^Готово" "$WORK/import2.log"'
check "снимок перед импортом" 'ls -d backups/snapshot-*-before-import >/dev/null 2>&1'
check "свежие данные с сервера (v2)" '[ "$(sql1 "select VALUE from b_option where NAME=\"bxbox_marker\"")" = v2 ]'
check "без --anonymize почта осталась" '[ "$(sql1 "select count(*) from b_user where EMAIL=\"ivan@mail.ru\"")" = 1 ]'
check "вход с --admin-password" '[ "$(login admin Test12345)" = LOGIN_OK ]'
check "upload не скачан" '! docker compose exec -T php test -f /var/www/html/upload/marker/m.txt'
check "upload отдаётся с «боевого» сайта" '[ "$(curl -s "http://localhost:$HTTP_PORT/upload/marker/m.txt")" = marker-upload ]'
check "PHP в upload закрыт" '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$HTTP_PORT/upload/x.php")" = 403 ]'

echo
echo "== bx pull --files =="
src ./bx sql "update b_option set VALUE='v3' where NAME='bxbox_marker'" >/dev/null
src docker compose exec -T php sh -c 'echo "<?php echo \"pulled\";" > /var/www/html/pulltest.php && chown 33:33 /var/www/html/pulltest.php'
echo '<?php // local-change' > local/php_interface/init.php
./bx pull --files --yes > "$WORK/pull.log" 2>&1
check "pull завершился" 'grep -q "^Готово" "$WORK/pull.log"'
check "база обновлена (v3)" '[ "$(sql1 "select VALUE from b_option where NAME=\"bxbox_marker\"")" = v3 ]'
check "новый файл приехал" '[ "$(curl -s "http://localhost:$HTTP_PORT/pulltest.php")" = pulled ]'
check "local/ не затёрта" 'grep -q local-change local/php_interface/init.php'
check "подключение к базе осталось локальным" 'docker compose exec -T php grep -q "=> .db." /var/www/html/bitrix/.settings.php'

echo
echo "== bx upload-proxy --save / off =="
./bx upload-proxy http://bxsrc-web --save >/dev/null
curl -s -o /dev/null "http://localhost:$HTTP_PORT/upload/marker/m.txt"
check "файл сохранён локально" 'docker compose exec -T php test -f /var/www/html/upload/marker/m.txt'
check "сохранённый файл доступен PHP на запись" 'docker compose exec -T -u www-data php sh -c "touch /var/www/html/upload/marker/w"'
./bx upload-proxy off >/dev/null
check "после off файл отдаётся локально" '[ "$(curl -s "http://localhost:$HTTP_PORT/upload/marker/m.txt")" = marker-upload ]'
check "после off недостающее — 404" '[ "$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$HTTP_PORT/upload/nope.jpg")" = 404 ]'

echo
[ "$FAILS" = 0 ] && echo "Все проверки пройдены" || echo "Ошибок: $FAILS"
exit "$FAILS"

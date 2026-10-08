#!/usr/bin/env bash
# Сквозная проверка миграций: чистый Битрикс -> обязательные модули -> bx migrate up/down.
# Запускается из корня проекта на ПУСТОМ окружении:  bash tests/migrate.sh
# Что проверяет: bx clean оставляет обязательный модуль и sprint.migration; bx migrate install ставит модуль;
# up создаёт инфоблок (и делает снимок), повторный up ничего не делает, down убирает инфоблок, modules sync возвращает модуль.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

HTTP_PORT=${HTTP_PORT:-8080}; HTTPS_PORT=${HTTPS_PORT:-8443}
DB_PORT=${DB_PORT:-3306}; MAIL_PORT=${MAIL_PORT:-8025}; ADMINER_PORT=${ADMINER_PORT:-8081}
FAILS=0
ok()   { echo "  [ok]   $1"; }
fail() { echo "  [FAIL] $1"; FAILS=$((FAILS+1)); }
q()    { ./bx sql "$1" 2>/dev/null | sed -n '4,$p' | grep -v '^+' | tr -d '| '; }

# «проект»: обязательный модуль и готовая миграция (как после git clone проекта)
mkdir -p local/php_interface/migrations && chmod -R a+rwx local
printf '# обязательные модули проекта\niblock\n' > local/bx-modules.txt
cat > local/php_interface/migrations/Version20260101000000.php <<'PHP'
<?php

namespace Sprint\Migration;

class Version20260101000000 extends Version
{
    protected $author = "admin";
    protected $description = "Тест BitrixBox: тип инфоблоков и инфоблок";
    protected $moduleVersion = "5.15.1";

    public function up()
    {
        $helper = $this->getHelperManager();
        $helper->Iblock()->saveIblockType([
            'ID' => 'bxtest',
            'SECTIONS' => 'Y',
            'LANG' => ['ru' => ['NAME' => 'Тест'], 'en' => ['NAME' => 'Test']],
        ]);
        $helper->Iblock()->saveIblock([
            'IBLOCK_TYPE_ID' => 'bxtest',
            'CODE' => 'bx_test',
            'NAME' => 'Тестовый инфоблок',
            'LID' => 's1',
            'GROUP_ID' => ['2' => 'R'],
        ]);
    }

    public function down()
    {
        $helper = $this->getHelperManager();
        $helper->Iblock()->deleteIblockIfExists('bx_test');
        $helper->Iblock()->deleteIblockTypeIfExists('bxtest');
    }
}
PHP

echo "== установка с очисткой =="
./bx setup --defaults --edition standard --install --skip-updates --clean --no-https \
  --http-port "$HTTP_PORT" --https-port "$HTTPS_PORT" --db-port "$DB_PORT" --mail-port "$MAIL_PORT" --adminer-port "$ADMINER_PORT" >/tmp/mig-setup.log 2>&1 && ok "setup --install --clean" || { fail "setup --install --clean"; tail -20 /tmp/mig-setup.log; }

mods=$(q "select group_concat(ID order by ID) from b_module")
[ "$mods" = "fileman,iblock,main,security,ui" ] && ok "после очистки остались защищённые и обязательные модули: $mods" || fail "модули после очистки: ${mods:-пусто} (ожидались fileman,iblock,main,security,ui)"

echo "== bx migrate install =="
./bx migrate install >/tmp/mig-install.log 2>&1 && ok "bx migrate install" || { fail "bx migrate install"; tail -10 /tmp/mig-install.log; }
[ "$(q "select count(*) from b_module where ID='sprint.migration'")" = 1 ] && ok "модуль sprint.migration установлен" || fail "модуль sprint.migration не установлен"
[ -d local/php_interface/migrations ] && ok "папка миграций на диске: local/php_interface/migrations" || fail "нет папки миграций"

echo "== bx migrate up / down =="
./bx migrate ls --new 2>&1 | grep -q 'Version20260101000000' && ok "миграция видна как новая" || fail "миграция не видна в ls --new"
if ./bx migrate up >/tmp/mig-up.log 2>&1; then ok "bx migrate up"; else fail "bx migrate up"; tail -15 /tmp/mig-up.log; fi
[ "$(q "select count(*) from b_iblock where CODE='bx_test'")" = 1 ] && ok "инфоблок создан миграцией" || fail "инфоблок не создан"
./bx backup list | grep -q before-migrate && ok "перед up сделан снимок before-migrate" || fail "снимок before-migrate не найден"
./bx migrate up 2>&1 | grep -q 'Новых миграций нет' && ok "повторный up ничего не делает" || fail "повторный up применил что-то лишнее"
./bx migrate down >/tmp/mig-down.log 2>&1 && ok "bx migrate down" || { fail "bx migrate down"; tail -10 /tmp/mig-down.log; }
[ "$(q "select count(*) from b_iblock where CODE='bx_test'")" = 0 ] && ok "инфоблок убран откатом" || fail "инфоблок остался после down"

echo "== обязательные модули =="
./bx modules uninstall iblock >/dev/null 2>&1
[ "$(q "select count(*) from b_module where ID='iblock'")" = 0 ] && ok "iblock удалён для проверки sync" || fail "iblock не удалился"
./bx modules sync >/tmp/mig-sync.log 2>&1 && ok "bx modules sync" || { fail "bx modules sync"; tail -5 /tmp/mig-sync.log; }
[ "$(q "select count(*) from b_module where ID='iblock'")" = 1 ] && ok "обязательный модуль возвращён" || fail "iblock не вернулся"
./bx migrate up >/tmp/mig-up2.log 2>&1 && [ "$(q "select count(*) from b_iblock where CODE='bx_test'")" = 1 ] && ok "up после отката создаёт инфоблок заново" || { fail "up после отката"; tail -10 /tmp/mig-up2.log; }

echo
if [ "$FAILS" = 0 ]; then echo "Всё в порядке: миграции работают"; else echo "Провалено проверок: $FAILS"; docker compose logs --tail 40 2>&1 | tail -50; fi
[ "$FAILS" = 0 ]

#!/usr/bin/env bash
# Сквозная проверка миграций: чистый Битрикс -> обязательные модули -> bx migrate install/status/up/redo/down.
# Запускается из корня проекта на ПУСТОМ окружении:  bash tests/migrate.sh
# Порты можно сменить: HTTP_PORT, HTTPS_PORT, DB_PORT, MAIL_PORT, ADMINER_PORT (если стандартные заняты).
#
# Что проверяет:
#  - bx clean оставляет обязательные модули проекта и sprint.migration; bx migrate install ставит модуль;
#  - три миграции разной сложности (инфоблок со свойствами, разделом и элементом; hl-блок; группа и настройка):
#    up создаёт всё, повторный up ничего не делает, redo пересоздаёт, down убирает всё, включая таблицу hl-блока;
#  - перед up делается снимок, bx migrate status показывает верные счётчики;
#  - bx modules sync возвращает удалённый обязательный модуль, и up после этого снова работает.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

HTTP_PORT=${HTTP_PORT:-8080}; HTTPS_PORT=${HTTPS_PORT:-8443}
DB_PORT=${DB_PORT:-3306}; MAIL_PORT=${MAIL_PORT:-8025}; ADMINER_PORT=${ADMINER_PORT:-8081}
FAILS=0
ok()   { echo "  [ok]   $1"; }
fail() { echo "  [FAIL] $1"; FAILS=$((FAILS+1)); }
q()    { ./bx sql "$1" 2>/dev/null | sed -n '4,$p' | grep -v '^+' | tr -d '| '; }
check() { # check "описание" "ожидаемое" "$(q ...)"
  [ "$3" = "$2" ] && ok "$1" || fail "$1: получено «$3», ожидалось «$2»"
}

# «проект»: обязательные модули и готовые миграции (как после git clone проекта)
MIG=local/php_interface/migrations
mkdir -p $MIG && chmod -R a+rwx local
printf '# обязательные модули проекта\niblock\nhighloadblock\n' > local/bx-modules.txt

cat > $MIG/Version20260101000001.php <<'PHP'
<?php

namespace Sprint\Migration;

class Version20260101000001 extends Version
{
    protected $author = "admin";
    protected $description = "Каталог: тип, инфоблок, свойства, раздел, элемент";
    protected $moduleVersion = "5.15.1";

    public function up()
    {
        $h = $this->getHelperManager()->Iblock();
        $h->saveIblockType(['ID' => 'bxshop', 'SECTIONS' => 'Y', 'LANG' => ['ru' => ['NAME' => 'Магазин'], 'en' => ['NAME' => 'Shop']]]);
        $iblockId = $h->saveIblock(['IBLOCK_TYPE_ID' => 'bxshop', 'CODE' => 'bx_catalog', 'NAME' => 'Каталог', 'LID' => 's1', 'GROUP_ID' => ['2' => 'R']]);
        $h->saveProperty($iblockId, ['CODE' => 'ARTICLE', 'NAME' => 'Артикул', 'PROPERTY_TYPE' => 'S']);
        $h->saveProperty($iblockId, ['CODE' => 'BRAND', 'NAME' => 'Бренд', 'PROPERTY_TYPE' => 'L', 'VALUES' => [
            ['VALUE' => 'IKEA', 'XML_ID' => 'ikea', 'SORT' => 100],
            ['VALUE' => 'Hoff', 'XML_ID' => 'hoff', 'SORT' => 200],
        ]]);
        $h->saveProperty($iblockId, ['CODE' => 'RELATED', 'NAME' => 'Похожие', 'PROPERTY_TYPE' => 'E', 'LINK_IBLOCK_ID' => $iblockId, 'MULTIPLE' => 'Y']);
        $sectionId = $h->saveSection($iblockId, ['CODE' => 'sofas', 'NAME' => 'Диваны']);
        $h->saveElementByCode($iblockId, ['CODE' => 'sofa-1', 'NAME' => 'Диван Берлин', 'IBLOCK_SECTION_ID' => $sectionId], ['ARTICLE' => 'SF-001']);
    }

    public function down()
    {
        $h = $this->getHelperManager()->Iblock();
        $h->deleteIblockIfExists('bx_catalog');
        $h->deleteIblockTypeIfExists('bxshop');
    }
}
PHP

cat > $MIG/Version20260101000002.php <<'PHP'
<?php

namespace Sprint\Migration;

class Version20260101000002 extends Version
{
    protected $author = "admin";
    protected $description = "Справочник брендов (hl-блок)";
    protected $moduleVersion = "5.15.1";

    public function up()
    {
        $h = $this->getHelperManager()->Hlblock();
        $h->saveHlblock(['NAME' => 'BxBrands', 'TABLE_NAME' => 'b_hlbd_bx_brands', 'LANG' => ['ru' => ['NAME' => 'Бренды'], 'en' => ['NAME' => 'Brands']]]);
        $h->saveField('BxBrands', ['FIELD_NAME' => 'UF_XML_ID', 'USER_TYPE_ID' => 'string', 'XML_ID' => 'UF_XML_ID']);
        $h->saveField('BxBrands', ['FIELD_NAME' => 'UF_NAME', 'USER_TYPE_ID' => 'string', 'XML_ID' => 'UF_NAME']);
        $h->saveElementByXmlId('BxBrands', ['UF_XML_ID' => 'ikea', 'UF_NAME' => 'IKEA']);
    }

    public function down()
    {
        $this->getHelperManager()->Hlblock()->deleteHlblockIfExists('BxBrands');
    }
}
PHP

cat > $MIG/Version20260101000003.php <<'PHP'
<?php

namespace Sprint\Migration;

class Version20260101000003 extends Version
{
    protected $author = "admin";
    protected $description = "Группа редакторов и настройка модуля";
    protected $moduleVersion = "5.15.1";

    public function up()
    {
        $helper = $this->getHelperManager();
        $helper->UserGroup()->saveGroup('bx_editors', ['NAME' => 'Редакторы каталога', 'ACTIVE' => 'Y']);
        $helper->Option()->saveOption(['MODULE_ID' => 'main', 'NAME' => 'bx_test_option', 'VALUE' => 'on']);
    }

    public function down()
    {
        $helper = $this->getHelperManager();
        $helper->UserGroup()->deleteGroup('bx_editors');
        $helper->Option()->deleteOptions(['MODULE_ID' => 'main', 'NAME' => 'bx_test_option']);
    }
}
PHP

echo "== установка с очисткой =="
./bx setup --defaults --edition standard --install --skip-updates --clean --no-https \
  --http-port "$HTTP_PORT" --https-port "$HTTPS_PORT" --db-port "$DB_PORT" --mail-port "$MAIL_PORT" --adminer-port "$ADMINER_PORT" \
  >/tmp/mig-setup.log 2>&1 && ok "setup --install --clean" || { fail "setup --install --clean"; tail -20 /tmp/mig-setup.log; }
check "после очистки остались защищённые и обязательные модули" "fileman,highloadblock,iblock,main,security,ui" "$(q "select group_concat(ID order by ID) from b_module")"

echo "== bx migrate install =="
./bx migrate install >/tmp/mig-install.log 2>&1 && ok "bx migrate install" || { fail "bx migrate install"; tail -10 /tmp/mig-install.log; }
check "модуль sprint.migration установлен" "1" "$(q "select count(*) from b_module where ID='sprint.migration'")"
docker compose exec -T php grep -q 'function input(\$field): string|array' /var/www/html/bitrix/modules/sprint.migration/lib/output/consoleoutput.php </dev/null \
  && ok "исправление ConsoleOutput::input применено" || fail "исправление ConsoleOutput::input не применено"
[ -d local/php_interface/migrations ] && ok "папка миграций на диске: local/php_interface/migrations" || fail "нет папки миграций"

echo "== bx migrate status / up =="
st=$(./bx migrate status 2>&1)
echo "$st" | grep -qE 'Ждут применения \(новые\): +3' && ok "status до up: 3 новые" || { fail "status до up"; echo "$st" | head -6; }
if ./bx migrate up >/tmp/mig-up.log 2>&1; then ok "bx migrate up"; else fail "bx migrate up"; tail -15 /tmp/mig-up.log; fi
check "инфоблок создан" "1" "$(q "select count(*) from b_iblock where CODE='bx_catalog'")"
check "свойства инфоблока (строка, список, привязка)" "ARTICLE,BRAND,RELATED" "$(q "select group_concat(p.CODE order by p.CODE) from b_iblock_property p join b_iblock i on i.ID=p.IBLOCK_ID where i.CODE='bx_catalog'")"
check "значения списка BRAND" "2" "$(q "select count(*) from b_iblock_property_enum e join b_iblock_property p on p.ID=e.PROPERTY_ID where p.CODE='BRAND'")"
check "привязка RELATED ведёт на тот же инфоблок" "1" "$(q "select count(*) from b_iblock_property p join b_iblock i on i.ID=p.IBLOCK_ID where p.CODE='RELATED' and p.LINK_IBLOCK_ID=i.ID")"
check "раздел и элемент созданы" "1/1" "$(q "select count(*) from b_iblock_section where CODE='sofas'")/$(q "select count(*) from b_iblock_element where CODE='sofa-1'")"
check "hl-блок с полями и значением" "BxBrands/UF_NAME,UF_XML_ID/1" "$(q "select NAME from b_hlblock_entity where NAME='BxBrands'")/$(q "select group_concat(f.FIELD_NAME order by f.FIELD_NAME) from b_user_field f join b_hlblock_entity h on f.ENTITY_ID=concat('HLBLOCK_', h.ID) where h.NAME='BxBrands'")/$(q "select count(*) from b_hlbd_bx_brands")"
check "группа и настройка созданы" "1/on" "$(q "select count(*) from b_group where STRING_ID='bx_editors'")/$(q "select VALUE from b_option where MODULE_ID='main' and NAME='bx_test_option'")"
./bx backup list | grep -q before-migrate && ok "перед up сделан снимок before-migrate" || fail "снимок before-migrate не найден"
./bx migrate up 2>&1 | grep -q 'Новых миграций нет' && ok "повторный up ничего не делает" || fail "повторный up применил что-то лишнее"
./bx migrate status 2>&1 | grep -qE 'Применено: +3' && ok "status после up: 3 применено" || fail "status после up"

echo "== redo / down =="
./bx migrate redo Version20260101000001 >/tmp/mig-redo.log 2>&1 && ok "bx migrate redo" || { fail "bx migrate redo"; tail -8 /tmp/mig-redo.log; }
check "после redo свойства и элемент на месте" "3/1" "$(q "select count(*) from b_iblock_property p join b_iblock i on i.ID=p.IBLOCK_ID where i.CODE='bx_catalog'")/$(q "select count(*) from b_iblock_element where CODE='sofa-1'")"
./bx migrate down >/tmp/mig-down.log 2>&1 && ok "bx migrate down" || { fail "bx migrate down"; tail -10 /tmp/mig-down.log; }
check "после down: инфоблок, тип, hl-блок, таблица hl, группа, настройка убраны" "0/0/0//0/0" "$(q "select count(*) from b_iblock where CODE='bx_catalog'")/$(q "select count(*) from b_iblock_type where ID='bxshop'")/$(q "select count(*) from b_hlblock_entity where NAME='BxBrands'")/$(q "show tables like 'b_hlbd_bx_brands'")/$(q "select count(*) from b_group where STRING_ID='bx_editors'")/$(q "select count(*) from b_option where NAME='bx_test_option'")"

echo "== обязательные модули =="
./bx modules uninstall iblock >/dev/null 2>&1
check "iblock удалён для проверки sync" "0" "$(q "select count(*) from b_module where ID='iblock'")"
./bx migrate up >/tmp/mig-up2.log 2>&1 && ok "up после удаления iblock (сам делает sync)" || { fail "up после удаления iblock"; tail -10 /tmp/mig-up2.log; }
check "iblock возвращён, миграции применены заново" "1/1" "$(q "select count(*) from b_module where ID='iblock'")/$(q "select count(*) from b_iblock where CODE='bx_catalog'")"

echo
if [ "$FAILS" = 0 ]; then echo "Всё в порядке: миграции работают"; else echo "Провалено проверок: $FAILS"; docker compose logs --tail 40 2>&1 | tail -50; fi
[ "$FAILS" = 0 ]

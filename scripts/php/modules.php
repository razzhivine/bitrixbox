<?php
// Список и удаление модулей Битрикса через их собственные деинсталляторы (DoUninstall).
// Запускается командой `bx clean` внутри php-контейнера. Переменные окружения:
//   MODE=list                  вывести установленные модули: id<TAB>название<TAB>версия
//   MODE=uninstall MODULE=id   удалить модуль
//   SAVEDATA=Y|N               сохранить (Y) или удалить (N) таблицы БД модуля

$_SERVER['DOCUMENT_ROOT'] = '/var/www/html';
$_SERVER['REQUEST_METHOD'] = 'POST';
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);
define('ADMIN_SECTION', true);

require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_admin_before.php';

use Bitrix\Main\ModuleManager;

// Список установленных модулей кешируется в ORM на сутки. Кеш может устареть (например,
// после установки модуля из админки), и тогда Битрикс «не видит» установленный модуль.
// Поэтому перед любой работой сбрасываем его.
\Bitrix\Main\ModuleTable::getEntity()->cleanCache();
// статический список ModuleManager уже заполнен при старте ядра (из этого же кеша) — сбрасываем и его
$resetModules = function () {
    \Bitrix\Main\ModuleTable::getEntity()->cleanCache();
    $p = new ReflectionProperty(ModuleManager::class, 'installedModules');
    $p->setAccessible(true);
    $p->setValue(null, []);
};
$resetModules();

$mode = getenv('MODE') ?: 'list';

if ($mode === 'list') {
    foreach (array_keys(ModuleManager::getInstalledModules()) as $id) {
        $obj = CModule::CreateModuleObject($id);
        if (!$obj) continue;
        echo implode("\t", [$id, trim(strip_tags((string)$obj->MODULE_NAME)), (string)$obj->MODULE_VERSION]) . "\n";
    }
    exit(0);
}

$id = (string)getenv('MODULE');
$save = getenv('SAVEDATA') === 'Y' ? 'Y' : 'N';

// эти модули не удаляем никогда (список дублируется в scripts/clean.sh)
const PROTECTED_MODULES = ['main', 'security', 'fileman', 'ui'];
if ($id === '' || in_array($id, PROTECTED_MODULES, true)) {
    echo "\nBXRESULT:FAIL:модуль защищён от удаления\n";
    exit(2);
}
if (!ModuleManager::isModuleInstalled($id)) {
    echo "\nBXRESULT:OK:уже не установлен\n";
    exit(0);
}

$module = CModule::CreateModuleObject($id);
if (!$module) {
    fwrite(STDERR, "нет установщика модуля\n");
    exit(2);
}

// Деинсталляторы читают параметры шага из запроса (и из $_REQUEST, и из объекта запроса D7)
// и проверяют sessid. По завершении они печатают страницу админки и делают exit,
// поэтому итог выводим в shutdown-функции строкой BXRESULT.
global $USER, $step, $savedata, $uninstall, $SAVE_TABLES;
$USER->Authorize(1);
// Шаг передаём СТРОКОЙ: одни модули читают его как intval($step) / $step == 2, а другие
// (например conversion) сравнивают строго: $step === '2'. Строка '2' подходит всем.
$step = '2';
// «Сохранить таблицы»: у разных модулей разные имена параметра (savedata, save_tables, SAVE_TABLES).
// Как в штатной форме: галочка присылает значение Y, без неё параметра нет вовсе
// (некоторые модули, например seo, считают любое непустое значение, даже 'N', за «сохранить»).
$savedata = $save === 'Y' ? 'Y' : '';
$SAVE_TABLES = $savedata;
$uninstall = 'Y';
$req = [
    'id' => $id, 'uninstall' => 'Y', 'step' => '2',
    'sessid' => bitrix_sessid(), 'lang' => LANGUAGE_ID,
];
if ($save === 'Y') {
    $req['savedata'] = 'Y';
    $req['save_tables'] = 'Y';
    $req['SAVE_TABLES'] = 'Y';
}
foreach (['savedata', 'save_tables', 'SAVE_TABLES'] as $k) unset($_REQUEST[$k], $_POST[$k], $_GET[$k]);
$_REQUEST = $_POST = $_GET = array_merge($_REQUEST, $req);

$ctx = \Bitrix\Main\Application::getInstance()->getContext();
$server = $ctx->getServer();
$ctx->initialize(new \Bitrix\Main\HttpRequest($server, $_GET, $_POST, [], $_COOKIE), $ctx->getResponse(), $server);

register_shutdown_function(function () use ($id, $save) {
    \Bitrix\Main\ModuleTable::getEntity()->cleanCache(); // чтобы админка сразу увидела новое состояние
    BXClearCache(true);
    // статический кеш ModuleManager устарел, спрашиваем БД напрямую
    $row = \Bitrix\Main\Application::getConnection()
        ->query("SELECT ID FROM b_module WHERE ID = '" . \Bitrix\Main\Application::getConnection()->getSqlHelper()->forSql($id) . "'")->fetch();
    if (!$row) {
        echo "\nBXRESULT:OK:" . ($save === 'Y' ? 'таблицы сохранены' : 'таблицы удалены') . "\n";
        exit(0);
    }
    $err = $GLOBALS['APPLICATION']->GetException();
    echo "\nBXRESULT:FAIL:модуль остался установленным" . ($err ? ' (' . trim(strip_tags($err->GetString())) . ')' : '') . "\n";
    exit(1);
});

try {
    $module->DoUninstall();
} catch (\Throwable $e) {
    echo "\nBXRESULT:FAIL:" . $e->getMessage() . "\n";
    exit(1);
}

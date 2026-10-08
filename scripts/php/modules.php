<?php
// Список, установка и удаление модулей Битрикса через их собственные установщики (DoInstall / DoUninstall).
// Запускается командами `bx clean` и `bx modules` внутри php-контейнера. Переменные окружения:
//   MODE=list                  вывести установленные модули: id<TAB>название<TAB>версия
//   MODE=list-all              все модули на диске: id<TAB>название<TAB>версия<TAB>Y|N (установлен)
//   MODE=install MODULE=id     установить модуль (его файлы должны лежать на диске)
//   MODE=uninstall MODULE=id   удалить модуль
//   SAVEDATA=Y|N               при удалении: сохранить (Y) или удалить (N) таблицы БД модуля

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

if ($mode === 'list-all') {
    $installed = array_keys(ModuleManager::getInstalledModules());
    $seen = [];
    foreach (['/bitrix/modules', '/local/modules'] as $dir) {
        $base = $_SERVER['DOCUMENT_ROOT'] . $dir;
        if (!is_dir($base)) continue;
        foreach (scandir($base) as $m) {
            if ($m[0] === '.' || isset($seen[$m]) || !is_file("$base/$m/install/index.php")) continue;
            $seen[$m] = true;
            $obj = CModule::CreateModuleObject($m);
            $name = $obj ? trim(strip_tags((string)$obj->MODULE_NAME)) : '';
            $ver = $obj ? (string)$obj->MODULE_VERSION : '';
            echo implode("\t", [$m, $name, $ver, in_array($m, $installed, true) ? 'Y' : 'N']) . "\n";
        }
    }
    exit(0);
}

$install = ($mode === 'install');
$id = (string)getenv('MODULE');
$save = getenv('SAVEDATA') === 'Y' ? 'Y' : 'N';

// эти модули не удаляем никогда (список дублируется в scripts/clean.sh)
const PROTECTED_MODULES = ['main', 'security', 'fileman', 'ui', 'sprint.migration'];
if ($id === '') {
    echo "\nBXRESULT:FAIL:не указан модуль\n";
    exit(2);
}
if (!$install && in_array($id, PROTECTED_MODULES, true)) {
    echo "\nBXRESULT:FAIL:модуль защищён от удаления\n";
    exit(2);
}
if ($install && ModuleManager::isModuleInstalled($id)) {
    echo "\nBXRESULT:OK:уже установлен\n";
    exit(0);
}
if (!$install && !ModuleManager::isModuleInstalled($id)) {
    echo "\nBXRESULT:OK:уже не установлен\n";
    exit(0);
}

$module = CModule::CreateModuleObject($id);
if (!$module) {
    echo "\nBXRESULT:FAIL:" . ($install ? "файлов модуля нет на диске (bitrix/modules/$id или local/modules/$id)" : "нет установщика модуля") . "\n";
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
$uninstall = $install ? '' : 'Y';
$req = [
    'id' => $id, 'step' => '2',
    'sessid' => bitrix_sessid(), 'lang' => LANGUAGE_ID,
];
$req[$install ? 'install' : 'uninstall'] = 'Y';
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

register_shutdown_function(function () use ($id, $save, $install) {
    \Bitrix\Main\ModuleTable::getEntity()->cleanCache(); // чтобы админка сразу увидела новое состояние
    BXClearCache(true);
    // статический кеш ModuleManager устарел, спрашиваем БД напрямую
    $row = \Bitrix\Main\Application::getConnection()
        ->query("SELECT ID FROM b_module WHERE ID = '" . \Bitrix\Main\Application::getConnection()->getSqlHelper()->forSql($id) . "'")->fetch();
    $err = $GLOBALS['APPLICATION']->GetException();
    $detail = $err ? ' (' . trim(strip_tags($err->GetString())) . ')' : '';
    if ($install) {
        if ($row) { echo "\nBXRESULT:OK:установлен\n"; exit(0); }
        echo "\nBXRESULT:FAIL:модуль не установился" . $detail . "\n";
        exit(1);
    }
    if (!$row) {
        echo "\nBXRESULT:OK:" . ($save === 'Y' ? 'таблицы сохранены' : 'таблицы удалены') . "\n";
        exit(0);
    }
    echo "\nBXRESULT:FAIL:модуль остался установленным" . $detail . "\n";
    exit(1);
});

try {
    $install ? $module->DoInstall() : $module->DoUninstall();
} catch (\Throwable $e) {
    echo "\nBXRESULT:FAIL:" . $e->getMessage() . "\n";
    exit(1);
}

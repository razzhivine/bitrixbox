<?php
// Режим отладки Битрикса: подробный вывод ошибок и лог исключений.
// Запускается командой `bx debug on|off|status` внутри php-контейнера (MODE=on|off|status).
// Настройки пишутся штатным API Configuration в bitrix/.settings.php (секция exception_handling).

$_SERVER['DOCUMENT_ROOT'] = '/var/www/html';
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);

require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_before.php';

use Bitrix\Main\Config\Configuration;

$logFile = 'bitrix/exceptions.log';
$mode = getenv('MODE') ?: 'status';
$eh = Configuration::getValue('exception_handling') ?: [];

if ($mode === 'on') {
    $eh['debug'] = true;
    $eh['log'] = ['settings' => ['file' => $logFile, 'log_size' => 1000000]];
    Configuration::setValue('exception_handling', $eh);
} elseif ($mode === 'off') {
    $eh['debug'] = false;
    $eh['log'] = null;
    Configuration::setValue('exception_handling', $eh);
    if (file_exists("{$_SERVER['DOCUMENT_ROOT']}/$logFile")) unlink("{$_SERVER['DOCUMENT_ROOT']}/$logFile");
} elseif ($mode !== 'status') {
    fwrite(STDERR, "Режим: on, off или status\n");
    exit(2);
}

// читаем заново из файла, чтобы показать реальное состояние
$fresh = (include $_SERVER['DOCUMENT_ROOT'] . '/bitrix/.settings.php')['exception_handling']['value'] ?? [];
$debug = !empty($fresh['debug']);
$logPath = $fresh['log']['settings']['file'] ?? null;
echo 'Отладка: ' . ($debug ? 'ВКЛЮЧЕНА (ошибки показываются на странице)' : 'выключена') . "\n";
echo 'Лог исключений: ' . ($logPath ? "включён → $logPath" : 'выключен') . "\n";
if ($logPath && file_exists("{$_SERVER['DOCUMENT_ROOT']}/$logPath")) {
    printf("Размер лога: %d байт\n", filesize("{$_SERVER['DOCUMENT_ROOT']}/$logPath"));
}
if ($debug) echo "На рабочем сайте так оставлять нельзя: bx debug off\n";

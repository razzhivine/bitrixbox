<?php
// Обновление платформы Битрикса теми же вызовами, что делает страница «Обновление платформы»
// (bitrix/modules/main/admin/update_system_call.php и update_system_act.php).
// Запускается командой `bx update` внутри php-контейнера. Переменные окружения:
//   MODE=check          показать, какие обновления доступны (строки MOD|… / SYS|… / ERR|…)
//   MODE=updateupdate   обновить саму систему обновлений
//   MODE=step           выполнить один шаг установки обновлений модулей
// Ответ шага печатает штатный скрипт: FIN (всё установлено), STP… (шаг выполнен, продолжать) или ERR… (ошибка).
// Они делают die(), поэтому каждый шаг идёт отдельным запуском PHP.

$_SERVER['DOCUMENT_ROOT'] = '/var/www/html';
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);

if (!is_file($_SERVER['DOCUMENT_ROOT'] . '/bitrix/php_interface/dbconn.php')) {
    echo "ERR|Битрикс ещё не установлен\n";
    exit(1);
}

require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_before.php';
require_once $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/classes/general/update_client.php';

if (!defined('LANG')) define('LANG', LANGUAGE_ID);
define('UPD_INTERNAL_CALL', 'Y'); // штатные скрипты тогда не требуют сессии и токена

global $USER;
$USER->Authorize(1);

$mode = getenv('MODE') ?: 'check';
$stable = COption::GetOptionString('main', 'stable_versions_only', 'Y');

if ($mode === 'check') {
    $err = '';
    $list = CUpdateClient::GetUpdatesList($err, LANG, $stable);
    if ($err !== '' || !is_array($list)) {
        echo 'ERR|' . trim(strip_tags($err ?: 'сервер обновлений не ответил')) . "\n";
        exit(1);
    }
    foreach ($list['ERROR'] ?? [] as $e) {
        $type = $e['@']['TYPE'] ?? '';
        if (in_array($type, ['RESERVED_KEY'], true)) continue;
        echo 'ERR|[' . $type . '] ' . trim(strip_tags($e['#'] ?? '')) . "\n";
    }
    if (!empty($list['UPDATE_SYSTEM'])) echo "SYS|доступно обновление самой системы обновлений\n";
    foreach ($list['MODULES'][0]['#']['MODULE'] ?? [] as $m) {
        $id = $m['@']['ID'] ?? '?';
        $versions = [];
        foreach ($m['#']['VERSION'] ?? [] as $v) $versions[] = $v['@']['ID'] ?? '';
        echo 'MOD|' . $id . '|' . count($versions) . '|' . ($versions ? end($versions) : '') . "\n";
    }
    exit(0);
}

if ($mode !== 'updateupdate' && $mode !== 'step') {
    echo "ERR|MODE: check, updateupdate или step\n";
    exit(2);
}

// Штатные скрипты сами печатают ответ (FIN / STP… / ERR… / Y) и могут сделать die() —
// ничего не оборачиваем, ответ разбирает bx update по сырому выводу.

if ($mode === 'updateupdate') {
    $_REQUEST['query_type'] = 'updateupdate';
    include $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/admin/update_system_act.php';
} else {
    $_REQUEST['query_type'] = 'M';
    include $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/admin/update_system_call.php';
}

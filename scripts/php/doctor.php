<?php
// Проверки состояния самого Битрикса для `bx doctor`. Печатает строки вида  СТАТУС|текст,
// где СТАТУС: OK, WARN или INFO. Запускается внутри php-контейнера.

$_SERVER['DOCUMENT_ROOT'] = '/var/www/html';
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);

if (!is_file($_SERVER['DOCUMENT_ROOT'] . '/bitrix/php_interface/dbconn.php')) {
    echo "INFO|Битрикс ещё не установлен (установщик не пройден)\n";
    exit(0);
}

require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_before.php';

use Bitrix\Main\Application;
use Bitrix\Main\ModuleManager;

function out(string $s, string $t) { echo "$s|$t\n"; }

$conn = Application::getConnection();

// версия продукта
$ver = defined('SM_VERSION') ? SM_VERSION : null;
if (!$ver && is_file($_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/classes/general/version.php')) {
    $v = include $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/classes/general/version.php';
    $ver = is_array($v) ? ($v['VERSION'] ?? null) : null;
}
out('INFO', 'Версия главного модуля: ' . ($ver ?: 'не определена') . ', PHP ' . PHP_VERSION);

// 1. кеш списка модулей против базы
$db = [];
$rs = $conn->query('SELECT ID FROM b_module ORDER BY ID');
while ($r = $rs->fetch()) $db[] = $r['ID'];
$cached = array_keys(ModuleManager::getInstalledModules());
sort($cached);
$missing = array_diff($db, $cached);
$extra = array_diff($cached, $db);
if ($missing || $extra) {
    out('WARN', 'Кеш списка модулей устарел (нет в кеше: ' . implode(',', $missing ?: ['—']) . '; лишние: ' . implode(',', $extra ?: ['—']) . '). Лечится: bx cache-clear');
} else {
    out('OK', 'Кеш списка модулей совпадает с базой (' . count($db) . ' модулей)');
}

// 2. отладка
$eh = (include $_SERVER['DOCUMENT_ROOT'] . '/bitrix/.settings.php')['exception_handling']['value'] ?? [];
if (!empty($eh['debug'])) out('WARN', 'Режим отладки включён (ошибки видны на страницах). Выключить: bx debug off');
else out('OK', 'Режим отладки выключен');

// 3. агенты: на хитах или по cron, и не застряли ли
$cronMode = defined('BX_CRONTAB_SUPPORT') && BX_CRONTAB_SUPPORT === true;
out('INFO', 'Агенты и почтовые события: ' . ($cronMode ? 'по расписанию (cron)' : 'на хитах страниц'));
$row = $conn->query("SELECT COUNT(*) C, MAX(LAST_EXEC) L, SUM(NEXT_EXEC < NOW() - INTERVAL 2 HOUR) O FROM b_agent WHERE ACTIVE='Y'")->fetch();
if ((int)$row['O'] > 0) {
    out('WARN', "Просроченных агентов: {$row['O']} из {$row['C']} (последний запуск: " . ($row['L'] ?: 'никогда') . '). ' . ($cronMode ? 'Проверьте контейнер cron: bx logs cron' : 'Включите cron: bx cron on'));
} else {
    out('OK', "Агенты выполняются вовремя ({$row['C']} активных)");
}

// 4. администратор
$adm = $conn->query("SELECT COUNT(*) C FROM b_user u JOIN b_user_group g ON g.USER_ID = u.ID WHERE g.GROUP_ID = 1 AND u.ACTIVE = 'Y'")->fetch();
if ((int)$adm['C'] < 1) out('WARN', 'Нет активных администраторов');
else out('OK', 'Администраторов: ' . (int)$adm['C']);

// 5. почта
$sendmail = ini_get('sendmail_path');
if (strpos($sendmail, 'msmtp') !== false) out('OK', 'Почта уходит в Mailpit (sendmail_path = msmtp)');
else out('WARN', "sendmail_path = «$sendmail» — письма не попадут в Mailpit");

// 6. кодировка базы
$cs = $conn->query("SELECT @@character_set_database cs, @@sql_mode m, @@transaction_isolation ti")->fetch();
if ($cs['cs'] !== 'utf8mb4') out('WARN', "Кодировка базы {$cs['cs']}, ожидалась utf8mb4");
elseif ($cs['m'] !== '') out('WARN', "sql_mode не пустой ({$cs['m']}) — Битрикс рекомендует пустой");
else out('OK', 'База: utf8mb4, sql_mode пустой, изоляция ' . $cs['ti']);

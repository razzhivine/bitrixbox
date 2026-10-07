<?php
// Полный сброс кеша Битрикса через API. Запускается командой `bx cache-clear`.

$_SERVER['DOCUMENT_ROOT'] = '/var/www/html';
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);

require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_before.php';

use Bitrix\Main\Application;

BXClearCache(true);                                            // файловый кеш
Application::getInstance()->getManagedCache()->cleanAll();     // управляемый кеш
Application::getInstance()->getTaggedCache()->clearByTag(true);
\Bitrix\Main\ModuleTable::getEntity()->cleanCache();           // кеш списка модулей (у него TTL сутки)

echo "Кеш Битрикса очищен\n";

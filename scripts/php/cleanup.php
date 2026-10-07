<?php
// Очистка Битрикса через его API. Запускается командой `bx clean` внутри php-контейнера.
// Переменная STAGE выбирает этап, остальные параметры передаёт scripts/clean.sh:
//
//   STAGE=demo        демо-данные: инфоблоки (элементы, разделы, сами инфоблоки и типы),
//                     страницы и папки в корне сайта, шаблоны (кроме .default), демо-картинки
//       DRY_RUN=1          только показать, что будет удалено
//       IBLOCK_IDS=1,2,3   ограничить список инфоблоков (по умолчанию все)
//       CONTENT=0          не трогать инфоблоки
//       KEEP_IBLOCKS=1     удалить только элементы и разделы, инфоблоки и их типы оставить
//       PAGES=0            не трогать страницы и шаблоны
//
//   STAGE=leftovers   остатки удалённых модулей и (по запросу) файлы неустановленных модулей
//       DRY_RUN=1          только показать план
//       LEFTOVERS=0        пропустить блок остатков
//       MODULE_FILES=1     добавить удаление файлов неустановленных модулей
//       FILES_ONLY=a,b     ограничить файлы этими модулями (для проверок)
//       PRINT_PATHS=1      дополнительно печатать пути строками FILE:<путь> (для архива)

$_SERVER['DOCUMENT_ROOT'] = '/var/www/html';
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('NO_AGENT_CHECK', true);
define('STOP_STATISTICS', true);

require $_SERVER['DOCUMENT_ROOT'] . '/bitrix/modules/main/include/prolog_before.php';

use Bitrix\Main\Application;
use Bitrix\Main\Config\Option;

$stage = getenv('STAGE');
$dry   = getenv('DRY_RUN') === '1';
$root  = $_SERVER['DOCUMENT_ROOT'];

if ($stage === 'demo') {
    if (!CModule::IncludeModule('iblock')) {
        fwrite(STDERR, "Модуль iblock не найден\n");
        exit(1);
    }

    $dry = getenv('DRY_RUN') === '1';
    $only   = array_filter(array_map('intval', explode(',', (string)getenv('IBLOCK_IDS'))));

    $doContent = getenv('CONTENT') !== '0';
    $doPages   = getenv('PAGES') !== '0';
    $dropIblocks = getenv('KEEP_IBLOCKS') !== '1';
    $types = []; // типы, из которых удалены инфоблоки

    $filter = $only ? ['ID' => $only] : [];
    $res = $doContent ? CIBlock::GetList(['ID' => 'ASC'], $filter + ['CHECK_PERMISSIONS' => 'N']) : null;

    $total = ['elements' => 0, 'sections' => 0];
    while ($res && ($ib = $res->Fetch())) {
        $id = (int)$ib['ID'];
        $elements = CIBlockElement::GetList(['ID' => 'ASC'], ['IBLOCK_ID' => $id, 'CHECK_PERMISSIONS' => 'N'], false, false, ['ID']);
        $elIds = [];
        while ($e = $elements->Fetch()) $elIds[] = (int)$e['ID'];

        // разделы удаляем от самых вложенных к корневым
        $sections = CIBlockSection::GetList(['DEPTH_LEVEL' => 'DESC', 'ID' => 'ASC'], ['IBLOCK_ID' => $id, 'CHECK_PERMISSIONS' => 'N'], false, ['ID']);
        $secIds = [];
        while ($s = $sections->Fetch()) $secIds[] = (int)$s['ID'];

        printf("[%d] %s (%s): элементов %d, разделов %d\n", $id, $ib['NAME'], $ib['CODE'], count($elIds), count($secIds));

        if (!$dry) {
            foreach ($elIds as $eid) {
                if (!CIBlockElement::Delete($eid)) fwrite(STDERR, "  не удалось удалить элемент $eid\n");
            }
            foreach ($secIds as $sid) {
                if (!CIBlockSection::Delete($sid)) fwrite(STDERR, "  не удалось удалить раздел $sid\n");
            }
        }
        if ($dropIblocks) {
            echo "  инфоблок будет удалён целиком\n";
            $types[$ib['IBLOCK_TYPE_ID']] = true;
            if (!$dry && !CIBlock::Delete($id)) fwrite(STDERR, "  не удалось удалить инфоблок $id\n");
        }
        $total['elements'] += count($elIds);
        $total['sections'] += count($secIds);
    }

    // типы удаляем, только если в них не осталось инфоблоков (служебные типы вроде rest_entity не трогаем)
    foreach (array_keys($types) as $typeId) {
        echo "Тип инфоблоков: $typeId\n";
        if ($dry) continue;
        $left = CIBlock::GetList([], ['TYPE' => $typeId, 'CHECK_PERMISSIONS' => 'N'])->SelectedRowsCount();
        if ($left === 0 && !CIBlockType::Delete($typeId)) fwrite(STDERR, "  не удалось удалить тип $typeId\n");
    }

    // --- страницы сайта, шаблоны, демо-файлы ---
    // В корне остаются только bitrix, local, upload и служебные urlrewrite.php/.htaccess,
    // из шаблонов остаётся только .default
    if ($doPages) {
            $keepRoot = ['bitrix', 'local', 'upload', 'urlrewrite.php', '.htaccess'];
        $del = [];

        foreach (scandir($root) as $name) {
            if ($name === '.' || $name === '..' || in_array($name, $keepRoot, true)) continue;
            $del[] = "/$name";
        }
        foreach (scandir("$root/bitrix/templates") as $name) {
            if ($name === '.' || $name === '..' || $name === '.default') continue;
            $del[] = "/bitrix/templates/$name";
        }
        foreach (scandir("$root/upload") as $name) { // демо-картинки, лежащие прямо в upload
            if ($name[0] !== '.' && is_file("$root/upload/$name")) $del[] = "/upload/$name"; // .htaccess не трогаем
        }

        foreach ($del as $path) {
            echo "Удалить: $path\n";
            if (!$dry) DeleteDirFilesEx($path);
        }

        if (!$dry) {
            // сайт переключаем на шаблон .default
            $site = new CSite;
            $site->Update('s1', ['TEMPLATE' => [['TEMPLATE' => '.default', 'SORT' => 1, 'CONDITION' => '']]]);

            // правила ЧПУ, ведущие на удалённые страницы
            foreach (CUrlRewriter::GetList(['SITE_ID' => 's1']) as $r) {
                if (strpos($r['PATH'], '/bitrix/') !== 0 && !file_exists($root . $r['PATH'])) {
                    CUrlRewriter::Delete(['SITE_ID' => 's1', 'CONDITION' => $r['CONDITION']]);
                }
            }
        } else {
            echo "Сайт s1 будет переключён на шаблон .default, лишние правила urlrewrite удалены\n";
        }
    }

    if (!$dry) {
        BXClearCache(true);
        echo "Кеш очищен\n";
    }
    printf("%s: элементов %d, разделов %d\n", $dry ? 'Будет удалено' : 'Удалено', $total['elements'], $total['sections']);
} elseif ($stage === 'leftovers') {
        $doLeft    = getenv('LEFTOVERS') !== '0';
    $doFiles   = getenv('MODULE_FILES') === '1';
    $printPaths = getenv('PRINT_PATHS') === '1';
    $filesOnly = array_filter(explode(',', (string)getenv('FILES_ONLY')));
    $conn = Application::getConnection();
    $sql  = $conn->getSqlHelper();

    // установленные модули — по БД, а не по кешу (кеш бывает устаревшим)
    \Bitrix\Main\ModuleTable::getEntity()->cleanCache();
    $installed = [];
    $rs = $conn->query('SELECT ID FROM b_module');
    while ($r = $rs->fetch()) $installed[] = $r['ID'];

    // модули на диске (у модуля есть install/index.php)
    $onDisk = [];
    foreach (scandir("$root/bitrix/modules") as $m) {
        if ($m[0] !== '.' && is_file("$root/bitrix/modules/$m/install/index.php")) $onDisk[] = $m;
    }
    $removed = array_values(array_diff($onDisk, $installed));
    echo 'Неустановленные модули на диске: ' . ($removed ? implode(', ', $removed) : 'нет') . "\n";

    function dirSizeKb(string $path): int
    {
        $out = shell_exec('du -sk ' . escapeshellarg($path) . ' 2>/dev/null');
        return (int)$out;
    }

    // ---------------------------------------------------------------- остатки
    if ($doLeft) {
        echo "\n-- Остатки удалённых модулей --\n";

        // 1. Настройки (b_option) неустановленных модулей, которые есть на диске
        $rs = $conn->query('SELECT MODULE_ID, COUNT(*) C FROM b_option GROUP BY MODULE_ID');
        while ($r = $rs->fetch()) {
            $mid = $r['MODULE_ID'];
            if (in_array($mid, $installed, true)) continue;
            if (in_array($mid, $removed, true)) {
                echo "Настройки модуля $mid: {$r['C']} шт.\n";
                if (!$dry) Option::delete($mid);
            } elseif (strpos($mid, 'main') !== 0) {
                echo "Настройки «{$mid}»: {$r['C']} шт. — не трогаю (не похоже на модуль)\n";
            }
        }

        // 2. Пользовательские поля сущностей удалённых модулей
        $ufPrefix = ['blog' => 'BLOG_', 'forum' => 'FORUM_', 'vote' => 'VOTE_', 'landing' => 'LANDING_', 'highloadblock' => 'HLBLOCK_'];
        $uts = new CUserTypeEntity;
        $rs = CUserTypeEntity::GetList([], []);
        while ($uf = $rs->Fetch()) {
            foreach ($ufPrefix as $mod => $pfx) {
                if (in_array($mod, $removed, true) && strpos($uf['ENTITY_ID'], $pfx) === 0) {
                    echo "Пользовательское поле: {$uf['ENTITY_ID']} / {$uf['FIELD_NAME']}\n";
                    if (!$dry) $uts->Delete($uf['ID']);
                }
            }
        }

        // 3. Почтовые типы и шаблоны удалённых модулей
        $evPrefix = ['forum' => 'FORUM', 'blog' => 'BLOG', 'vote' => 'VOTE', 'subscribe' => 'SUBSCRIBE',
                     'photogallery' => 'PHOTOGALLERY', 'landing' => 'LANDING'];
        $seen = [];
        $rs = $conn->query("SELECT DISTINCT EVENT_NAME FROM b_event_type");
        while ($r = $rs->fetch()) {
            foreach ($evPrefix as $mod => $pfx) {
                if (in_array($mod, $removed, true) && ($r['EVENT_NAME'] === $pfx || strpos($r['EVENT_NAME'], $pfx . '_') === 0)) {
                    $seen[$r['EVENT_NAME']] = true;
                }
            }
        }
        foreach (array_keys($seen) as $ev) {
            $msgs = CEventMessage::GetList('id', 'asc', ['TYPE_ID' => $ev]);
            $ids = [];
            while ($m = $msgs->Fetch()) $ids[] = (int)$m['ID'];
            echo "Почтовый тип $ev: шаблонов " . count($ids) . "\n";
            if (!$dry) {
                $em = new CEventMessage;
                foreach ($ids as $id) $em->Delete($id);
                $et = new CEventType;
                $et->Delete($ev);
            }
        }

        // 4. Мастера установки: демо-сайт и мастера удалённых модулей
        $wizDir = "$root/bitrix/wizards/bitrix";
        if (is_dir($wizDir)) {
            foreach (scandir($wizDir) as $w) {
                if ($w[0] === '.') continue;
                $isDemo = $w === 'corp_furniture';
                $ofRemoved = false;
                foreach ($removed as $m) if (strpos($w, $m . '.') === 0) $ofRemoved = true;
                if ($isDemo || $ofRemoved) {
                    echo "Мастер установки: bitrix/wizards/bitrix/$w\n";
                    if (!$dry) DeleteDirFilesEx("/bitrix/wizards/bitrix/$w");
                }
            }
        }

        // 5. Временные файлы
        foreach (['/bitrix/tmp', '/upload/tmp', '/upload/resize_cache'] as $tmp) {
            if (!is_dir($root . $tmp)) continue;
            $kids = array_diff(scandir($root . $tmp), ['.', '..']);
            if (!$kids) continue;
            echo "Временные файлы: $tmp (" . count($kids) . " шт.)\n";
            if (!$dry) foreach ($kids as $k) DeleteDirFilesEx("$tmp/$k");
        }
        echo "Кеш: будет очищен\n";

        // 6. Название сайта от демо-шаблона
        $site = CSite::GetByID('s1')->Fetch();
        if ($site && ($site['NAME'] !== 'Сайт по умолчанию' || $site['SITE_NAME'] !== '')) {
            echo "Название сайта s1: «{$site['NAME']}» → «Сайт по умолчанию»\n";
            if (!$dry) {
                $s = new CSite;
                $s->Update('s1', ['NAME' => 'Сайт по умолчанию', 'SITE_NAME' => '']);
            }
        }
    }

    // ---------------------------------------------------------------- файлы модулей
    if ($doFiles) {
        echo "\n-- Файлы неустановленных модулей --\n";
        $totalKb = 0;
        $allPaths = [];

        foreach ($removed as $m) {
            if ($filesOnly && !in_array($m, $filesOnly, true)) continue;
            $paths = [];
            // то, что установщик модуля скопировал за пределы его папки
            foreach (['components' => '/bitrix/components', 'wizards' => '/bitrix/wizards', 'templates' => '/bitrix/templates'] as $sub => $target) {
                $base = "$root/bitrix/modules/$m/install/$sub";
                if (!is_dir($base)) continue;
                foreach (array_diff(scandir($base), ['.', '..']) as $first) {
                    if ($sub === 'templates') {
                        if ($first !== '.default') $paths[] = "$target/$first";
                        continue;
                    }
                    if (!is_dir("$base/$first")) continue;
                    foreach (array_diff(scandir("$base/$first"), ['.', '..']) as $second) {
                        $paths[] = "$target/$first/$second";
                    }
                }
            }
            // папки модуля в js/images/panel/themes (install/js — это файлы модуля, копируются в /bitrix/js/<модуль>)
            foreach (['/bitrix/js', '/bitrix/images', '/bitrix/panel', '/bitrix/themes/.default'] as $dir) {
                $paths[] = "$dir/$m";
            }
            $paths = array_values(array_filter(array_unique($paths), fn($p) => file_exists($root . $p)));
            $paths[] = "/bitrix/modules/$m"; // папку модуля — последней

            $kb = 0;
            foreach ($paths as $p) $kb += dirSizeKb($root . $p);
            $totalKb += $kb;
            printf("Модуль %-22s путей %2d, %6.1f МБ\n", $m, count($paths), $kb / 1024);
            foreach ($paths as $p) {
                $allPaths[] = $p;
                if ($printPaths) echo "FILE:" . ltrim($p, '/') . "\n";
            }
        }
        printf("Всего файлов к удалению: %.1f МБ\n", $totalKb / 1024);

        if (!$dry) {
            foreach ($allPaths as $p) DeleteDirFilesEx($p);
        }
    }

    if (!$dry) {
        \Bitrix\Main\ModuleTable::getEntity()->cleanCache();
        BXClearCache(true);
        echo "\nКеш очищен\n";
    }
} else {
    fwrite(STDERR, "Не задан STAGE (demo|leftovers)\n");
    exit(2);
}

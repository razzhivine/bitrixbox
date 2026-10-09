<?php
// Подготовка перенесённого сайта к работе в BitrixBox. Запускается внутри php-контейнера командами bx import и bx pull.
// Ядро Битрикса не подключается: до правки настроек оно бы пыталось соединиться с боевой базой и кешем.
//   MODE=config  настройки на диске: подключение к базе, кеш и сессии в файлах, без SMTP, cookie без secure
//   MODE=db      настройки в базе: правила доступа по IP, облачные хранилища только на чтение, очередь писем
//   MODE=admin   задать пароль администратору (ADMIN_LOGIN — какому, иначе первому активному из группы 1)
// Ожидает переменные DB_NAME, DB_USER, DB_PASSWORD; для db — ещё SITE_HOST (например, localhost:8080).
// Печатает строки «  - что сделано»; предупреждения начинаются с WARN|, итог admin — ADMIN|логин|пароль.

$root = '/var/www/html';
$mode = getenv('MODE') ?: '';

function say(string $s): void { echo "  - $s\n"; }
function warn(string $s): void { echo "WARN|$s\n"; }

function db(): mysqli
{
    mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
    $c = new mysqli('db', getenv('DB_USER'), getenv('DB_PASSWORD'), getenv('DB_NAME'));
    $c->set_charset('utf8mb4');
    return $c;
}

function table_exists(mysqli $c, string $t): bool
{
    $r = $c->query("SHOW TABLES LIKE '" . $c->real_escape_string($t) . "'");
    return $r->num_rows > 0;
}

function column_exists(mysqli $c, string $t, string $col): bool
{
    $r = $c->query("SHOW COLUMNS FROM `$t` LIKE '" . $c->real_escape_string($col) . "'");
    return $r->num_rows > 0;
}

if ($mode === 'config') {
    // --- bitrix/.settings.php: файл возвращает массив, Битрикс сам сохраняет его через var_export ---
    $f = "$root/bitrix/.settings.php";
    if (!is_file($f)) { fwrite(STDERR, "Нет файла bitrix/.settings.php — это не сайт на Битриксе или архив неполный\n"); exit(1); }
    $cfg = include $f;
    if (!is_array($cfg)) { fwrite(STDERR, "bitrix/.settings.php не вернул массив настроек\n"); exit(1); }

    $conn = $cfg['connections']['value']['default'] ?? [];
    $class = $conn['className'] ?? '\\Bitrix\\Main\\DB\\MysqliConnection';
    if (stripos($class, 'pgsql') !== false) { fwrite(STDERR, "Сайт работает на PostgreSQL — BitrixBox поддерживает только MySQL и MariaDB\n"); exit(1); }
    if (stripos($class, 'Mysqli') === false) {
        say("класс подключения $class заменён на MysqliConnection (в PHP 8 нет расширения mysql)");
        $class = '\\Bitrix\\Main\\DB\\MysqliConnection';
    }
    $cfg['connections']['value']['default'] = array_merge($conn, [
        'host' => 'db',
        'database' => getenv('DB_NAME'),
        'login' => getenv('DB_USER'),
        'password' => getenv('DB_PASSWORD'),
        'className' => $class,
    ]);
    $cfg['connections']['readonly'] = true;
    $extra = array_diff(array_keys($cfg['connections']['value']), ['default']);
    if ($extra) warn('в .settings.php есть дополнительные подключения к базам (' . implode(', ', $extra) . ') — они ведут на боевые серверы, проверьте их');
    say('подключение к базе: db / ' . getenv('DB_NAME'));

    // кеш в memcache/redis/apcu на боевом сервере → в файлах (по умолчанию)
    if (isset($cfg['cache'])) {
        $type = $cfg['cache']['value']['type'] ?? null;
        $type = is_array($type) ? ($type['class_name'] ?? 'свой класс') : $type;
        unset($cfg['cache']);
        say('кеш: ' . ($type ?: 'настройка') . ' → файлы');
    }
    // сессии в redis/memcache/базе → в файлах
    if (isset($cfg['session'])) {
        unset($cfg['session']);
        say('сессии: обработчик боевого сервера → файлы');
    }
    // встроенная отправка почты через SMTP: письма ушли бы настоящим людям мимо Mailpit
    if (!empty($cfg['smtp']['value']['enabled'])) {
        $cfg['smtp']['value']['enabled'] = false;
        say('SMTP Битрикса выключен: письма уходят в Mailpit');
    }
    // cookie только по HTTPS не дали бы войти на http://localhost
    if (!empty($cfg['cookies']['value']['secure'])) {
        $cfg['cookies']['value']['secure'] = false;
        say('cookie: secure выключен (иначе вход по http не работает)');
    }
    file_put_contents($f, "<?php\nreturn " . var_export($cfg, true) . ";\n");

    // --- bitrix/php_interface/dbconn.php ---
    $f = "$root/bitrix/php_interface/dbconn.php";
    if (is_file($f)) {
        $s = $orig = file_get_contents($f);
        // старые установки хранят подключение ещё и здесь
        $vars = ['DBHost' => 'db', 'DBName' => getenv('DB_NAME'), 'DBLogin' => getenv('DB_USER'), 'DBPassword' => getenv('DB_PASSWORD')];
        foreach ($vars as $k => $v) {
            $s = preg_replace('/^(\s*\$' . $k . '\s*=\s*)([\'"]).*?\2\s*;/m', '${1}"' . addcslashes($v, '"\\$') . '";', $s);
        }
        if (preg_match('/^\s*\$DBType\s*=\s*[\'"]mysql[\'"]/mi', $s) === 0 && preg_match('/^\s*\$DBType\s*=/m', $s)) {
            warn('в dbconn.php задан $DBType не mysql — проверьте подключение');
        }
        // настройки, которые на локальной машине ломают сайт: кеш в memcache, временные файлы вне сайта и т. п.
        $off = ['BX_CACHE_TYPE', 'BX_CACHE_SID', 'BX_MEMCACHE_HOST', 'BX_MEMCACHE_PORT', 'BX_TEMPORARY_FILES_DIRECTORY',
                'BX_SECURITY_SESSION_MEMCACHE_HOST', 'BX_SECURITY_SESSION_MEMCACHE_PORT', 'BX_SECURITY_SESSION_VIRTUAL',
                'BX_SECURITY_SESSION_READONLY', 'BX_CACHE_CLASS'];
        $n = 0;
        foreach ($off as $name) {
            $s = preg_replace('/^(\s*)(@?define\s*\(\s*[\'"]' . $name . '[\'"].*)$/m', '$1// bitrixbox: $2', $s, -1, $c);
            $n += $c;
        }
        if ($n) say("dbconn.php: отключено настроек боевого сервера: $n (кеш, временные файлы, сессии)");
        if ($s !== $orig) file_put_contents($f, $s);
    }

    // Свой обработчик почты в коде: его мы не трогаем, но предупреждаем — письма могут уйти мимо Mailpit
    foreach (["$root/local/php_interface/init.php", "$root/bitrix/php_interface/init.php"] as $init) {
        if (is_file($init) && preg_match('/function\s+custom_mail\s*\(/i', file_get_contents($init))) {
            warn(str_replace("$root/", '', $init) . ': своя функция custom_mail — письма могут уходить наружу, мимо Mailpit');
        }
    }
    exit(0);
}

if ($mode === 'db') {
    $c = db();
    $coll = $c->query("SHOW TABLE STATUS LIKE 'b_option'")->fetch_assoc()['Collation'] ?? '';
    if (stripos($coll, 'cp1251') === 0) {
        warn('база в кодировке windows-1251: BitrixBox рассчитан на UTF-8, возможны «кракозябры» (сайт стоит перевести на UTF-8)');
    }

    // адрес сайта («URL сервера») записывает scripts/siteurl.sh (его вызывает import.sh после этого шага)

    if (table_exists($c, 'b_sec_iprule')) {
        $c->query("UPDATE b_sec_iprule SET ACTIVE='N' WHERE ACTIVE='Y'");
        if ($c->affected_rows) say("правила доступа по IP (модуль «Проактивная защита») выключены: {$c->affected_rows}");
    }
    if (table_exists($c, 'b_clouds_file_bucket') && column_exists($c, 'b_clouds_file_bucket', 'READ_ONLY')) {
        $c->query("UPDATE b_clouds_file_bucket SET READ_ONLY='Y' WHERE READ_ONLY<>'Y'");
        if ($c->affected_rows) say("облачные хранилища переведены в режим «только чтение»: {$c->affected_rows} (новые файлы не попадут в боевое хранилище)");
    }
    // очередь писем, накопленная на боевом сервере
    if (table_exists($c, 'b_event')) {
        $c->query("DELETE FROM b_event WHERE SUCCESS_EXEC='N'");
        if ($c->affected_rows) say("неотправленные письма боевого сервера удалены из очереди: {$c->affected_rows}");
    }
    exit(0);
}

if ($mode === 'admin') {
    $c = db();
    $login = getenv('ADMIN_LOGIN') ?: '';
    if ($login !== '') {
        $st = $c->prepare('SELECT ID, LOGIN FROM b_user WHERE LOGIN=?');
        $st->bind_param('s', $login); $st->execute();
        $u = $st->get_result()->fetch_assoc();
        if (!$u) { fwrite(STDERR, "Пользователь с логином $login не найден\n"); exit(1); }
    } else {
        $u = $c->query("SELECT u.ID, u.LOGIN FROM b_user u JOIN b_user_group g ON g.USER_ID=u.ID AND g.GROUP_ID=1
                        WHERE u.ACTIVE='Y' AND u.LOGIN NOT LIKE '%@%' ORDER BY u.ID LIMIT 1")->fetch_assoc()
          ?: $c->query("SELECT u.ID, u.LOGIN FROM b_user u JOIN b_user_group g ON g.USER_ID=u.ID AND g.GROUP_ID=1
                        ORDER BY u.ID LIMIT 1")->fetch_assoc();
        if (!$u) { fwrite(STDERR, "В группе администраторов нет пользователей\n"); exit(1); }
    }
    $pass = getenv('ADMIN_PASSWORD') ?: substr(bin2hex(random_bytes(8)), 0, 16);
    $alpha = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    $salt = '';
    for ($i = 0; $i < 16; $i++) $salt .= $alpha[random_int(0, strlen($alpha) - 1)];
    $hash = crypt($pass, '$6$' . $salt . '$');   // тот же формат, что \Bitrix\Main\Security\Password::hash()

    $set = ["PASSWORD=?", "ACTIVE='Y'"];
    foreach (['BLOCKED' => "'N'", 'LOGIN_ATTEMPTS' => '0', 'CHECKWORD' => "''"] as $col => $v) {
        if (column_exists($c, 'b_user', $col)) $set[] = "$col=$v";
    }
    $st = $c->prepare('UPDATE b_user SET ' . implode(', ', $set) . ' WHERE ID=?');
    $st->bind_param('si', $hash, $u['ID']); $st->execute();
    // одноразовые пароли (двухэтапная авторизация) — телефон с боевым ключом здесь не поможет
    if (table_exists($c, 'b_sec_user')) {
        $st = $c->prepare('DELETE FROM b_sec_user WHERE USER_ID=?');
        $st->bind_param('i', $u['ID']); $st->execute();
    }
    // группа может требовать регулярную смену пароля: отметим, что пароль сменён сейчас
    if (table_exists($c, 'b_user_password')) {
        $st = $c->prepare('INSERT INTO b_user_password (USER_ID, PASSWORD, DATE_CHANGE) VALUES (?, ?, NOW())');
        $st->bind_param('is', $u['ID'], $hash); $st->execute();
    }
    echo "ADMIN|{$u['LOGIN']}|$pass\n";
    exit(0);
}

fwrite(STDERR, "MODE: config | db | admin\n");
exit(1);

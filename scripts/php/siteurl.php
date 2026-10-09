<?php
// Записывает адрес сайта в поля «URL сервера»: настройка main/server_name («Настройки продукта → Настройки главного
// модуля → URL сервера по умолчанию») и SERVER_NAME у каждого сайта (b_lang). Битрикс берёт его для ссылок в письмах,
// sitemap, SEO и «абсолютных» адресов; пустое значение приводит к письмам со ссылками без адреса.
// Запускается внутри php-контейнера (bx siteurl и автоматически после установки, bx https, bx clean, bx import).
// Ядро Битрикса не подключается: скрипту нужна только база. Переменные: DB_NAME, DB_USER, DB_PASSWORD, SITE_HOST
// (localhost:8090), FORCE=1 — перезаписать и заполненные значения (по умолчанию заполненные «чужие» не трогаем,
// если они не из списка локальных адресов).
// Печатает «  - что сделано»; если менять нечего — ничего.

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
$c = new mysqli('db', getenv('DB_USER'), getenv('DB_PASSWORD'), getenv('DB_NAME'));
$c->set_charset('utf8mb4');
$host = trim((string)getenv('SITE_HOST'));
if ($host === '') { fwrite(STDERR, "SITE_HOST не задан\n"); exit(1); }
$force = getenv('FORCE') === '1';

// «Локальным» считается адрес localhost / 127.0.0.1 с любым портом: его при смене порта обновляем сами. Чужой адрес
// (боевой домен, который кто-то вписал руками) без FORCE не трогаем.
$ours = fn(string $v) => $v === '' || (bool)preg_match('/^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$/i', $v);

$done = [];

// главный модуль
$old = $c->query("SELECT VALUE FROM b_option WHERE MODULE_ID='main' AND NAME='server_name' AND SITE_ID IS NULL")->fetch_row()[0] ?? null;
if ($old === null) {
    $st = $c->prepare("INSERT INTO b_option (MODULE_ID, NAME, VALUE, SITE_ID) VALUES ('main', 'server_name', ?, NULL)");
    $st->bind_param('s', $host); $st->execute();
    $done[] = "URL сервера по умолчанию (main): $host";
} elseif ($old !== $host && ($force || $ours($old))) {
    $st = $c->prepare("UPDATE b_option SET VALUE=? WHERE MODULE_ID='main' AND NAME='server_name' AND SITE_ID IS NULL");
    $st->bind_param('s', $host); $st->execute();
    $done[] = 'URL сервера по умолчанию (main): ' . ($old === '' ? 'пусто' : $old) . " → $host";
}

// каждый сайт
$cols = array_column($c->query("SHOW COLUMNS FROM b_lang")->fetch_all(MYSQLI_ASSOC), 'Field');
if (in_array('SERVER_NAME', $cols, true)) {
    foreach ($c->query('SELECT LID, SERVER_NAME FROM b_lang')->fetch_all(MYSQLI_ASSOC) as $s) {
        $cur = (string)$s['SERVER_NAME'];
        if ($cur === $host || !($force || $ours($cur))) continue;
        $st = $c->prepare('UPDATE b_lang SET SERVER_NAME=? WHERE LID=?');
        $st->bind_param('ss', $host, $s['LID']); $st->execute();
        $done[] = "URL сервера сайта {$s['LID']}: " . ($cur === '' ? 'пусто' : $cur) . " → $host";
    }
}

foreach ($done as $d) echo "  - $d\n";
echo $done ? "CHANGED\n" : '';

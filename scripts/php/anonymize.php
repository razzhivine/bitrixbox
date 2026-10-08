<?php
// Обезличивание персональных данных в базе Битрикса. Запускается внутри php-контейнера командой bx anonymize
// (и bx import --anonymize). Работает прямыми SQL-запросами: на сотнях тысяч пользователей и заказов API было бы
// слишком медленным. Каждая таблица и колонка сначала проверяется: модулей на сайте может не быть.
// DRY_RUN=1 — только посчитать. Печатает строки «  - что сделано».

mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
$c = new mysqli('db', getenv('DB_USER'), getenv('DB_PASSWORD'), getenv('DB_NAME'));
$c->set_charset('utf8mb4');
$dry = getenv('DRY_RUN') === '1';

$tables = [];
foreach ($c->query('SHOW TABLES')->fetch_all() as $r) $tables[$r[0]] = true;
$colsCache = [];
function cols(string $t): array
{
    global $c, $colsCache;
    if (!isset($colsCache[$t])) {
        $colsCache[$t] = [];
        foreach ($c->query("SHOW COLUMNS FROM `$t`")->fetch_all(MYSQLI_ASSOC) as $r) $colsCache[$t][$r['Field']] = true;
    }
    return $colsCache[$t];
}
function has(string $t, string ...$cols): bool
{
    global $tables;
    if (!isset($tables[$t])) return false;
    foreach ($cols as $col) if (!isset(cols($t)[$col])) return false;
    return true;
}
function count_rows(string $t, string $where = '1'): int
{
    global $c;
    return (int)$c->query("SELECT COUNT(*) FROM `$t` WHERE $where")->fetch_row()[0];
}
// UPDATE только по существующим колонкам: $set = ['КОЛОНКА' => 'SQL-выражение']
function update(string $t, array $set, string $where, string $what): void
{
    global $dry, $c;
    if (!has($t)) return;
    $parts = [];
    foreach ($set as $col => $expr) if (isset(cols($t)[$col])) $parts[] = "`$col`=$expr";
    if (!$parts) return;
    $n = count_rows($t, $where);
    if (!$n) return;
    if (!$dry) $c->query("UPDATE `$t` SET " . implode(', ', $parts) . " WHERE $where");
    echo "  - $what: $n\n";
}
function wipe(string $t, string $what): void
{
    global $dry, $c;
    if (!has($t)) return;
    $n = count_rows($t);
    if (!$n) return;
    if (!$dry) $c->query("DELETE FROM `$t`");
    echo "  - $what: $n (удалено)\n";
}

$email = fn(string $prefix, string $id) => "CONCAT('$prefix', $id, '@example.test')";
$phone = fn(string $id) => "CONCAT('+7999', LPAD($id, 7, '0'))";

// --- пользователи ---
// Логины-почты и логины-телефоны заменяются на bxuserID; остальные логины (admin, manager…) остаются, чтобы было
// понятно, кто есть кто. Пароли у всех становятся недействительными: вход — только по паролю, который задаст
// bx import / bx anonymize первому администратору.
update('b_user', [
    'EMAIL' => $email('user', 'ID'),
    'LOGIN' => "IF(LOGIN LIKE '%@%' OR LOGIN REGEXP '^[+0-9 ()-]{6,}$', CONCAT('bxuser', ID), LOGIN)",
    'NAME' => "'Пользователь'", 'LAST_NAME' => "CONCAT('№', ID)", 'SECOND_NAME' => "''",
    'PASSWORD' => "'bitrixbox-anonymized'", 'CHECKWORD' => "''", 'CONFIRM_CODE' => "''", 'STORED_HASH' => "NULL",
    'PERSONAL_PHONE' => "''", 'PERSONAL_MOBILE' => "''", 'PERSONAL_FAX' => "''", 'PERSONAL_PAGER' => "''",
    'PERSONAL_STREET' => "''", 'PERSONAL_MAILBOX' => "''", 'PERSONAL_ZIP' => "''", 'PERSONAL_NOTES' => "''",
    'PERSONAL_BIRTHDAY' => 'NULL', 'PERSONAL_ICQ' => "''", 'PERSONAL_WWW' => "''", 'PERSONAL_PHOTO' => 'NULL',
    'PERSONAL_PROFESSION' => "''",
    'WORK_PHONE' => "''", 'WORK_FAX' => "''", 'WORK_PAGER' => "''", 'WORK_STREET' => "''", 'WORK_MAILBOX' => "''",
    'WORK_NOTES' => "''", 'WORK_WWW' => "''", 'WORK_POSITION' => "''",
    'ADMIN_NOTES' => "''",
], '1', 'пользователи (почта, имя, телефоны, адреса, пароли)');
update('b_user_phone_auth', ['PHONE_NUMBER' => $phone('USER_ID'), 'OTP_SECRET' => 'NULL'], '1', 'телефоны для входа');
wipe('b_user_stored_auth', 'запомненные входы («Запомнить меня»)');
wipe('b_user_hit_auth', 'ссылки входа без пароля');
wipe('b_user_password', 'история паролей');
wipe('b_user_auth_code', 'коды подтверждения');
wipe('b_sec_user', 'ключи двухэтапной авторизации');
wipe('b_sec_session', 'сессии в базе');
wipe('b_socialservices_user', 'привязки соцсетей');
wipe('b_main_user_device', 'устройства пользователей');

// --- интернет-магазин ---
if (has('b_sale_order_props_value', 'ORDER_PROPS_ID', 'VALUE') && has('b_sale_order_props', 'ID', 'TYPE')) {
    $p = cols('b_sale_order_props');
    $flag = fn(string $col) => isset($p[$col]) ? "p.`$col`='Y'" : '0';
    // строковые свойства заказа (ФИО, почта, телефон, адрес, ИНН, компания…); местоположение и индекс не трогаем
    $where = "p.TYPE IN ('STRING','TEXT','TEXTAREA') AND NOT " . $flag('IS_ZIP') . " AND v.VALUE<>''";
    $expr = "CASE WHEN {$flag('IS_EMAIL')} THEN CONCAT('order', v.ORDER_ID, '@example.test')
                  WHEN {$flag('IS_PHONE')} THEN CONCAT('+7999', LPAD(v.ORDER_ID, 7, '0'))
                  WHEN {$flag('IS_PAYER')} OR {$flag('IS_PROFILE_NAME')} THEN CONCAT('Покупатель ', v.ORDER_ID)
                  ELSE 'скрыто' END";
    $n = (int)$c->query("SELECT COUNT(*) FROM b_sale_order_props_value v JOIN b_sale_order_props p ON p.ID=v.ORDER_PROPS_ID WHERE $where")->fetch_row()[0];
    if ($n) {
        if (!$dry) $c->query("UPDATE b_sale_order_props_value v JOIN b_sale_order_props p ON p.ID=v.ORDER_PROPS_ID SET v.VALUE=$expr WHERE $where");
        echo "  - свойства заказов (ФИО, почта, телефон, адрес и др.): $n\n";
    }
}
if (has('b_sale_user_props_value', 'ORDER_PROPS_ID', 'VALUE') && has('b_sale_order_props', 'ID', 'TYPE')) {
    $p = cols('b_sale_order_props');
    $where = "p.TYPE IN ('STRING','TEXT','TEXTAREA') AND v.VALUE<>''" . (isset($p['IS_ZIP']) ? " AND p.IS_ZIP<>'Y'" : '');
    $expr = isset($p['IS_EMAIL']) ? "IF(p.IS_EMAIL='Y', CONCAT('profile', v.USER_PROPS_ID, '@example.test'), 'скрыто')" : "'скрыто'";
    $n = (int)$c->query("SELECT COUNT(*) FROM b_sale_user_props_value v JOIN b_sale_order_props p ON p.ID=v.ORDER_PROPS_ID WHERE $where")->fetch_row()[0];
    if ($n) {
        if (!$dry) $c->query("UPDATE b_sale_user_props_value v JOIN b_sale_order_props p ON p.ID=v.ORDER_PROPS_ID SET v.VALUE=$expr WHERE $where");
        echo "  - профили покупателей: $n\n";
    }
}
update('b_sale_user_props', ['NAME' => "CONCAT('Профиль ', ID)"], '1', 'названия профилей покупателей');
update('b_sale_order', ['USER_DESCRIPTION' => "''", 'COMMENTS' => "''", 'ADDITIONAL_INFO' => "''", 'USER_IP' => "''"],
    '1', 'заказы (комментарии и IP покупателей)');
wipe('b_sale_order_change', 'история изменений заказов (в ней старые значения)');

// --- формы, подписки, рассылки, комментарии ---
update('b_form_result_answer', ['USER_TEXT' => "IF(USER_TEXT IS NULL OR USER_TEXT='', USER_TEXT, 'скрыто')", 'USER_TEXT_SEARCH' => "''"],
    "USER_TEXT<>''", 'ответы в веб-формах');
update('b_subscription', ['EMAIL' => $email('sub', 'ID')], '1', 'подписчики');
update('b_sender_contact', ['CODE' => "IF(TYPE_ID=2, CONCAT('+7999', LPAD(ID, 7, '0')), CONCAT('contact', ID, '@example.test'))", 'NAME' => "''"],
    '1', 'контакты рассылок');
update('b_forum_message', ['AUTHOR_EMAIL' => "''", 'AUTHOR_IP' => "''", 'AUTHOR_REAL_IP' => "''"], '1', 'сообщения форума (почта и IP авторов)');
update('b_blog_comment', ['AUTHOR_EMAIL' => "''", 'AUTHOR_IP' => "''", 'AUTHOR_IP1' => "''"], '1', 'комментарии блогов (почта и IP авторов)');
update('b_consent_user_consent', ['IP' => "'0.0.0.0'"], '1', 'согласия на обработку данных (IP)');
update('b_vote_event', ['IP' => "''"], '1', 'голосования (IP)');

// --- журналы и очереди ---
wipe('b_event', 'очередь почтовых событий');
wipe('b_event_log', 'журнал событий (IP, логины)');
foreach (['b_stat_guest' => 'посетители (статистика)', 'b_stat_session' => 'сессии (статистика)', 'b_stat_hit' => 'хиты (статистика)'] as $t => $what) {
    wipe($t, $what);
}

if ($dry) echo "  (пробный запуск: ничего не изменено)\n";

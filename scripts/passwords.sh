#!/usr/bin/env bash
# Смена паролей базы данных: пользователь БД и root.
#   bx passwords rotate    сгенерировать новые случайные пароли и применить их везде
#
# Меняется всё сразу: пользователи в самой БД, файл .env и настройки подключения Битрикса
# (bitrix/php_interface/dbconn.php и bitrix/.settings.php). Перед сменой делается снимок (bx backup).
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

[ "${1:-}" = rotate ] || { echo "Используйте: bx passwords rotate"; exit 1; }
[ -f .env ] || { echo "Нет файла .env — нечего менять"; exit 1; }

env_get() { grep "^$1=" .env | head -1 | cut -d= -f2-; }
set_env() { # set_env KEY VALUE
  if grep -q "^$1=" .env; then sed -i.bak "s#^$1=.*#$1=$2#" .env && rm -f .env.bak; else echo "$1=$2" >> .env; fi
}

for s in db php; do
  docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx "$s" || { echo "Контейнеры не запущены: bx up"; exit 1; }
done

DB_USER=$(env_get DB_USER)

# Заранее проверяем, что настройки Битрикса можно поправить: иначе после смены пароля в БД сайт бы остался сломанным.
if docker compose exec -T php test -f /var/www/html/bitrix/.settings.php </dev/null; then
  docker compose exec -T php php -r '
    $s = file_get_contents("/var/www/html/bitrix/.settings.php");
    $n = preg_match_all("/\x27password\x27\s*=>\s*\x27[^\x27]*\x27/", $s);
    if ($n !== 1) { fwrite(STDERR, ".settings.php: найдено $n значений password (ожидалось 1) — ничего не меняю\n"); exit(1); }
    $d = @file_get_contents("/var/www/html/bitrix/php_interface/dbconn.php");
    if ($d !== false && preg_match_all("/^\\\$DBPassword\\s*=/m", $d) > 1) { fwrite(STDERR, "dbconn.php: несколько \$DBPassword — ничего не меняю\n"); exit(1); }
  ' </dev/null || exit 1
fi
NEW_DB=$(openssl rand -hex 12)
NEW_ROOT=$(openssl rand -hex 12)
# Новые пароли сразу сохраняем: если скрипт оборвётся после смены в базе, они не пропадут.
( umask 077; printf 'DB_PASSWORD=%s\nDB_ROOT_PASSWORD=%s\n' "$NEW_DB" "$NEW_ROOT" > .env.rotate )
trap 'echo "Скрипт прерван. Новые пароли сохранены в .env.rotate (если смена в базе уже прошла, возьмите их оттуда); откат: bx restore" >&2' ERR

echo "== Снимок перед сменой паролей =="
bash scripts/backup.sh backup before-rotate

echo
echo "== Меняю пароли в базе данных =="
# Имена пользователей и пароли подставляются внутрь контейнера через переменные окружения
docker compose exec -T -e NEW_DB="$NEW_DB" -e NEW_ROOT="$NEW_ROOT" -e BXUSER="$DB_USER" db sh -c '
  CLI=mysql; command -v mysql >/dev/null || CLI=mariadb
  out=$($CLI -uroot -p"$MYSQL_ROOT_PASSWORD" -e "
    ALTER USER IF EXISTS \`$BXUSER\`@\`%\` IDENTIFIED BY \"$NEW_DB\";
    ALTER USER IF EXISTS \`root\`@\`%\` IDENTIFIED BY \"$NEW_ROOT\";
    ALTER USER IF EXISTS \`root\`@\`localhost\` IDENTIFIED BY \"$NEW_ROOT\";
    FLUSH PRIVILEGES;" 2>&1)
  rc=$?
  printf "%s\n" "$out" | grep -v "Using a password" || true
  exit $rc
' </dev/null
# проверка, что новый пароль пользователя БД действительно работает
docker compose exec -T -e P="$NEW_DB" -e U="$DB_USER" db sh -c 'CLI=mysql; command -v mysql >/dev/null || CLI=mariadb; $CLI -u"$U" -p"$P" -e "select 1" >/dev/null 2>&1' </dev/null \
  || { echo "Новый пароль в базе не заработал — .env и Битрикс не трогаю. Откат: bx restore"; exit 1; }
echo "  пользователь БД и root: пароли изменены"

echo
echo "== Обновляю .env и настройки подключения Битрикса =="
set_env DB_PASSWORD "$NEW_DB"
set_env DB_ROOT_PASSWORD "$NEW_ROOT"
echo "  .env: обновлён"

if docker compose exec -T php test -f /var/www/html/bitrix/php_interface/dbconn.php </dev/null; then
  docker compose exec -T -u www-data -e NEW_DB="$NEW_DB" php php -r '
    $root = "/var/www/html/bitrix";
    // dbconn.php: строка вида  $DBPassword = "…";
    $f = "$root/php_interface/dbconn.php"; $s = file_get_contents($f);
    $s2 = preg_replace("/^(\\\$DBPassword\\s*=\\s*)([\"\x27]).*?\\2\\s*;/m", "\${1}\"" . getenv("NEW_DB") . "\";", $s, -1, $n1);
    if ($n1 > 1) { fwrite(STDERR, "dbconn.php: несколько \$DBPassword — не трогаю\n"); exit(1); }
    if ($n1 === 1) file_put_contents($f, $s2);
    // .settings.php: ровно одно значение password в разделе connections
    $f = "$root/.settings.php"; $s = file_get_contents($f);
    $s2 = preg_replace("/(\x27password\x27\\s*=>\\s*)\x27[^\x27]*\x27/", "\${1}\x27" . getenv("NEW_DB") . "\x27", $s, -1, $n2);
    if ($n2 !== 1) { fwrite(STDERR, ".settings.php: найдено $n2 значений password (ожидалось 1) — не трогаю\n"); exit(1); }
    file_put_contents($f, $s2);
    echo "  Битрикс: dbconn.php (" . $n1 . "), .settings.php (" . $n2 . ") обновлены\n";
  ' </dev/null
else
  echo "  Битрикс ещё не установлен — править нечего"
fi

echo
echo "== Применяю (контейнеры пересоздадутся с новыми значениями из .env) =="
docker compose up -d </dev/null 2>&1 | grep -aE "Recreate|Started|Error" | tail -8 || true

# дождаться сайта
port=$(env_get HTTP_PORT); port=${port:-8080}
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://localhost:$port/" 2>/dev/null)
  [ -n "$code" ] && [ "$code" != 000 ] && break
  sleep 2
done

rm -f .env.rotate
trap - ERR

echo
echo "Готово. Новые пароли лежат в .env (DB_PASSWORD, DB_ROOT_PASSWORD)."
echo "Пароль пользователя БД для Adminer: $NEW_DB"
echo "Снимок до смены: bx backup list (метка before-rotate); откат: bx restore <снимок>"

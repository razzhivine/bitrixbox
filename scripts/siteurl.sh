#!/usr/bin/env bash
# Записывает адрес локального сайта в поля «URL сервера» Битрикса (main/server_name и SERVER_NAME каждого сайта).
#   bx siteurl             проставить (пустое и локальное заменяются; чужой домен, вписанный руками, остаётся)
#   bx siteurl --force     перезаписать в любом случае
#   bx siteurl --show      показать, что записано сейчас
#   bx siteurl <адрес>     записать указанный адрес (например, shop.local:8453), в том числе вместо localhost
#
# Адрес берётся из .env: если включено перенаправление на https — localhost:<HTTPS_PORT>, иначе localhost:<HTTP_PORT>
# (порты 80 и 443 без номера). Вызывается сам после установки, bx https, bx clean и bx import.
# Флаг --quiet: ничего не печатать, если менять нечего; --no-cache: не сбрасывать кеш (его сбросит вызывающий).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

FORCE=0; SHOW=0; QUIET=0; CACHE=1; HOST=""
while [ $# -gt 0 ]; do
  case $1 in
    --force)    FORCE=1 ;;
    --show)     SHOW=1 ;;
    --quiet)    QUIET=1 ;;
    --no-cache) CACHE=0 ;;
    -h|--help)  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "Неизвестный параметр: $1 (bx siteurl --help)"; exit 1 ;;
    *)          HOST=$1; FORCE=1 ;;
  esac
  shift
done

env_get() { grep "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }
[ -f .env ] || { echo "Нет .env — окружение не создано"; exit 1; }
docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx php || { [ "$QUIET" = 1 ] && exit 0; echo "Контейнеры не запущены: bx up"; exit 1; }
docker compose exec -T php test -f /var/www/html/bitrix/.settings.php </dev/null || { [ "$QUIET" = 1 ] && exit 0; echo "Битрикс ещё не установлен"; exit 1; }

if [ "$SHOW" = 1 ]; then
  docker compose exec -T db sh -c 'M=$(command -v mysql || command -v mariadb); "$M" -uroot -p"$MYSQL_ROOT_PASSWORD" --default-character-set=utf8mb4 "$MYSQL_DATABASE" -N -e "select concat(\"main (по умолчанию): \", ifnull(VALUE, \"\")) from b_option where MODULE_ID=\"main\" and NAME=\"server_name\" and SITE_ID is null; select concat(\"сайт \", LID, \": \", ifnull(SERVER_NAME, \"\")) from b_lang" 2>/dev/null' </dev/null
  exit 0
fi

if [ -z "$HOST" ]; then
  if [ -f docker/nginx/https/redirect.conf ]; then port=$(env_get HTTPS_PORT); std=443; else port=$(env_get HTTP_PORT); std=80; fi
  if [ "$port" = "$std" ] || [ -z "$port" ]; then HOST=localhost; else HOST="localhost:$port"; fi
fi

out=$(docker compose exec -T -u www-data \
  -e DB_NAME="$(env_get DB_NAME)" -e DB_USER="$(env_get DB_USER)" -e DB_PASSWORD="$(env_get DB_PASSWORD)" \
  -e SITE_HOST="$HOST" -e FORCE="$FORCE" php php < scripts/php/siteurl.php 2>&1) || { echo "$out"; echo "Не удалось записать URL сервера"; exit 1; }

if echo "$out" | grep -q '^CHANGED$'; then
  [ "$QUIET" = 1 ] || { echo "URL сервера:"; echo "$out" | grep -v '^CHANGED$'; }
  # настройки кешируются: без сброса админка ещё какое-то время показывала бы старое значение
  [ "$CACHE" = 1 ] && docker compose exec -T -u root php sh -c 'rm -rf /var/www/html/bitrix/cache/* /var/www/html/bitrix/managed_cache/* 2>/dev/null; true' </dev/null
else
  [ "$QUIET" = 1 ] || echo "URL сервера уже $HOST (или задан вручную другой: bx siteurl --force)"
fi
exit 0

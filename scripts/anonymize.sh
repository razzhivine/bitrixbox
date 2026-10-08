#!/usr/bin/env bash
# Обезличивание персональных данных в локальной базе — для копии боевого сайта.
#   bx anonymize                 показать, что изменится, спросить, сделать снимок и обезличить
#   bx anonymize --dry-run       только показать
#   bx anonymize --yes           без вопроса
#   bx anonymize --admin-password <пароль>   пароль первого администратора (по умолчанию — случайный, будет показан)
#   bx anonymize --admin-login <логин>       какому администратору задать пароль
#
# Что меняется: почта, имена, телефоны, адреса и пароли пользователей; ФИО, почта, телефон, адрес и прочие строковые
# свойства заказов и профилей покупателей; комментарии к заказам и история их изменений; ответы веб-форм;
# подписчики и контакты рассылок; почта и IP в форумах, блогах, согласиях и голосованиях; очередь писем,
# журнал событий, сессии, ключи двухэтапной авторизации, статистика посещений.
# Не меняется: товары, каталог, инфоблоки, состав и суммы заказов, пользовательские поля (UF_*),
# ключи платёжных систем и интеграций — их проверьте сами.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

DRY=0; YES=0; BACKUP=1; ADMIN=1; ADMIN_PASS=""; ADMIN_LOGIN=""
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run)        DRY=1 ;;
    --yes|-y)         YES=1 ;;
    --no-backup)      BACKUP=0 ;;
    --no-admin)       ADMIN=0 ;;
    --admin-password) ADMIN_PASS=${2:?нужен пароль}; shift ;;
    --admin-login)    ADMIN_LOGIN=${2:?нужен логин}; shift ;;
    -h|--help)        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Неизвестный параметр: $1 (bx anonymize --help)"; exit 1 ;;
  esac
  shift
done

docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx php || { echo "Контейнеры не запущены: bx up"; exit 1; }
docker compose exec -T php test -f /var/www/html/bitrix/.settings.php </dev/null || { echo "Битрикс ещё не установлен"; exit 1; }

env_get() { grep "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }
PHPENV=(-e DB_NAME="$(env_get DB_NAME)" -e DB_USER="$(env_get DB_USER)" -e DB_PASSWORD="$(env_get DB_PASSWORD)")
run() { docker compose exec -T -u www-data "${PHPENV[@]}" -e DRY_RUN="$1" php php < scripts/php/anonymize.php; }

if [ "$YES" != 1 ] || [ "$DRY" = 1 ]; then
  echo "Будет обезличено:"
  plan=$(run 1) || { echo "$plan"; exit 1; }
  echo "$plan" | grep -v 'пробный запуск'
  [ "$DRY" = 1 ] && exit 0
  echo
  read -r -p "Обезличить? Сначала сделаю снимок (bx restore вернёт). [y/N]: " yn
  [[ $yn =~ ^[yY]$ ]] || { echo "Отменено"; exit 0; }
fi

if [ "$BACKUP" = 1 ]; then
  bash scripts/backup.sh backup before-anonymize || { echo "Снимок не создан — ничего не меняю (или --no-backup)"; exit 1; }
  echo
fi

out=$(run 0) || { echo "$out"; echo "Обезличивание прервалось. Откат: bx restore"; exit 1; }
echo "$out"
docker compose exec -T -u root php sh -c 'rm -rf /var/www/html/bitrix/cache/* /var/www/html/bitrix/managed_cache/*' </dev/null

if [ "$ADMIN" = 1 ]; then
  line=$(docker compose exec -T -u www-data "${PHPENV[@]}" -e MODE=admin -e ADMIN_PASSWORD="$ADMIN_PASS" -e ADMIN_LOGIN="$ADMIN_LOGIN" php php < scripts/php/import.php 2>&1)
  if [[ $line == *ADMIN\|* ]]; then
    IFS='|' read -r _ al ap <<<"$(echo "$line" | grep '^ADMIN|' | tail -1)"
    echo
    echo "Пароли всех пользователей недействительны. Вход в админку: логин $al, пароль $ap"
  else
    echo "$line"; echo "Пароль администратора не задан — задайте: bx anonymize --no-backup --yes --admin-login <логин>"
  fi
fi

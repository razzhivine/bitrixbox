#!/usr/bin/env bash
# Агенты и почтовые события Битрикса: на хитах страниц или по расписанию (контейнер cron).
#   bitrix cron on       выполнять по расписанию (раз в минуту), на хитах не выполнять
#   bitrix cron off      вернуть выполнение на хитах
#   bitrix cron status   показать режим и состояние
set -euo pipefail
cd "$(dirname "$0")/.."

DBCONN=/var/www/html/bitrix/php_interface/dbconn.php
LINE='define("BX_CRONTAB_SUPPORT", true);'

in_php() { docker compose exec -T -u www-data php sh -c "$1" </dev/null; }

installed() { in_php "[ -f $DBCONN ]" 2>/dev/null; }
enabled()   { in_php "grep -q BX_CRONTAB_SUPPORT $DBCONN" 2>/dev/null; }

case "${1:-status}" in
  on)
    installed || { echo "Битрикс ещё не установлен — сначала пройдите установщик"; exit 1; }
    enabled || in_php "printf '\n$LINE\n' >> $DBCONN"
    docker compose up -d cron </dev/null >/dev/null 2>&1
    echo "Cron включён: агенты и почтовые события выполняются раз в минуту отдельным контейнером, на хитах — нет."
    ;;
  off)
    installed || { echo "Битрикс ещё не установлен"; exit 1; }
    in_php "sed -i '/BX_CRONTAB_SUPPORT/d' $DBCONN"
    echo "Cron выключен: агенты и почтовые события снова выполняются на хитах страниц."
    ;;
  status)
    if ! installed; then echo "Битрикс ещё не установлен"; exit 0; fi
    if enabled; then echo "Режим: по расписанию (cron)"; else echo "Режим: на хитах страниц"; fi
    docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx cron \
      && echo "Контейнер cron: работает" || echo "Контейнер cron: не запущен"
    docker compose exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" -N -e "select concat(\"Агентов: \", count(*), \", последний запуск: \", ifnull(max(LAST_EXEC), \"никогда\")) from b_agent where ACTIVE=\"Y\"" 2>/dev/null' </dev/null
    ;;
  *) echo "Используйте: bitrix cron on | off | status"; exit 1 ;;
esac

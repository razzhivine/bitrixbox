#!/usr/bin/env bash
# Снимки окружения: база + файлы сайта (том www) + папка local + .env.
#   bx backup [метка]        создать снимок в backups/snapshot-<дата>[-метка]/
#   bx backup list           показать снимки
#   bx restore [снимок]      восстановить (без параметра — выбор из списка)
set -euo pipefail
cd "$(dirname "$0")/.."

DIR=backups
EXCLUDES=(--exclude=./bitrix/cache --exclude=./bitrix/managed_cache --exclude=./bitrix/stack_cache --exclude=./bitrix/tmp --exclude=./local)

need_running() {
  docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx php \
    && docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx db \
    || { echo "Контейнеры не запущены: bx up"; exit 1; }
}

human() { du -sh "$1" 2>/dev/null | cut -f1; }

list_snapshots() { ls -1d "$DIR"/snapshot-* 2>/dev/null | sort || true; }

do_backup() { # do_backup [метка] -> путь снимка в $SNAP
  local label="${1:-}"
  need_running
  SNAP="$DIR/snapshot-$(date +%Y%m%d-%H%M%S)${label:+-$label}"
  mkdir -p "$SNAP"
  echo "== Снимок: $SNAP =="

  echo "  база данных..."
  docker compose exec -T db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines "$MYSQL_DATABASE" 2>/dev/null || mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines "$MYSQL_DATABASE"' </dev/null | gzip > "$SNAP/db.sql.gz"

  echo "  файлы сайта (без кеша)..."
  docker compose exec -T php sh -c "cd /var/www/html && tar czf - ${EXCLUDES[*]} ." </dev/null > "$SNAP/www.tar.gz"

  echo "  папка local..."
  tar czf "$SNAP/local.tar.gz" -C local .

  [ -f .env ] && cp .env "$SNAP/env"
  {
    echo "created: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "label: $label"
    grep -E '^(DISTRIB_URL|DB_IMAGE|PHP_VERSION|DB_NAME|HTTP_PORT|HTTPS_PORT)=' .env 2>/dev/null || true
  } > "$SNAP/meta.txt"

  for f in db.sql.gz www.tar.gz; do
    [ -s "$SNAP/$f" ] || { echo "Файл $f пустой — снимок не удался, удаляю"; rm -rf "$SNAP"; exit 1; }
  done
  printf "  готово: база %s, файлы %s, local %s\n" "$(human "$SNAP/db.sql.gz")" "$(human "$SNAP/www.tar.gz")" "$(human "$SNAP/local.tar.gz")"
}

pick_snapshot() { # pick_snapshot [имя|путь] -> $SNAP
  local arg="${1:-}"
  if [ -n "$arg" ]; then
    if [ -d "$arg" ]; then SNAP="${arg%/}"
    elif [ -d "$DIR/$arg" ]; then SNAP="$DIR/$arg"
    elif [ -d "$DIR/snapshot-$arg" ]; then SNAP="$DIR/snapshot-$arg"
    else echo "Снимок не найден: $arg (список: bx backup list)"; exit 1; fi
    return
  fi
  local snaps=(); while IFS= read -r l; do [ -n "$l" ] && snaps+=("$l"); done < <(list_snapshots)
  [ ${#snaps[@]} -gt 0 ] || { echo "Снимков нет. Создайте: bx backup"; exit 1; }
  echo "Снимки:"
  local i=1; for s in "${snaps[@]}"; do printf "  %d) %s  (%s)\n" "$i" "$(basename "$s")" "$(human "$s")"; i=$((i+1)); done
  local n
  while true; do
    read -r -p "Какой восстановить? [${#snaps[@]}]: " n; n=${n:-${#snaps[@]}}
    [[ $n =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le ${#snaps[@]} ] && break
    echo "Введите число от 1 до ${#snaps[@]}"
  done
  SNAP="${snaps[$((n-1))]}"
}

do_restore() {
  need_running
  pick_snapshot "${1:-}"
  for f in db.sql.gz www.tar.gz local.tar.gz; do [ -s "$SNAP/$f" ] || { echo "В снимке нет $f — восстановление невозможно"; exit 1; }; done
  echo
  echo "Будет восстановлено из $(basename "$SNAP") (создан: $(grep '^created:' "$SNAP/meta.txt" 2>/dev/null | cut -d' ' -f2-)):"
  echo "  - база данных будет пересоздана"
  echo "  - файлы сайта и папка local будут заменены"
  echo "Текущее состояние я сначала сохраню в отдельный снимок (метка pre-restore)."
  read -r -p "Введите yes для подтверждения: " yn
  [ "$yn" = yes ] || { echo "Отменено"; exit 0; }

  if [ -f "$SNAP/env" ]; then
    for k in DB_NAME DB_USER DB_PASSWORD DB_ROOT_PASSWORD; do
      a=$(grep "^$k=" .env 2>/dev/null | cut -d= -f2- || true); b=$(grep "^$k=" "$SNAP/env" | cut -d= -f2- || true)
      [ "$a" = "$b" ] || echo "ВНИМАНИЕ: $k в снимке отличается от текущего .env — настройки подключения к БД внутри снимка могут не подойти"
    done
  fi

  TARGET="$SNAP"
  echo
  do_backup pre-restore
  SAFETY="$SNAP"; SNAP="$TARGET"
  echo
  echo "== Восстановление из $(basename "$SNAP") =="

  echo "  база данных..."
  docker compose exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci" 2>/dev/null' </dev/null
  gunzip -c "$SNAP/db.sql.gz" | docker compose exec -T db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE" 2>/dev/null'

  echo "  файлы сайта..."
  docker compose exec -T -u root php sh -c 'find /var/www/html -mindepth 1 -maxdepth 1 ! -name local -exec rm -rf {} +' </dev/null
  docker compose exec -T -u root php sh -c 'tar xzf - -C /var/www/html' < "$SNAP/www.tar.gz"
  docker compose exec -T -u root php sh -c 'cd /var/www/html/bitrix && mkdir -p cache managed_cache stack_cache tmp && chown -R 33:33 cache managed_cache stack_cache tmp' </dev/null

  echo "  папка local..."
  find local -mindepth 1 -delete 2>/dev/null || true
  tar xzf "$SNAP/local.tar.gz" -C local

  docker compose restart php nginx </dev/null >/dev/null 2>&1
  echo
  echo "Готово. Состояние до восстановления сохранено: $SAFETY"
}

case "${1:-}" in
  restore) shift; do_restore "${1:-}" ;;
  backup)  shift
           if [ "${1:-}" = list ]; then list_snapshots | while read -r s; do printf "%s  (%s)\n" "$(basename "$s")" "$(human "$s")"; done
           else do_backup "${1:-}"; fi ;;
  *)       echo "Используйте: bx backup [метка|list]  /  bx restore [снимок]"; exit 1 ;;
esac

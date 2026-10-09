#!/usr/bin/env bash
# Перенос существующего сайта на Битриксе в BitrixBox и обновление локальной копии с сервера.
#
#   bx import <архив>                   резервная копия Битрикса (Настройки → Инструменты → Резервное копирование):
#                                       файл .tar.gz или .tar; части .tar.gz.1, .tar.gz.2 … рядом подхватываются сами
#   bx import <папка> [--sql дамп]      файлы сайта из папки и дамп базы (.sql или .sql.gz)
#   bx import user@host:/путь/к/сайту   забрать с сервера по SSH: файлы (tar) и база (mysqldump на сервере)
#   bx import ssh://user@host:порт/путь   то же с нестандартным портом
#
#   --sql <файл>              дамп базы (если его нет в архиве или папке)
#   --no-upload               не переносить папку upload (только SSH и папка)
#   --upload-proxy <адрес>    недостающие файлы из upload брать с этого сайта (bx upload-proxy); upload не переносится
#   --anonymize               обезличить персональные данные (bx anonymize)
#   --admin-password <пароль> задать пароль первому администратору (иначе вход — с паролями боевого сайта)
#   --ssh-opts "<параметры>"  дополнительные параметры ssh, например "-i ~/.ssh/deploy"
#   --yes                     не спрашивать подтверждение
#   параметры bx init для нового проекта: --php, --db, --project, --http-port, --db-port …
#
#   bx pull [--files] [--upload] [--no-anonymize] [--yes]
#       обновить локальную копию с сервера, с которого был bx import по SSH: всегда база,
#       с --files ещё и файлы (кроме local/ и upload/), с --upload — и upload/. Снимок перед этим делается сам.
#
# Боевой сайт не меняется: по SSH на сервере только читаются файлы и делается дамп базы.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MODE=import; [ "${1:-}" = --pull ] && { MODE=pull; shift; }

SRC=""; SQL=""; NO_UPLOAD=0; PROXY=""; ANON=""; ADMIN_PASS=""; SSH_OPTS=""; YES=0
PULL_FILES=0; PULL_UPLOAD=0; INIT_ARGS=()
while [ $# -gt 0 ]; do
  case $1 in
    --sql)            SQL=${2:?у --sql нужен файл}; shift ;;
    --no-upload)      NO_UPLOAD=1 ;;
    --upload-proxy)   PROXY=${2:?у --upload-proxy нужен адрес сайта}; NO_UPLOAD=1; shift ;;
    --anonymize)      ANON=1 ;;
    --no-anonymize)   ANON=0 ;;
    --admin-password) ADMIN_PASS=${2:?нужен пароль}; shift ;;
    --ssh-opts)       SSH_OPTS=${2:?}; shift ;;
    --files)          PULL_FILES=1 ;;
    --upload)         PULL_UPLOAD=1; PULL_FILES=1 ;;
    --yes|-y)         YES=1 ;;
    --php|--db|--project|--http-port|--https-port|--db-port|--mail-port|--adminer-port|--db-name|--db-user|--db-password|--db-root-password)
                      INIT_ARGS+=("$1" "${2:?у $1 нужно значение}"); shift ;;
    -h|--help)        sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)               echo "Неизвестный параметр: $1 (bx import --help)"; exit 1 ;;
    *)                [ -z "$SRC" ] && SRC=$1 || { echo "Лишний аргумент: $1"; exit 1; } ;;
  esac
  shift
done

env_get() { grep "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }
env_set() { # env_set KEY VALUE (значение без переводов строк)
  local tmp; tmp=$(mktemp)
  grep -v "^$1=" .env > "$tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > .env; rm -f "$tmp"
}
step() { echo; echo "== $* =="; }
die()  { echo; echo "ОШИБКА: $*"; [ -n "${SNAPSHOT:-}" ] && echo "Вернуть всё как было до импорта: bx restore $(basename "$SNAPSHOT")"; exit 1; }
dc_php()  { docker compose exec -T -u root php "$@"; }
dc_sql()  { # выполнить SQL из stdin под root в базе проекта
  docker compose exec -T db sh -c 'M=$(command -v mysql || command -v mariadb); "$M" -uroot -p"$MYSQL_ROOT_PASSWORD" --default-character-set=utf8mb4 "$MYSQL_DATABASE" 2>&1 | grep -v "Using a password"; exit 0'
}

# ---------- источник ----------
KIND=""; SSH_HOST=""; SSH_PATH=""
parse_ssh() { # ssh://user@host:port/path  или  user@host:/path
  local s=$1
  if [[ $s == ssh://* ]]; then
    s=${s#ssh://}
    local hp=${s%%/*}; SSH_PATH=/${s#*/}
    if [[ $hp == *:* ]]; then SSH_HOST=${hp%:*}; SSH_OPTS="$SSH_OPTS -p ${hp##*:}"; else SSH_HOST=$hp; fi
  else
    SSH_HOST=${s%%:*}; SSH_PATH=${s#*:}
  fi
  SSH_PATH=${SSH_PATH%/}; [ -n "$SSH_PATH" ] || SSH_PATH=/
}

if [ "$MODE" = pull ]; then
  [ -f .env ] || { echo "Нет .env — сначала bx import user@host:/путь"; exit 1; }
  saved=$(env_get IMPORT_SSH)
  [ -n "$saved" ] || { echo "Не знаю, откуда обновлять: bx pull работает после bx import по SSH (user@host:/путь)."; exit 1; }
  parse_ssh "$saved"; KIND=ssh
  [ -n "$SSH_OPTS" ] || SSH_OPTS=$(env_get IMPORT_SSH_OPTS)
  [ -n "$ANON" ] || ANON=$(env_get IMPORT_ANONYMIZE)
  [ -n "$PROXY" ] || PROXY=""
  [ "$PULL_UPLOAD" = 1 ] || NO_UPLOAD=1
else
  [ -n "$SRC" ] || { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
  if [[ $SRC == ssh://* ]] || { [ ! -e "$SRC" ] && [[ $SRC == *:* ]]; }; then
    KIND=ssh; parse_ssh "$SRC"
  elif [ -d "$SRC" ]; then
    KIND=dir; SRC=$(cd "$SRC" && pwd)
  elif [ -f "$SRC" ]; then
    KIND=archive
  else
    echo "Не найдено: $SRC (ожидается архив, папка или user@host:/путь)"; exit 1
  fi
  [ -z "$SQL" ] || [ -f "$SQL" ] || { echo "Нет файла дампа: $SQL"; exit 1; }
fi
ANON=${ANON:-0}

SSH_BASE=(ssh -o ServerAliveInterval=30 -o ConnectTimeout=15)
ssh_site() { # ssh_site check|dump|files [исключения] — scripts/remote/site.sh на сервере
  # shellcheck disable=SC2086  # SSH_OPTS — набор параметров ssh, делится на слова намеренно
  "${SSH_BASE[@]}" $SSH_OPTS "$SSH_HOST" bash -s -- "$(printf %q "$SSH_PATH")" "$@" < scripts/remote/site.sh
}

# Части архива Битрикса: имя.tar.gz, имя.tar.gz.1, имя.tar.gz.2 … (по возрастанию номера)
PARTS=()
if [ "$KIND" = archive ]; then
  base=$SRC; [[ $base =~ \.[0-9]+$ ]] && base=${base%.*}
  case "$base" in *.enc|*.enc.gz) echo "Архив зашифрован (.enc): BitrixBox не умеет его расшифровывать. Сделайте копию без шифрования."; exit 1 ;; esac
  [ -f "$base" ] || { echo "Нет первой части архива: $base"; exit 1; }
  PARTS=("$base"); i=1
  while [ -f "$base.$i" ]; do PARTS+=("$base.$i"); i=$((i+1)); done
  [ "$(head -c2 "$base" | od -An -tx1 | tr -d ' \n')" = 1f8b ] && GZ=z || GZ=""
fi

# ---------- окружение ----------
if [ ! -f .env ]; then
  step "Новое окружение (пустой сайт под импорт)"
  log=$(mktemp)
  if ! bash scripts/init.sh --defaults --edition none ${INIT_ARGS[@]+"${INIT_ARGS[@]}"} >"$log" 2>&1; then
    tail -20 "$log"; rm -f "$log"; die "bx init не удался"
  fi
  rm -f "$log"
  echo "  создан .env, контейнеры запущены"
elif [ ${#INIT_ARGS[@]} -gt 0 ]; then
  echo "Параметры окружения (${INIT_ARGS[*]}) игнорируются: .env уже есть. Начать с нуля: bx reset"
fi
for s in php db nginx; do
  docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx "$s" && continue
  echo "Запускаю контейнеры..."; docker compose up -d </dev/null >/dev/null 2>&1 || die "контейнеры не запустились (bx up)"; break
done
HAS_SITE=0
dc_php test -f /var/www/html/bitrix/modules/main/include/prolog_before.php </dev/null && HAS_SITE=1

# ---------- предварительная проверка и подтверждение ----------
step "Источник"
case $KIND in
  archive) echo "  резервная копия Битрикса: $(basename "${PARTS[0]}") (частей: ${#PARTS[@]}, $(du -ch "${PARTS[@]}" | tail -1 | cut -f1))"
           first=$(cat "${PARTS[@]}" | tar -t${GZ}f - 2>/dev/null | head -20 || true)
           if [ -z "$SQL" ] && ! echo "$first" | grep -q '^bitrix/backup/.*\.sql$'; then
             die "в начале архива нет дампа базы (bitrix/backup/*.sql). Это копия только файлов? Укажите дамп: --sql файл.sql.gz"
           fi ;;
  dir)     echo "  папка: $SRC"
           [ -f "$SRC/bitrix/.settings.php" ] || die "в папке нет bitrix/.settings.php — это не корень сайта на Битриксе"
           if [ -z "$SQL" ] && ! ls "$SRC"/bitrix/backup/*.sql >/dev/null 2>&1; then die "нужен дамп базы: --sql файл.sql.gz"; fi ;;
  ssh)     echo "  сервер: $SSH_HOST, папка сайта: $SSH_PATH"
           info=$(ssh_site check) || die "не удалось подключиться по SSH или на сервере нет сайта (проверьте: ssh $SSH_HOST)"
           IFS='|' read -r _ rhost dbh dbn dbu size usize <<<"$(echo "$info" | grep '^OK|' | tail -1)"
           echo "  сервер отвечает: $rhost; база $dbn на $dbh (пользователь $dbu)"
           echo "  размер сайта: ${size:-?}, из них upload: ${usize:-нет}" ;;
esac
if [ "$MODE" = pull ]; then
  echo "  обновится: база$([ "$PULL_FILES" = 1 ] && echo ", файлы сайта (кроме local/$([ "$PULL_UPLOAD" = 1 ] || echo " и upload/"))")"
else
  echo "  upload: $([ -n "$PROXY" ] && echo "не переносится, файлы берутся с $PROXY" || { [ "$NO_UPLOAD" = 1 ] && echo "не переносится" || echo "переносится"; })"
fi
[ "$ANON" = 1 ] && echo "  персональные данные будут обезличены (bx anonymize)"

if [ "$HAS_SITE" = 1 ] && [ "$YES" != 1 ]; then
  echo
  if [ "$MODE" = pull ]; then echo "Локальная база будет заменена базой с сервера. Перед этим сделаю снимок (bx restore вернёт)."
  else echo "Текущий сайт в этом окружении будет заменён. Перед этим сделаю снимок (bx restore вернёт)."; fi
  read -r -p "Продолжить? [y/N]: " yn
  [[ $yn =~ ^[yY]$ ]] || { echo "Отменено"; exit 0; }
fi

SNAPSHOT=""
if [ "$HAS_SITE" = 1 ]; then
  step "Снимок текущего состояния"
  bash scripts/backup.sh backup "before-$MODE" || die "снимок не создан — ничего не меняю"
  SNAPSHOT=$(ls -1d backups/snapshot-*-before-"$MODE" 2>/dev/null | sort | tail -1)
fi

# Исходные настройки сайта (с боевыми паролями) кладём рядом со снимками, не в корень сайта
KEEP=backups/$MODE-$(date +%Y%m%d-%H%M%S); mkdir -p "$KEEP"; chmod 700 "$KEEP"

# ---------- дамп с сервера: первым делом, пока локально ещё ничего не тронуто ----------
if [ "$KIND" = ssh ]; then
  step "Дамп базы на сервере"
  DUMP="$KEEP/db.sql.gz"
  echo "  mysqldump на сервере → $DUMP ..."
  ssh_site dump > "$DUMP" || die "дамп на сервере не удался — локально ничего не изменено"
  gunzip -t "$DUMP" 2>/dev/null || die "дамп пришёл повреждённым (оборвалось соединение?) — локально ничего не изменено"
  echo "  готово: $(du -h "$DUMP" | cut -f1)"
fi

# ---------- файлы ----------
FULL_FILES=1; [ "$MODE" = pull ] && [ "$PULL_FILES" = 0 ] && FULL_FILES=0
if [ "$FULL_FILES" = 1 ]; then
  step "Файлы сайта"
  if [ "$MODE" = import ]; then
    # всё, кроме local/ — это папка проекта на вашем диске
    dc_php sh -c 'find /var/www/html -mindepth 1 -maxdepth 1 ! -name local -exec rm -rf {} +' </dev/null
  fi
  case $KIND in
    archive)
      echo "  распаковываю архив..."
      # --anchored: шаблон относится только к началу пути (иначе «upload» исключил бы и папки upload внутри модулей)
      excl=(--anchored --exclude=bitrix/cache --exclude=bitrix/managed_cache --exclude=bitrix/stack_cache)
      [ "$NO_UPLOAD" = 1 ] && excl+=(--exclude=upload)
      cat "${PARTS[@]}" | dc_php tar -x${GZ}f - --ignore-zeros --no-same-owner "${excl[@]}" -C /var/www/html \
        || die "архив не распаковался (повреждён или неполный — все ли части на месте?)" ;;
    dir)
      echo "  копирую из папки..."
      excl=(--exclude=./bitrix/cache --exclude=./bitrix/managed_cache --exclude=./bitrix/stack_cache --exclude=./bitrix/tmp --exclude=./bitrix/html_pages)
      [ "$NO_UPLOAD" = 1 ] && excl+=(--exclude=./upload)
      # COPYFILE_DISABLE и --warning: tar на macOS добавляет служебные заголовки (._*, xattr), GNU tar о них предупреждает
      COPYFILE_DISABLE=1 tar -C "$SRC" -czf - "${excl[@]}" . | dc_php tar -xzf - --no-same-owner --warning=no-unknown-keyword -C /var/www/html \
        || die "не удалось скопировать файлы из $SRC" ;;
    ssh)
      ex=(); [ "$NO_UPLOAD" = 1 ] && ex+=(upload); [ "$MODE" = pull ] && ex+=(local bitrix/.settings.php bitrix/.settings_extra.php bitrix/php_interface/dbconn.php)
      echo "  загружаю с сервера (tar по SSH)$([ ${#ex[@]} -gt 0 ] && echo ", без: ${ex[*]}")..."
      ssh_site files ${ex[@]+"${ex[@]}"} | dc_php tar -xzf - --no-same-owner -C /var/www/html \
        || die "не удалось загрузить файлы с сервера" ;;
  esac
  dc_php sh -c 'cd /var/www/html && mkdir -p bitrix/cache bitrix/managed_cache bitrix/stack_cache bitrix/tmp upload
                find . -path ./local -prune -o -exec chown 33:33 {} + 2>/dev/null
                chown -R '"$(id -u):$(id -g)"' local 2>/dev/null; true' </dev/null
  dc_php test -f /var/www/html/bitrix/.settings.php </dev/null || die "после распаковки нет bitrix/.settings.php — это не сайт на Битриксе"
  echo "  готово: $(dc_php du -sh /var/www/html </dev/null | cut -f1)"
fi

# ---------- база ----------
step "База данных"
DB_IMG=$(env_get DB_IMAGE)
# Дамп с MySQL 8 содержит сортировки utf8mb4_0900_*, которых нет в MariaDB; DEFINER ссылается на пользователей сервера
fix_dump() {
  if [[ $DB_IMG == mariadb* ]]; then sed -E 's/utf8mb4_0900_[a-z_]+/utf8mb4_unicode_ci/g; s/DEFINER=`[^`]*`@`[^`]*`//g'
  else sed -E 's/DEFINER=`[^`]*`@`[^`]*`//g'; fi
}
recreate_db() {
  docker compose exec -T db sh -c 'M=$(command -v mysql || command -v mariadb); "$M" -uroot -p"$MYSQL_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$MYSQL_DATABASE\`; CREATE DATABASE \`$MYSQL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL ON \`$MYSQL_DATABASE\`.* TO \`$MYSQL_USER\`@\`%\`" 2>&1 | grep -v "Using a password"' </dev/null
}
load_db() { # stdin: SQL
  local out
  out=$( { printf 'SET FOREIGN_KEY_CHECKS=0;\nSET UNIQUE_CHECKS=0;\n'; fix_dump; } | dc_sql )
  if echo "$out" | grep -qa '^ERROR'; then echo "$out" | grep -a '^ERROR' | head -5 | sed 's/^/  /'; return 1; fi
}

if [ -n "$SQL" ]; then
  echo "  дамп: $SQL"
  recreate_db
  if [[ $SQL == *.gz ]]; then gunzip -c "$SQL"; else cat "$SQL"; fi | load_db || die "дамп не загрузился"
elif [ "$KIND" = ssh ]; then
  echo "  загружаю дамп с сервера ($(du -h "$DUMP" | cut -f1))..."
  recreate_db
  gunzip -c "$DUMP" | load_db || die "дамп не загрузился"
else
  # дамп из резервной копии Битрикса: bitrix/backup/<имя>.sql (+ .sql.1, .sql.2 …) и <имя>_after_connect.sql
  name=$(dc_php sh -c 'ls -1t /var/www/html/bitrix/backup/*.sql 2>/dev/null | grep -v _after_connect.sql | head -1' </dev/null)
  [ -n "$name" ] || die "в копии нет дампа базы (bitrix/backup/*.sql) — укажите --sql"
  echo "  дамп из резервной копии: $(basename "$name")"
  recreate_db
  dc_php sh -e -c 'f=$1; a=${f%.sql}_after_connect.sql
       [ -f "$a" ] && sed "s/<DATABASE>/$2/g" "$a"
       cat "$f"; i=1; while [ -f "$f.$i" ]; do cat "$f.$i"; i=$((i+1)); done' sh "$name" "$(env_get DB_NAME)" </dev/null \
    | load_db || die "дамп не загрузился"
  # дамп больше не нужен, а в корне сайта ему не место
  dc_php sh -c 'rm -f /var/www/html/bitrix/backup/*.sql /var/www/html/bitrix/backup/*.sql.[0-9]*' </dev/null
fi
tables=$(echo "select count(*) from information_schema.tables where table_schema=database();" | dc_sql | tail -1)
[ "${tables:-0}" -gt 10 ] 2>/dev/null || die "после загрузки в базе $tables таблиц — дамп пустой или не тот"
echo "  загружено таблиц: $tables"

# ---------- настройки ----------
step "Настройки под BitrixBox"
for f in bitrix/.settings.php bitrix/.settings_extra.php bitrix/php_interface/dbconn.php; do
  dc_php test -f "/var/www/html/$f" </dev/null && dc_php cat "/var/www/html/$f" </dev/null > "$KEEP/$(echo "$f" | tr / _)"
done
if dc_php test -f /var/www/html/bitrix/.settings_extra.php </dev/null; then
  # обычно здесь подключения к кешу и базам боевого сервера; переопределяет .settings.php
  dc_php rm -f /var/www/html/bitrix/.settings_extra.php </dev/null
  echo "  - bitrix/.settings_extra.php убран (копия: $KEEP)"
fi
PHPENV=(-e DB_NAME="$(env_get DB_NAME)" -e DB_USER="$(env_get DB_USER)" -e DB_PASSWORD="$(env_get DB_PASSWORD)")
WARNS=""
out=$(docker compose exec -T -u www-data "${PHPENV[@]}" -e MODE=config php php < scripts/php/import.php 2>&1) || { echo "$out"; die "не удалось поправить настройки сайта"; }
echo "$out" | grep -v '^WARN|'; WARNS+=$(echo "$out" | grep '^WARN|' | cut -d'|' -f2-)$'\n'
out=$(docker compose exec -T -u www-data "${PHPENV[@]}" -e MODE=db php php < scripts/php/import.php 2>&1) || { echo "$out"; die "не удалось поправить настройки в базе"; }
echo "$out" | grep -v '^WARN|'; WARNS+=$(echo "$out" | grep '^WARN|' | cut -d'|' -f2-)$'\n'
# «URL сервера» (main и каждый сайт) → локальный адрес: ссылки в письмах и абсолютные адреса поведут на копию
bash scripts/siteurl.sh --force --no-cache | grep -v '^URL сервера:$'
dc_php sh -c 'rm -rf /var/www/html/bitrix/cache/* /var/www/html/bitrix/managed_cache/* /var/www/html/bitrix/stack_cache/*' </dev/null
echo "  - кеш очищен"
echo "  исходные файлы настроек: $KEEP"

# ---------- дополнительно ----------
if [ "$ANON" = 1 ]; then
  step "Обезличивание"
  bash scripts/anonymize.sh --yes --no-backup --no-admin || die "обезличивание не удалось"
fi
ADMIN_LINE=""
if [ -n "$ADMIN_PASS" ] || [ "$ANON" = 1 ]; then
  ADMIN_LINE=$(docker compose exec -T -u www-data "${PHPENV[@]}" -e MODE=admin -e ADMIN_PASSWORD="$ADMIN_PASS" php php < scripts/php/import.php 2>&1 | grep '^ADMIN|' | tail -1)
fi
if [ -n "$PROXY" ]; then
  step "Файлы upload с сайта $PROXY"
  bash scripts/upload-proxy.sh "$PROXY" || die "не удалось включить прокси upload"
fi

# Запомнить источник для bx pull
if [ "$MODE" = import ]; then
  if [ "$KIND" = ssh ]; then
    env_set IMPORT_SSH "$SSH_HOST:$SSH_PATH"
    env_set IMPORT_SSH_OPTS "$(echo "$SSH_OPTS" | xargs)"
  fi
  env_set IMPORT_ANONYMIZE "$ANON"
fi

# ---------- проверка ----------
step "Проверка"
docker compose restart php nginx cron </dev/null >/dev/null 2>&1
port=$(env_get HTTP_PORT)
code=000
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://localhost:$port/" 2>/dev/null || true)
  [ -n "$code" ] && [ "$code" != 000 ] && break
  sleep 2
done
acode=$(curl -s -o /dev/null -m 20 -w '%{http_code}' "http://localhost:$port/bitrix/admin/" 2>/dev/null || true)
echo "  главная: HTTP $code, админка: HTTP $acode"
case $code in 2*|3*) ;; *) WARNS+="главная страница ответила $code — смотрите bx logs php"$'\n' ;; esac

WARNS=$(echo "$WARNS" | grep -v '^$' || true)
if [ -n "$WARNS" ]; then
  echo; echo "Обратите внимание:"; echo "$WARNS" | sed 's/^/  ! /'
fi
echo
echo "Готово: http://localhost:$port/"
if [ -n "$ADMIN_LINE" ]; then
  IFS='|' read -r _ al ap <<<"$ADMIN_LINE"
  echo "Вход в админку: http://localhost:$port/bitrix/admin/  логин: $al  пароль: $ap"
else
  echo "Вход в админку — с логинами и паролями боевого сайта (или задайте пароль: bx import … --admin-password)."
fi
[ -n "$SNAPSHOT" ] && echo "Состояние до $([ "$MODE" = pull ] && echo обновления || echo импорта): bx restore $(basename "$SNAPSHOT")"
[ "$KIND" = ssh ] && [ "$MODE" = import ] && echo "Обновить базу с сервера позже: bx pull   (с файлами: bx pull --files)"
dc_php grep -q BX_CRONTAB_SUPPORT /var/www/html/bitrix/php_interface/dbconn.php </dev/null \
  && echo "Агенты сайта выполняются контейнером cron (как на сервере). Выключить: bx cron off"
exit 0

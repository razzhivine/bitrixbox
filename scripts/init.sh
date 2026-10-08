#!/usr/bin/env bash
# Настройка и запуск локального окружения для 1С-Битрикс (интерактивно или по флагам).
#   bx init                      задаёт вопросы
#   bx init --defaults           без вопросов, всё по умолчанию (пароли случайные)
#   Любой вопрос можно закрыть флагом:
#     --edition web|start|standard|small_business|business
#     --db mysql-8.4|mysql-8.0|mariadb-11.4|mariadb-10.11
#     --php 8.3|8.2|8.1
#     --project имя        префикс контейнеров и томов Docker (по умолчанию — имя папки)
#     --db-name --db-user --db-password --db-root-password
#     --http-port --https-port --db-port --mail-port --adminer-port
#     --force              перезаписать существующий .env без вопроса
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=https://www.1c-bitrix.ru/download
DEFAULTS=0; FORCE=0
EDITION=""; DBSEL=""; PHP_VERSION=""; BX_PROJECT=""
DB_NAME=""; DB_USER=""; DB_PASSWORD=""; DB_ROOT_PASSWORD=""
HTTP_PORT=""; HTTPS_PORT=""; DB_PORT=""; MAIL_PORT=""; ADMINER_PORT=""

while [ $# -gt 0 ]; do
  case $1 in
    --defaults|-y)      DEFAULTS=1 ;;
    --force)            FORCE=1 ;;
    --edition)          EDITION=${2:?}; shift ;;
    --db)               DBSEL=${2:?}; shift ;;
    --php)              PHP_VERSION=${2:?}; shift ;;
    --project)          BX_PROJECT=${2:?}; shift ;;
    --db-name)          DB_NAME=${2:?}; shift ;;
    --db-user)          DB_USER=${2:?}; shift ;;
    --db-password)      DB_PASSWORD=${2:?}; shift ;;
    --db-root-password) DB_ROOT_PASSWORD=${2:?}; shift ;;
    --http-port)        HTTP_PORT=${2:?}; shift ;;
    --https-port)       HTTPS_PORT=${2:?}; shift ;;
    --db-port)          DB_PORT=${2:?}; shift ;;
    --mail-port)        MAIL_PORT=${2:?}; shift ;;
    --adminer-port)     ADMINER_PORT=${2:?}; shift ;;
    *) echo "Неизвестный параметр: $1 (список — в начале scripts/init.sh)"; exit 1 ;;
  esac
  shift
done

rand() { openssl rand -hex 12; }

# ask ПЕРЕМЕННАЯ "вопрос" "по умолчанию" [secret|random]
# Если переменная уже задана флагом — вопрос пропускается. С --defaults берётся значение по умолчанию.
ask() {
  local var=$1 question=$2 default=$3 kind=${4:-}
  if [ -n "${!var}" ]; then return; fi
  if [ "$kind" = random ]; then default=$(rand); fi
  if [ "$DEFAULTS" = 1 ]; then printf -v "$var" '%s' "$default"; return; fi
  local answer
  if [ "$kind" = random ]; then
    read -r -s -p "$question [случайный]: " answer; echo
  else
    read -r -p "$question [$default]: " answer
  fi
  printf -v "$var" '%s' "${answer:-$default}"
}

# choose ПЕРЕМЕННАЯ "заголовок" ИМЯ1 "описание1" ИМЯ2 "описание2" ...  (значение переменной — ИМЯ)
choose() {
  local var=$1 title=$2; shift 2
  local names=() descs=()
  while [ $# -gt 0 ]; do names+=("$1"); descs+=("$2"); shift 2; done
  if [ -n "${!var}" ]; then
    local n; for n in "${names[@]}"; do [ "$n" = "${!var}" ] && return; done
    echo "Недопустимое значение «${!var}». Допустимо: ${names[*]}"; exit 1
  fi
  if [ "$DEFAULTS" = 1 ]; then printf -v "$var" '%s' "${names[0]}"; return; fi
  echo; echo "$title"
  local i
  for i in "${!names[@]}"; do echo "  $((i+1))) ${descs[$i]}"; done
  local pick
  while true; do
    read -r -p "Выбор [1]: " pick; pick=${pick:-1}
    if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#names[@]} )); then
      printf -v "$var" '%s' "${names[$((pick-1))]}"; return
    fi
    echo "Введите число от 1 до ${#names[@]}"
  done
}

command -v docker >/dev/null || { echo "Docker не найден"; exit 1; }

if [ -f .env ] && [ "$FORCE" != 1 ]; then
  if [ "$DEFAULTS" = 1 ]; then
    yn=n
  else
    read -r -p ".env уже существует. Перезаписать настройки? [y/N]: " yn
  fi
  if [[ ! $yn =~ ^[yY]$ ]]; then
    echo "Оставляю текущие настройки, запускаю..."
    docker compose up -d --build
    exit 0
  fi
fi

# --- Редакция Битрикса ---
choose EDITION "Какую редакцию Битрикса ставить?" \
  web            "Веб-установщик bitrixsetup.php (редакцию выберете в браузере)" \
  start          "Старт (start)" \
  standard       "Стандарт (standard)" \
  small_business "Малый бизнес (small_business)" \
  business       "Бизнес (business)"
case $EDITION in
  web)            DISTRIB_URL="$BASE/scripts/bitrixsetup.php"; START_PATH="/bitrixsetup.php" ;;
  *)              DISTRIB_URL="$BASE/${EDITION}_encode.tar.gz"; START_PATH="/" ;;
esac

# --- СУБД ---
choose DBSEL "Какая база данных?" \
  mysql-8.4    "MySQL 8.4 LTS" \
  mysql-8.0    "MySQL 8.0" \
  mariadb-11.4 "MariaDB 11.4 LTS" \
  mariadb-10.11 "MariaDB 10.11 LTS"
DB_IMAGE="${DBSEL%%-*}:${DBSEL#*-}"

# --- PHP ---
choose PHP_VERSION "Версия PHP?" 8.3 "8.3" 8.2 "8.2" 8.1 "8.1"

# --- Проект и параметры БД ---
[ "$DEFAULTS" = 1 ] || echo
DEFAULT_PROJECT=$(basename "$PWD" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]//g')
ask BX_PROJECT       "Имя проекта (префикс контейнеров и томов Docker)" "${DEFAULT_PROJECT:-bitrixbox}"
ask DB_NAME          "Имя базы данных"        "bitrix"
ask DB_USER          "Пользователь БД"        "bitrix"
ask DB_PASSWORD      "Пароль пользователя БД" "" random
ask DB_ROOT_PASSWORD "Пароль root в БД"       "" random

# --- Порты ---
ask HTTP_PORT    "Порт сайта на хосте"  "8080"
ask HTTPS_PORT   "Порт HTTPS на хосте"  "8443"
ask DB_PORT      "Порт БД на хосте"     "3306"
ask MAIL_PORT    "Порт почты (Mailpit)" "8025"
ask ADMINER_PORT "Порт Adminer"         "8081"

cat > .env <<EOF
BX_PROJECT=$BX_PROJECT
DISTRIB_URL=$DISTRIB_URL
START_PATH=$START_PATH
DB_IMAGE=$DB_IMAGE
PHP_VERSION=$PHP_VERSION
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASSWORD
DB_ROOT_PASSWORD=$DB_ROOT_PASSWORD
HTTP_PORT=$HTTP_PORT
HTTPS_PORT=$HTTPS_PORT
DB_PORT=$DB_PORT
MAIL_PORT=$MAIL_PORT
ADMINER_PORT=$ADMINER_PORT
EOF
chmod 600 .env

echo
echo "Настройки сохранены в .env. Запускаю Docker (первый раз может занять несколько минут)..."
# Если меняли СУБД или пароли, старый том с базой мешает — предупредим
if docker volume ls -q --filter "label=com.docker.compose.project=$BX_PROJECT" </dev/null | grep -q '_db_data$'; then
  echo "ВНИМАНИЕ: том с базой уже существует. Новые имя/пароли/версия БД к нему не применятся."
  echo "Чтобы начать с чистой базы: bx reset"
fi
docker compose up -d --build

cat <<EOF

Готово! Открывайте: http://localhost:$HTTP_PORT$START_PATH

Параметры БД для установщика Битрикса:
  Сервер:       db
  База данных:  $DB_NAME
  Пользователь: $DB_USER
  Пароль:       $DB_PASSWORD
  (пароль root: $DB_ROOT_PASSWORD; все значения лежат в файле .env)

Инструменты для разработки:
  Почта сайта (все письма попадают сюда): http://localhost:$MAIL_PORT   (bx open mail)
  База данных (Adminer):                  http://localhost:$ADMINER_PORT   (bx open db)
EOF

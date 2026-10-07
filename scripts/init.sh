#!/usr/bin/env bash
# Интерактивный установщик локального окружения для 1С-Битрикс
set -euo pipefail
cd "$(dirname "$0")/.."

BASE=https://www.1c-bitrix.ru/download

ask() { # ask "вопрос" "по умолчанию" -> результат в $REPLY_VAL
  local answer
  read -r -p "$1 [$2]: " answer
  REPLY_VAL="${answer:-$2}"
}

ask_secret() {
  local answer
  read -r -s -p "$1 [$2]: " answer; echo
  REPLY_VAL="${answer:-$2}"
}

choose() { # choose "заголовок" "вариант1" "вариант2" ... -> номер в $REPLY_VAL
  local title=$1; shift
  echo; echo "$title"
  local i=1
  for opt in "$@"; do echo "  $i) $opt"; i=$((i+1)); done
  local n
  while true; do
    read -r -p "Выбор [1]: " n
    n=${n:-1}
    if [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= $# )); then REPLY_VAL=$n; return; fi
    echo "Введите число от 1 до $#"
  done
}

command -v docker >/dev/null || { echo "Docker не найден"; exit 1; }

if [ -f .env ]; then
  read -r -p ".env уже существует. Перезаписать настройки? [y/N]: " yn
  if [[ ! $yn =~ ^[yY]$ ]]; then
    echo "Оставляю текущие настройки, запускаю..."
    docker compose up -d --build
    exit 0
  fi
fi

# --- Редакция Битрикса ---
choose "Какую редакцию Битрикса ставить?" \
  "Веб-установщик bitrixsetup.php (редакцию выберете в браузере)" \
  "Старт (start)" \
  "Стандарт (standard)" \
  "Малый бизнес (small_business)" \
  "Бизнес (business)"
case $REPLY_VAL in
  1) DISTRIB_URL="$BASE/scripts/bitrixsetup.php"; START_PATH="/bitrixsetup.php" ;;
  2) DISTRIB_URL="$BASE/start_encode.tar.gz";          START_PATH="/" ;;
  3) DISTRIB_URL="$BASE/standard_encode.tar.gz";       START_PATH="/" ;;
  4) DISTRIB_URL="$BASE/small_business_encode.tar.gz"; START_PATH="/" ;;
  5) DISTRIB_URL="$BASE/business_encode.tar.gz";       START_PATH="/" ;;
esac

# --- СУБД ---
choose "Какая база данных?" \
  "MySQL 8.4 LTS" \
  "MySQL 8.0" \
  "MariaDB 11.4 LTS" \
  "MariaDB 10.11 LTS"
case $REPLY_VAL in
  1) DB_IMAGE=mysql:8.4 ;;
  2) DB_IMAGE=mysql:8.0 ;;
  3) DB_IMAGE=mariadb:11.4 ;;
  4) DB_IMAGE=mariadb:10.11 ;;
esac

# --- PHP ---
choose "Версия PHP?" "8.3" "8.2" "8.1"
case $REPLY_VAL in 1) PHP_VERSION=8.3 ;; 2) PHP_VERSION=8.2 ;; 3) PHP_VERSION=8.1 ;; esac

# --- Параметры БД ---
echo
ask        "Имя базы данных"          "bitrix";  DB_NAME=$REPLY_VAL
ask        "Пользователь БД"          "bitrix";  DB_USER=$REPLY_VAL
ask_secret "Пароль пользователя БД"   "bitrix";  DB_PASSWORD=$REPLY_VAL
ask_secret "Пароль root в БД"         "root";    DB_ROOT_PASSWORD=$REPLY_VAL

# --- Порты ---
ask "Порт сайта на хосте"  "8080"; HTTP_PORT=$REPLY_VAL
ask "Порт HTTPS на хосте"  "8443"; HTTPS_PORT=$REPLY_VAL
ask "Порт БД на хосте"     "3306"; DB_PORT=$REPLY_VAL
ask "Порт почты (Mailpit)" "8025"; MAIL_PORT=$REPLY_VAL
ask "Порт Adminer"         "8081"; ADMINER_PORT=$REPLY_VAL

cat > .env <<EOF
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

echo
echo "Настройки сохранены в .env. Запускаю Docker (первый раз может занять несколько минут)..."
# Если меняли СУБД или пароли, старый том с базой мешает — предупредим
PROJECT=$(docker compose config --format json </dev/null 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])" 2>/dev/null || basename "$PWD")
if docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT" </dev/null | grep -q '_db_data$'; then
  echo "ВНИМАНИЕ: том с базой уже существует. Новые имя/пароли/версия БД к нему не применятся."
  echo "Чтобы начать с чистой базы: bitrix reset"
fi
docker compose up -d --build

cat <<EOF

Готово! Открывайте: http://localhost:$HTTP_PORT$START_PATH

Параметры БД для установщика Битрикса:
  Сервер:       db
  База данных:  $DB_NAME
  Пользователь: $DB_USER
  Пароль:       (тот, что вы ввели)

Инструменты для разработки:
  Почта сайта (все письма попадают сюда): http://localhost:$MAIL_PORT   (bitrix open mail)
  База данных (Adminer):                  http://localhost:$ADMINER_PORT   (bitrix open db)
EOF

#!/usr/bin/env bash
# Включает HTTPS для локального сайта.
#   bx https                        спросит порт, домены и редирект, выпустит сертификат и перезапустит nginx
#   bx https --defaults             без вопросов: порт из .env, только localhost, без редиректа
#   bx https --port 8443 --domains "bitrix.local shop.local" --redirect   отдельные ответы флагами
#   bx https --off                  выключить HTTPS (вернуть только http)
#
# Сертификат: если установлен mkcert — доверенный браузеру (без предупреждений),
# иначе самоподписанный через openssl (браузер предупредит, это нормально для разработки).
set -euo pipefail
cd "$(dirname "$0")/.."

CERTS=docker/nginx/certs
CONF=docker/nginx/https

OFF=0; DEFAULTS=0; HTTPS_PORT=""; DOMAINS=""; DOMAINS_SET=0; REDIRECT=""
while [ $# -gt 0 ]; do
  case $1 in
    --off)          OFF=1 ;;
    --defaults|-y)  DEFAULTS=1 ;;
    --port)         HTTPS_PORT=${2:?}; shift ;;
    --domains)      DOMAINS=${2-}; DOMAINS_SET=1; shift ;;
    --redirect)     REDIRECT=y ;;
    *) echo "Неизвестный параметр: $1"; exit 1 ;;
  esac
  shift
done

# ask ПЕРЕМЕННАЯ "вопрос" "по умолчанию": пропускается, если значение задано флагом или стоит --defaults
ask() {
  local var=$1 question=$2 default=$3
  if [ -n "${!var}" ]; then return; fi
  if [ "$DEFAULTS" = 1 ]; then printf -v "$var" '%s' "$default"; return; fi
  local a; read -r -p "$question [$default]: " a; printf -v "$var" '%s' "${a:-$default}"
}

set_env() { # set_env KEY VALUE
  touch .env
  if grep -q "^$1=" .env; then sed -i.bak "s#^$1=.*#$1=$2#" .env && rm -f .env.bak; else echo "$1=$2" >> .env; fi
}

if [ "$OFF" = 1 ]; then
  rm -f "$CONF"/server.conf "$CONF"/redirect.conf "$CERTS"/cert.pem "$CERTS"/key.pem
  docker compose up -d nginx
  sleep 2   # файловая система Docker Desktop применяет удаление с задержкой
  docker compose exec -T nginx nginx -s reload </dev/null
  echo "HTTPS выключен, сайт доступен только по http."
  exit 0
fi

docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx nginx || { echo "Контейнеры не запущены: bx up"; exit 1; }

HTTP_PORT=$(grep '^HTTP_PORT=' .env 2>/dev/null | cut -d= -f2 || true); HTTP_PORT=${HTTP_PORT:-8080}

echo "== HTTPS для локального сайта =="
CUR_HTTPS=$(grep '^HTTPS_PORT=' .env 2>/dev/null | cut -d= -f2 || true)
ask HTTPS_PORT "Порт HTTPS на хосте" "${CUR_HTTPS:-8443}"
if [ "$DOMAINS_SET" = 0 ]; then
  if [ "$DEFAULTS" = 1 ]; then DOMAINS=""; else
    read -r -p "Дополнительные домены через пробел (например bitrix.local; пусто = только localhost) []: " DOMAINS
  fi
fi
ask REDIRECT "Перенаправлять http на https? (y/N)" "N"

mkdir -p "$CERTS" "$CONF"
NAMES=(localhost 127.0.0.1 ::1)
for d in $DOMAINS; do NAMES+=("$d"); done

echo
if command -v mkcert >/dev/null 2>&1; then
  if [ ! -f "$(mkcert -CAROOT)/rootCA.pem" ]; then
    echo "mkcert установлен, но его корневой сертификат ещё не добавлен в систему."
    if [ "$DEFAULTS" = 1 ]; then
      echo "Без вопросов не добавляю его (нужен пароль). Выполните вручную: mkcert -install"
    else
      read -r -p "Выполнить 'mkcert -install' сейчас (попросит пароль macOS)? [Y/n]: " yn
      [[ $yn =~ ^[nN]$ ]] || mkcert -install
    fi
  fi
  echo "== Сертификат через mkcert для: ${NAMES[*]} =="
  mkcert -cert-file "$CERTS/cert.pem" -key-file "$CERTS/key.pem" "${NAMES[@]}" >/dev/null 2>&1
  TRUSTED=1
else
  echo "mkcert не найден — делаю самоподписанный сертификат (браузер покажет предупреждение)."
  echo "Чтобы было без предупреждений:  brew install mkcert  и снова выполнить bx https."
  CNF=$(mktemp)
  {
    echo "[req]"; echo "distinguished_name=dn"; echo "x509_extensions=ext"; echo "prompt=no"
    echo "[dn]"; echo "CN=localhost"
    echo "[ext]"; echo "subjectAltName=@alt"; echo "basicConstraints=CA:FALSE"
    echo "[alt]"
    i=1; for n in "${NAMES[@]}"; do
      if [[ $n =~ ^[0-9.]+$ || $n == *:* ]]; then echo "IP.$i=$n"; else echo "DNS.$i=$n"; fi
      i=$((i+1))
    done
  } > "$CNF"
  openssl req -x509 -nodes -newkey rsa:2048 -days 825 -keyout "$CERTS/key.pem" -out "$CERTS/cert.pem" -config "$CNF" >/dev/null 2>&1
  rm -f "$CNF"
  TRUSTED=0
fi
chmod 600 "$CERTS/key.pem"

cat > "$CONF/server.conf" <<EOF
# создано командой bx https
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/certs/cert.pem;
    ssl_certificate_key /etc/nginx/certs/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    include /etc/nginx/bitrix.inc;
}
EOF

if [[ $REDIRECT =~ ^[yY]$ ]]; then
  echo 'return 301 https://$host:'"$HTTPS_PORT"'$request_uri;' > "$CONF/redirect.conf"
else
  rm -f "$CONF/redirect.conf"
fi

set_env HTTPS_PORT "$HTTPS_PORT"
echo "== Применяю настройки nginx =="
docker compose up -d nginx </dev/null          # откроет порт HTTPS, если контейнер был без него
sleep 2   # файловая система Docker Desktop применяет изменения с задержкой
docker compose exec -T nginx nginx -t </dev/null
docker compose exec -T nginx nginx -s reload </dev/null   # перечитать конфиг и сертификаты
sleep 1

echo
echo "Готово: https://localhost:$HTTPS_PORT/"
[ "$TRUSTED" = 1 ] || echo "(браузер предупредит о сертификате: «Дополнительно → Перейти»)"
if [[ $REDIRECT =~ ^[yY]$ ]]; then echo "http://localhost:$HTTP_PORT/ теперь перенаправляет на https"; fi

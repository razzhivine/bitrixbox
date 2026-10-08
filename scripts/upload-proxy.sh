#!/usr/bin/env bash
# Файлы из upload/, которых нет локально, nginx берёт с боевого сайта: картинки товаров и документы видны,
# а скачивать десятки гигабайт upload не нужно.
#   bx upload-proxy https://example.ru          включить (локальные файлы по-прежнему в приоритете)
#   bx upload-proxy https://example.ru --save   ещё и сохранять полученные файлы в локальный upload/
#   bx upload-proxy off                         выключить
#   bx upload-proxy                             показать состояние
#
# Настройка лежит в docker/nginx/upload/proxy.conf (не в git) и в .env (UPLOAD_PROXY).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CONF=docker/nginx/upload/proxy.conf
env_set() {
  local tmp; tmp=$(mktemp)
  grep -v "^$1=" .env > "$tmp" 2>/dev/null || true
  [ -n "$2" ] && printf '%s=%s\n' "$1" "$2" >> "$tmp"
  cat "$tmp" > .env; rm -f "$tmp"
}

reload() {
  docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx nginx || { echo "  nginx не запущен — настройка применится при bx up"; return 0; }
  # том с настройкой подключается при создании контейнера: после обновления BitrixBox его нужно пересоздать
  if ! docker compose exec -T nginx test -d /etc/nginx/upload.d </dev/null 2>/dev/null; then
    docker compose up -d nginx </dev/null >/dev/null 2>&1
  fi
  if docker compose exec -T nginx nginx -t </dev/null >/dev/null 2>&1; then
    docker compose exec -T nginx nginx -s reload </dev/null >/dev/null 2>&1
    sleep 1   # reload асинхронный: дать старым процессам nginx завершиться
  else
    docker compose exec -T nginx nginx -t </dev/null; return 1
  fi
}

case "${1:-status}" in
  status)
    if [ -f "$CONF" ]; then
      echo "Включено: недостающие файлы upload/ берутся с $(sed -n 's/^# origin: //p' "$CONF")$(grep -q proxy_store "$CONF" && echo ' и сохраняются локально')"
    else
      echo "Выключено: файлы upload/ только локальные. Включить: bx upload-proxy https://ваш-сайт.ru"
    fi
    ;;
  off)
    rm -f "$CONF"; env_set UPLOAD_PROXY ""
    reload && echo "Выключено: файлы upload/ только локальные."
    ;;
  http://*|https://*)
    url=${1%/}; save=0
    [ "${2:-}" = --save ] && save=1
    [[ $url =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo "Нужен адрес сайта без пути: https://example.ru"; exit 1; }
    mkdir -p docker/nginx/upload
    {
      echo "# origin: $url"
      echo "# Создано bx upload-proxy. Файлы upload/, которых нет локально, берутся с сайта выше."
      echo "location ^~ /upload/ {"
      echo "    location ~* \\.(php|phtml|phar)\$ { deny all; }"
      echo "    try_files \$uri @bx_upload_origin;"
      echo "}"
      echo "location @bx_upload_origin {"
      echo "    # адрес в переменной: nginx ищет его в DNS при запросе, а не при старте (иначе без сети не запустился бы)"
      echo "    resolver 127.0.0.11 valid=300s ipv6=off;"
      echo "    set \$bx_upload_origin $url;"
      echo "    proxy_pass \$bx_upload_origin;"
      echo "    proxy_ssl_server_name on;"
      echo "    proxy_set_header User-Agent \"BitrixBox upload-proxy\";"
      echo "    proxy_connect_timeout 10s;"
      if [ "$save" = 1 ]; then
        echo "    # полученный файл сохраняется в upload/, в следующий раз отдаётся локально"
        echo "    root /var/www/html;"
        echo "    proxy_store on;"
        echo "    proxy_store_access user:rw group:rw all:rw;"
      fi
      echo "}"
    } > "$CONF"
    if [ "$save" = 1 ]; then
      # nginx работает под своим пользователем: даём ему право создавать файлы и папки в upload/
      docker compose exec -T -u root php sh -c 'mkdir -p /var/www/html/upload && chmod -R a+rwX /var/www/html/upload' </dev/null \
        || echo "  не удалось открыть upload/ на запись — файлы не будут сохраняться"
    fi
    env_set UPLOAD_PROXY "$url"
    if reload; then
      echo "Включено: недостающие файлы upload/ берутся с $url$([ "$save" = 1 ] && echo ' и сохраняются в локальный upload/')."
      echo "Выключить: bx upload-proxy off"
    else
      rm -f "$CONF"; reload >/dev/null; echo "nginx не принял настройку — выключено"; exit 1
    fi
    ;;
  *) echo "Используйте: bx upload-proxy https://example.ru [--save] | off | status"; exit 1 ;;
esac

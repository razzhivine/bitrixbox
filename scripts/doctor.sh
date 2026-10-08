#!/usr/bin/env bash
# Диагностика окружения:  bx doctor
# Проверяет Docker, настройки, контейнеры, порты, ответы сайта, HTTPS, диск и состояние самого Битрикса.
# Код возврата: 0 — проблем нет, 1 — есть предупреждения.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PROBLEMS=0
ok()   { printf '  [ok]   %s\n' "$1"; }
warn() { printf '  [!!]   %s\n' "$1"; PROBLEMS=$((PROBLEMS+1)); }
info() { printf '  [i]    %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }

# значение из .env; если его там нет — то же умолчание, что в docker-compose.yml
env_get() {
  local v; v=$(grep "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-)
  if [ -z "$v" ]; then
    case $1 in HTTP_PORT) v=8080 ;; HTTPS_PORT) v=8443 ;; DB_PORT) v=3306 ;; MAIL_PORT) v=8025 ;; ADMINER_PORT) v=8081 ;; esac
  fi
  printf '%s' "$v"
}

# ---------------------------------------------------------------- Docker и настройки
section "Docker и настройки"
if docker info >/dev/null 2>&1; then ok "Docker запущен ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"; else warn "Docker не запущен — остальное проверить нельзя (bx up запустит его)"; exit 1; fi
docker compose version >/dev/null 2>&1 && ok "Docker Compose: $(docker compose version --short 2>/dev/null)" || warn "Docker Compose не найден"

if [ ! -f .env ]; then warn "Нет файла .env — выполните bx init"; exit 1; fi
ok "Проект: $(env_get BX_PROJECT), редакция: $(env_get DISTRIB_URL | sed 's#.*/##'), PHP $(env_get PHP_VERSION), БД $(env_get DB_IMAGE)"
perm=$(stat -c '%a' .env 2>/dev/null || stat -f '%Lp' .env 2>/dev/null)   # GNU (Linux), затем BSD (macOS)
[ "$perm" = 600 ] && ok ".env закрыт для других пользователей (600)" || warn ".env доступен другим пользователям (права $perm) — chmod 600 .env"
for k in DB_PASSWORD DB_ROOT_PASSWORD; do
  v=$(env_get $k)
  case "$v" in bitrix|root|password|123456|"") warn "$k слабый ($v) — смените пароль" ;; *) [ ${#v} -ge 10 ] && ok "$k: достаточной длины" || warn "$k короче 10 символов" ;; esac
done

# ---------------------------------------------------------------- контейнеры
section "Контейнеры"
services=$(docker compose config --services 2>/dev/null | grep -vx bitrix-setup)
for s in $services; do
  st=$(docker compose ps --format '{{.Service}} {{.Status}}' </dev/null 2>/dev/null | awk -v s="$s" '$1==s{ $1=""; print substr($0,2) }')
  case "$st" in
    *"Up"*"unhealthy"*) warn "$s: работает, но нездоров ($st)" ;;
    *"Up"*)             ok "$s: $st" ;;
    "")                 warn "$s: не запущен (bx up)" ;;
    *)                  warn "$s: $st" ;;
  esac
done

# ---------------------------------------------------------------- порты
section "Порты"
check_port() { # check_port ИМЯ ПОРТ СЕРВИС
  local name=$1 port=$2 svc=$3
  if docker compose ps --format '{{.Service}} {{.Ports}}' </dev/null 2>/dev/null | awk -v s="$svc" '$1==s' | grep -q ":$port->"; then
    ok "$name: $port (занят нашим контейнером)"
  elif nc -z -w1 127.0.0.1 "$port" 2>/dev/null; then
    warn "$name: порт $port занят другим процессом — измените в .env и выполните bx up"
  else
    info "$name: порт $port свободен (контейнер не запущен)"
  fi
}
check_port "HTTP"    "$(env_get HTTP_PORT)"    nginx
check_port "HTTPS"   "$(env_get HTTPS_PORT)"   nginx
check_port "БД"      "$(env_get DB_PORT)"      db
check_port "Mailpit" "$(env_get MAIL_PORT)"    mailpit
check_port "Adminer" "$(env_get ADMINER_PORT)" adminer

# ---------------------------------------------------------------- ответы сайта
section "Сайт"
HTTP_PORT=$(env_get HTTP_PORT)
if docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx nginx; then
  hdr=$(curl -s -m 10 -D - -o /tmp/bx-doctor-body.$$ "http://localhost:$HTTP_PORT/" 2>/dev/null)
  code=$(echo "$hdr" | head -1 | awk '{print $2}')
  ctype=$(echo "$hdr" | grep -i '^content-type' | head -1 | tr -d '\r' | cut -d' ' -f2-)
  body=$(head -c 200 /tmp/bx-doctor-body.$$ 2>/dev/null); rm -f /tmp/bx-doctor-body.$$
  if [ -z "$code" ]; then warn "http://localhost:$HTTP_PORT/ не отвечает"
  elif echo "$body" | grep -q '<?php'; then warn "Сервер отдаёт ИСХОДНЫЙ КОД PHP вместо страницы! Проверьте docker/nginx/bitrix.inc"
  elif echo "$ctype" | grep -qi 'octet-stream'; then warn "/ отдаётся как файл (Content-Type: $ctype) — PHP не выполняется"
  elif [ "$code" -ge 500 ] 2>/dev/null; then warn "/ отвечает $code"
  else ok "http://localhost:$HTTP_PORT/ → $code ($ctype)"; fi

  if [ -f docker/nginx/https/server.conf ]; then
    HPORT=$(env_get HTTPS_PORT)
    hcode=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://localhost:$HPORT/" 2>/dev/null)
    [ "$hcode" != 000 ] && ok "https://localhost:$HPORT/ → $hcode" || warn "HTTPS включён, но не отвечает"
    if [ -f docker/nginx/certs/cert.pem ]; then
      end=$(openssl x509 -in docker/nginx/certs/cert.pem -noout -enddate 2>/dev/null | cut -d= -f2)
      if openssl x509 -in docker/nginx/certs/cert.pem -noout -checkend $((30*86400)) >/dev/null 2>&1; then ok "Сертификат действует до $end"; else warn "Сертификат истекает скоро или уже истёк ($end) — bx https"; fi
      if curl -s -m 10 -o /dev/null "https://localhost:$HPORT/" 2>/dev/null; then ok "Сертификату доверяет система (mkcert)"; else info "Сертификат самоподписанный — браузер предупреждает (brew install mkcert и bx https уберут предупреждение)"; fi
    fi
  else
    info "HTTPS выключен (bx https включит)"
  fi
  if curl -s -m 5 -o /dev/null -w '%{http_code}' "http://localhost:$(env_get MAIL_PORT)/" 2>/dev/null | grep -q 200; then ok "Mailpit отвечает"; else warn "Mailpit не отвечает"; fi
else
  info "nginx не запущен — проверка сайта пропущена"
fi

# ---------------------------------------------------------------- Битрикс
section "Битрикс"
if docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx php; then
  while IFS='|' read -r st text; do
    [ -z "$text" ] && continue
    case "$st" in OK) ok "$text" ;; WARN) warn "$text" ;; INFO) info "$text" ;; esac
  done < <(docker compose exec -T php php < scripts/php/doctor.php 2>&1 | grep -aE '^(OK|WARN|INFO)\|')
else
  info "php не запущен — проверка Битрикса пропущена"
fi

# ---------------------------------------------------------------- диск
section "Диск"
if docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx php; then
  info "Файлы сайта (том www): $(docker compose exec -T php sh -c 'du -sh /var/www/html 2>/dev/null | cut -f1' </dev/null)"
fi
if [ -d backups ]; then
  n=$(ls -1d backups/snapshot-* 2>/dev/null | wc -l | tr -d ' ')
  sz=$(du -sh backups 2>/dev/null | cut -f1)
  kb=$(du -sk backups 2>/dev/null | cut -f1)
  info "Снимки: $n шт., всего $sz (bx backup list)"
  [ "${kb:-0}" -gt 5242880 ] && warn "Снимки занимают больше 5 ГБ — удалите ненужные из папки backups/"
fi

echo
if [ "$PROBLEMS" = 0 ]; then echo "Проблем не найдено."; else echo "Найдено замечаний: $PROBLEMS."; fi
[ "$PROBLEMS" = 0 ]

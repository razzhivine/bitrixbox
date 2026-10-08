#!/usr/bin/env bash
# Обновление платформы 1С-Битрикс (как кнопка «Обновление платформы» в админке).
#   bx update --check     показать, какие обновления доступны, ничего не меняя
#   bx update             обновить: спросит подтверждение, сделает снимок и поставит все обновления
#   bx update --yes       то же без вопроса
#   bx update --no-backup не делать снимок перед обновлением (не рекомендуется)
#
# Обновления получает только зарегистрированная копия (bx install --register ...).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CHECK=0; YES=0; BACKUP=1
while [ $# -gt 0 ]; do
  case $1 in
    --check)     CHECK=1 ;;
    --yes|-y)    YES=1 ;;
    --no-backup) BACKUP=0 ;;
    *) echo "Неизвестный параметр: $1 (bx update --check | --yes | --no-backup)"; exit 1 ;;
  esac
  shift
done

docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx php || { echo "Контейнеры не запущены: bx up"; exit 1; }
docker compose exec -T php test -f /var/www/html/bitrix/php_interface/dbconn.php </dev/null \
  || { echo "Битрикс ещё не установлен — сначала bx install"; exit 1; }

run_php() { docker compose exec -T -e MODE="$1" php php < scripts/php/update.php 2>&1; }
version() { docker compose exec -T php sh -c "grep -o 'SM_VERSION\",\"[0-9.]*' /var/www/html/bitrix/modules/main/classes/general/version.php | cut -d'\"' -f3" </dev/null | tr -d '\r\n'; }

# Ответ штатного скрипта обновления: FIN, STP0|…, STP<n>|…, ERR… или Y. Берём первый узнаваемый токен, теги убираем.
answer() {
  echo "$1" | tr -d '\r' | sed -E 's/<[^>]*>/ /g' | grep -aoE '(FIN|STP[0-9]*\|.*|ERR.*)' | head -1
}

CURRENT=$(version)
echo "Установлена версия главного модуля: ${CURRENT:-неизвестна}"

KEY=$(docker compose exec -T php sh -c 'grep -o "LICENSE_KEY *= *\"[^\"]*" /var/www/html/bitrix/license_key.php 2>/dev/null | sed "s/.*\"//"' </dev/null | tr -d '\r\n')
if [ -z "$KEY" ] || [ "$(echo "$KEY" | tr 'A-Z' 'a-z')" = demo ]; then
  echo "Внимание: копия не зарегистрирована (ключ DEMO) — сервер обновлений, скорее всего, ничего не отдаст."
  echo "Зарегистрировать: bx install --register --reg-name … --reg-surname … --reg-email … (при установке)."
fi

echo
echo "== Проверка обновлений =="
OUT=$(run_php check)
# Сначала должна обновиться сама система обновлений (клиент), как и в админке; после этого сервер отдаёт список модулей.
# Это безопасно: меняется только клиент обновлений, модули сайта не затрагиваются.
if echo "$OUT" | grep -aq '^SYS|'; then
  echo "  доступно обновление самой системы обновлений — ставлю (список модулей станет доступен после него)"
  up=$(answer "$(run_php updateupdate)")
  case "$up" in ERR*) echo "  не удалось: $up"; exit 1 ;; esac
  OUT=$(run_php check)
fi
ERRS=$(echo "$OUT" | grep -a '^ERR|' | cut -d'|' -f2-)
if [ -n "$ERRS" ]; then
  echo "$ERRS" | sed 's/^/  /'
fi
echo "$OUT" | grep -a '^SYS|' | cut -d'|' -f2- | sed 's/^/  /'
MODS=$(echo "$OUT" | grep -a '^MOD|' || true)
if [ -z "$MODS" ]; then
  [ -z "$ERRS" ] && echo "  Обновлений нет: установлена последняя версия."
  [ -n "$ERRS" ] && exit 1
  exit 0
fi
TOTAL_V=0
while IFS='|' read -r _ id n last; do
  printf "  %-18s %2s шт., до версии %s\n" "$id" "$n" "$last"
  TOTAL_V=$((TOTAL_V + n))
done <<<"$MODS"
echo "  Всего обновлений: $TOTAL_V в $(echo "$MODS" | grep -c .) модулях"
[ "$CHECK" = 1 ] && exit 0

if [ "$YES" != 1 ]; then
  echo
  read -r -p "Установить все обновления? [y/N]: " yn
  [[ $yn =~ ^[yY]$ ]] || { echo "Отменено"; exit 0; }
fi

if [ "$BACKUP" = 1 ]; then
  echo
  bash scripts/backup.sh backup before-update || { echo "Снимок не создан — обновление не начато"; exit 1; }
fi

echo
echo "== Установка обновлений =="
res=$(answer "$(run_php updateupdate)")
case "$res" in
  ERR*)  echo "  система обновлений: $res"; echo "Откат: bx restore"; exit 1 ;;
  *)     echo "  система обновлений: актуальна" ;;
esac

steps=0
while [ $steps -lt 400 ]; do
  steps=$((steps+1))
  res=$(answer "$(run_php step)")
  case "$res" in
    FIN*)  echo "  готово"; break ;;
    STP0*) : ;;                                        # промежуточная загрузка пакета, продолжаем
    STP*)  echo "  [$steps] ${res#STP}" | sed -E 's/^(  \[[0-9]+\] )[0-9]+\|/\1/' ;;
    ERR*)  echo "  Ошибка на шаге $steps: ${res#ERR}"; echo "Откат до обновления: bx restore"; exit 1 ;;
    "")    echo "  Шаг $steps: нет ответа от скрипта обновления (bx logs php)"; exit 1 ;;
    *)     echo "  Шаг $steps: неожиданный ответ: $res"; exit 1 ;;
  esac
done
[ $steps -ge 400 ] && { echo "Слишком много шагов — остановился. Проверьте: bx update --check"; exit 1; }

# сбросить кеши, чтобы админка сразу увидела новое состояние
docker compose exec -T php php < scripts/php/cache.php 2>&1 | grep -a "Кеш" || true

NEW=$(version)
echo
echo "Готово. Версия главного модуля: ${CURRENT:-?} → ${NEW:-?}"
echo "Снимок до обновления: bx backup list (метка before-update); откат: bx restore <снимок>"

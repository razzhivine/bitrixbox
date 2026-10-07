#!/usr/bin/env bash
# Удаляет демо-данные Битрикса после установки:
#   - инфоблоки целиком (элементы, разделы, сами инфоблоки и их типы)
#   - все страницы и папки в корне сайта (остаются bitrix, local, upload, urlrewrite.php, .htaccess)
#   - все шаблоны сайта, кроме .default (сайт переключается на него)
#   - демо-картинки в корне upload/
#   - модули: либо спрашивает по каждому «удалить?» (и «сохранить таблицы БД?», если модуль
#     это умеет), либо удаляет все сразу. Удаление идёт через штатный деинсталлятор (DoUninstall).
#     Защищены и не удаляются никогда: main, security, fileman, ui.
#   - остатки удалённых модулей: их настройки, пользовательские поля, почтовые типы, мастера
#     установки, временные файлы, название сайта от демо-шаблона
#   - по отдельному вопросу: файлы неустановленных модулей на диске (с архивом перед удалением)
# Остаются: служебные типы инфоблоков (rest_entity), пользователи и сам сайт (s1).
#
#   bx clean             показать план, спросить подтверждение, сделать бэкап БД и удалить
#   bx clean --dry-run   только показать, что будет удалено
#   bx clean --yes       без вопроса подтверждения
#   bx clean --no-pages  не трогать страницы и шаблоны
#   bx clean --no-content  не трогать инфоблоки
#   bx clean --keep-iblocks  удалить только элементы/разделы, инфоблоки и типы оставить
#   bx clean --iblock 2,3   только указанные инфоблоки (ID)
#   bx clean --no-modules   не спрашивать про модули (так же при --yes)
#   bx clean --modules-only только модули, без демо-данных
#   bx clean --no-leftovers не чистить остатки удалённых модулей
#   bx clean --module-files удалить файлы неустановленных модулей без вопроса
set -euo pipefail
cd "$(dirname "$0")/.."

DRY=0; YES=0; IBLOCKS=""; PAGES=1; CONTENT=1; KEEP=0; MODULES=1; LEFT=1; FILES=ask
PROTECTED=" main security fileman ui "  # дублируется в scripts/php/modules.php
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY=1 ;;
    --yes|-y)  YES=1 ;;
    --no-pages)   PAGES=0 ;;
    --no-content) CONTENT=0 ;;
    --keep-iblocks) KEEP=1 ;;
    --no-modules) MODULES=0 ;;
    --no-leftovers) LEFT=0 ;;
    --module-files) FILES=1 ;;
    --modules-only) PAGES=0; CONTENT=0 ;;
    --iblock)  IBLOCKS=${2:?нужен список ID}; shift ;;
    *) echo "Неизвестный параметр: $1"; exit 1 ;;
  esac
  shift
done

docker compose ps --status running --services 2>/dev/null </dev/null | grep -qx php || { echo "Контейнеры не запущены: bx up"; exit 1; }
docker compose exec -T php test -f /var/www/html/bitrix/modules/main/include/prolog_before.php </dev/null \
  || { echo "Битрикс ещё не установлен — сначала пройдите установщик"; exit 1; }

run_php() { # run_php <DRY_RUN 0|1>
  docker compose exec -T -e DRY_RUN="$1" -e IBLOCK_IDS="$IBLOCKS" -e PAGES="$PAGES" -e CONTENT="$CONTENT" -e KEEP_IBLOCKS="$KEEP" -e STAGE=demo php php < scripts/php/cleanup.php
}

DEMO=1; [ "$PAGES" = 0 ] && [ "$CONTENT" = 0 ] && DEMO=0

if [ "$DEMO" = 1 ]; then
  echo "== План =="
  run_php 1
fi

left_php() { # left_php <DRY_RUN 0|1> <MODULE_FILES 0|1> [PRINT_PATHS]
  docker compose exec -T -e DRY_RUN="$1" -e LEFTOVERS="$LEFT" -e MODULE_FILES="$2" -e PRINT_PATHS="${3:-0}" -e STAGE=leftovers php php < scripts/php/cleanup.php
}

module_php() { # module_php <MODE> [MODULE] [SAVEDATA]
  docker compose exec -T -e MODE="$1" -e MODULE="${2:-}" -e SAVEDATA="${3:-N}" php php < scripts/php/modules.php
}

# Модули, у которых деинсталлятор спрашивает «сохранить таблицы?»
SAVEDATA_MODULES=" $(docker compose exec -T php sh -c 'cd /var/www/html/bitrix/modules && grep -l savedata */install/index.php 2>/dev/null | cut -d/ -f1' </dev/null | tr '\n' ' ')"

TODO=() # элементы вида "id:Y|N" (Y = сохранить таблицы)
if [ "$MODULES" = 1 ]; then
  MODULE_LIST=$(module_php list | awk -F'\t' 'NF==3')
  if [ "$DRY" = 1 ] || [ "$YES" = 1 ]; then
    echo
    echo "== Установленные модули (в этом режиме не спрашиваю; запустите без --yes и --dry-run) =="
    echo "$MODULE_LIST" | awk -F'\t' -v p="$PROTECTED" '{printf "  %-20s %s (%s)%s\n", $1, $2, $3, (index(p, " " $1 " ") ? "  [защищён]" : "")}'
  else
    TOTAL=$(echo "$MODULE_LIST" | grep -c .); N=0
    echo
    echo "== Модули ($TOTAL установлено) =="
    echo "Защищены и не удаляются никогда:$PROTECTED"
    echo "Удаление идёт через штатный деинсталлятор модуля. Зависимые модули удалятся раньше."
    echo
    echo "Что делать с модулями?"
    echo "  1) спрашивать по каждому отдельно"
    echo "  2) удалить ВСЕ, кроме защищённых"
    echo "  3) не трогать модули"
    while true; do
      read -r -p "Выбор [1]: " mode; mode=${mode:-1}
      [[ $mode =~ ^[123]$ ]] && break
      echo "Введите 1, 2 или 3"
    done

    ALL_SAVE=Y
    if [ "$mode" = 2 ]; then
      read -r -p "Сохранить таблицы БД у модулей, которые это умеют? [Y/n]: " keep
      [[ $keep =~ ^[nN]$ ]] && ALL_SAVE=N
    fi

    if [ "$mode" != 3 ]; then
      while IFS=$'\t' read -r id name ver <&3; do
        N=$((N+1))
        [[ $PROTECTED == *" $id "* ]] && { [ "$mode" = 1 ] && echo "[$N/$TOTAL] $id — $name: защищён, пропускаю"; continue; }
        if [ "$mode" = 2 ]; then
          if [[ $SAVEDATA_MODULES == *" $id "* ]]; then TODO+=("$id:$ALL_SAVE"); else TODO+=("$id:N"); fi
          continue
        fi
        read -r -p "[$N/$TOTAL] $id — $name ($ver). Удалить модуль? [y/N]: " yn
        [[ $yn =~ ^[yY]$ ]] || continue
        if [[ $SAVEDATA_MODULES == *" $id "* ]]; then
          read -r -p "    Сохранить таблицы БД этого модуля? [Y/n]: " keep
          if [[ $keep =~ ^[nN]$ ]]; then TODO+=("$id:N"); else TODO+=("$id:Y"); fi
        else
          echo "    (деинсталлятор модуля не спрашивает про таблицы — он сам решает, что с ними делать)"
          TODO+=("$id:N")
        fi
      done 3<<<"$MODULE_LIST"
    fi
  fi
fi
# остатки и файлы модулей имеет смысл чистить, если что-то удаляется (демо или модули) либо явно просят файлы
LEFT_STAGE=0
if [ "$DEMO" = 1 ] || [ ${#TODO[@]} -gt 0 ] || [ "$FILES" = 1 ]; then LEFT_STAGE=1; fi
[ "$LEFT" = 0 ] && [ "$FILES" != 1 ] && LEFT_STAGE=0

if [ "$LEFT_STAGE" = 1 ] || [ "$DRY" = 1 ]; then
  echo
  echo "== Остатки и файлы модулей (показано для текущего состояния; после удаления модулей их станет больше) =="
  left_php 1 1 | grep -a -v '^FILE:'
fi

if [ "$LEFT_STAGE" = 1 ] && [ "$FILES" = ask ] && [ "$DRY" != 1 ] && [ "$YES" != 1 ]; then
  echo
  read -r -p "Удалить с диска файлы ВСЕХ неустановленных модулей (список и размер выше; перед этим сделаю архив)? [y/N]: " yn
  [[ $yn =~ ^[yY]$ ]] && FILES=1 || FILES=0
fi
[ "$FILES" = ask ] && FILES=0

[ "$DRY" = 1 ] && exit 0

if [ "$DEMO" = 0 ] && [ ${#TODO[@]} = 0 ] && [ "$LEFT_STAGE" = 0 ]; then echo "Нечего делать"; exit 0; fi

if [ "$YES" != 1 ]; then
  echo
  if [ ${#TODO[@]} -gt 0 ]; then
    echo "Модули к удалению:"
    for t in "${TODO[@]}"; do
      id=${t%%:*}
      if [[ $SAVEDATA_MODULES == *" $id "* ]]; then
        echo "  $id (таблицы: $([ "${t##*:}" = Y ] && echo сохранить || echo удалить))"
      else
        echo "  $id (таблицы: решает сам модуль)"
      fi
    done
  fi
  read -r -p "Выполнить это БЕЗ возможности восстановления файлов (бэкап сделаю только для базы)? [y/N]: " yn
  [[ $yn =~ ^[yY]$ ]] || { echo "Отменено"; exit 0; }
fi

mkdir -p backups
BACKUP="backups/bitrix-before-clean-$(date +%Y%m%d-%H%M%S).sql"
echo
echo "== Бэкап базы: $BACKUP =="
docker compose exec -T db sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction "$MYSQL_DATABASE" 2>/dev/null || mariadb-dump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction "$MYSQL_DATABASE"' </dev/null > "$BACKUP"
[ -s "$BACKUP" ] || { echo "Бэкап пустой, останавливаюсь"; rm -f "$BACKUP"; exit 1; }

if [ "$PAGES" = 1 ]; then
  PAGES_BACKUP="${BACKUP%.sql}-pages.tar"
  echo "== Бэкап страниц: $PAGES_BACKUP =="
  docker compose exec -T php sh -c 'cd /var/www/html && tar c $(ls -A | grep -vxE "bitrix|local|upload|urlrewrite.php|.htaccess") bitrix/templates $(ls -p upload | grep -v "/$" | sed "s#^#upload/#")' </dev/null > "$PAGES_BACKUP"
fi

if [ "$DEMO" = 1 ]; then
  echo
  echo "== Удаление демо-данных =="
  run_php 0
fi

if [ ${#TODO[@]} -gt 0 ]; then
  echo
  echo "== Удаление модулей =="
  PENDING=("${TODO[@]}")
  for pass in 1 2 3 4 5; do
    [ ${#PENDING[@]} = 0 ] && break
    NEXT=()
    for t in "${PENDING[@]}"; do
      id=${t%%:*}; save=${t##*:}
      res=$(module_php uninstall "$id" "$save" 2>&1 | grep '^BXRESULT' | tail -1 || true)
      if [[ $res == BXRESULT:OK:* ]]; then
        echo "  [ok]   $id — ${res#BXRESULT:OK:}"
      else
        NEXT+=("$t")
        # отложим: возможно, мешает зависимый модуль, который удалится на следующем проходе
        [ "$pass" = 5 ] && echo "  [FAIL] $id — ${res:-нет ответа от деинсталлятора}"
      fi
    done
    PENDING=("${NEXT[@]+"${NEXT[@]}"}")
  done
fi

if [ "$LEFT_STAGE" = 1 ]; then
  if [ "$FILES" = 1 ]; then
    FILES_BACKUP="${BACKUP%.sql}-modulefiles.tar.gz"
    echo
    echo "== Архив файлов модулей: $FILES_BACKUP (может занять минуту) =="
    left_php 1 1 1 | grep -a '^FILE:' | cut -c6- \
      | docker compose exec -T php sh -c 'cd /var/www/html && tar czf - -T -' > "$FILES_BACKUP"
    [ -s "$FILES_BACKUP" ] || { echo "Архив пустой, файлы модулей не трогаю"; FILES=0; }
  fi
  echo
  echo "== Очистка остатков$([ "$FILES" = 1 ] && echo " и файлов модулей") =="
  left_php 0 "$FILES" | grep -a -v '^FILE:'
fi

echo
echo "Готово. Откат (файлы из upload/ при этом не вернутся):"
echo "  база:    docker compose exec -T db sh -c 'mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" \"\$MYSQL_DATABASE\"' < $BACKUP"
[ -n "${PAGES_BACKUP:-}" ]  && echo "  страницы: docker compose exec -T -u root php tar x -C /var/www/html < $PAGES_BACKUP"
[ -n "${FILES_BACKUP:-}" ] && [ "$FILES" = 1 ] && echo "  файлы модулей: docker compose exec -T -u root php tar xz -C /var/www/html < $FILES_BACKUP"
exit 0

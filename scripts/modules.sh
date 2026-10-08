#!/usr/bin/env bash
# Модули Битрикса: список, установка, удаление, синхронизация со списком проекта.
#   bx modules                    установленные модули
#   bx modules all                все модули на диске: установлены или нет, обязательные для проекта
#   bx modules install <id…>      установить модули (недостающие зависимости ставятся на следующих проходах)
#   bx modules uninstall <id…> [--drop-tables]   удалить модули (таблицы по умолчанию сохраняются)
#   bx modules required           список обязательных модулей проекта (local/bx-modules.txt)
#   bx modules sync               поставить все обязательные модули, которых ещё нет
#
# Файл local/bx-modules.txt (по одному модулю в строке, # — комментарий) лежит в вашем проекте, в git.
# Эти модули bx clean не удаляет, а bx migrate up ставит перед применением миграций.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REQFILE=local/bx-modules.txt

required_list() { # обязательные модули проекта, по одному в строке
  [ -f "$REQFILE" ] || return 0
  sed -e 's/#.*//' -e 's/[[:space:]]//g' "$REQFILE" | grep -v '^$' | sort -u
}

need_running() {
  docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx php || { echo "Контейнеры не запущены: bx up"; exit 1; }
  docker compose exec -T php test -f /var/www/html/bitrix/modules/main/include/prolog_before.php </dev/null \
    || { echo "Битрикс ещё не установлен — сначала bx install"; exit 1; }
}

# защищённые модули: scripts/protected-modules.txt (тот же список читает scripts/clean.sh)
PROTECTED=$(sed -e 's/#.*//' -e 's/[[:space:]]//g' scripts/protected-modules.txt | grep -v '^$' | paste -sd, -)

module_php() { # module_php MODE [MODULE] [SAVEDATA]
  docker compose exec -T -e MODE="$1" -e MODULE="${2:-}" -e SAVEDATA="${3:-N}" -e PROTECTED="$PROTECTED" php php < scripts/php/modules.php 2>&1
}

# один модуль: install|uninstall -> код 0 при успехе; сообщение — в $MSG
act() {
  local action=$1 id=$2 save=${3:-N} res
  res=$(module_php "$action" "$id" "$save" | grep -a '^BXRESULT' | tail -1)
  MSG=${res#BXRESULT:*:}
  [[ $res == BXRESULT:OK:* ]]
}

# несколько проходов: модуль может не встать, пока не стоит его зависимость
# (без ассоциативных массивов: работает и в bash 3.2 на macOS)
act_many() { # act_many install|uninstall SAVE id…
  local action=$1 save=$2; shift 2
  local pending=("$@") msgs=() next nextmsgs i
  for _ in 1 2 3 4 5; do
    [ ${#pending[@]} = 0 ] && break
    next=(); nextmsgs=()
    for i in "${!pending[@]}"; do
      if act "$action" "${pending[$i]}" "$save"; then
        echo "  [ok]   ${pending[$i]} — $MSG"
      else
        next+=("${pending[$i]}"); nextmsgs+=("$MSG")
      fi
    done
    pending=(${next[@]+"${next[@]}"}); msgs=(${nextmsgs[@]+"${nextmsgs[@]}"})
  done
  [ ${#pending[@]} = 0 ] && return 0
  for i in "${!pending[@]}"; do echo "  [FAIL] ${pending[$i]} — ${msgs[$i]:-нет ответа}"; done
  return 1
}

cmd="${1:-list}"; [ $# -gt 0 ] && shift
case "$cmd" in
  list)
    need_running
    module_php list | awk -F'\t' 'NF==3 {printf "  %-22s %-44s %s\n", $1, $2, $3}'
    ;;
  all)
    need_running
    REQ=" $(required_list | tr '\n' ' ') "
    module_php list-all | awk -F'\t' -v req="$REQ" 'NF==4 {printf "  %-22s %-9s %s%s\n", $1, ($4=="Y" ? "установлен" : "—"), $3, (index(req, " " $1 " ") ? "   [обязателен для проекта]" : "")}' | sort
    ;;
  required)
    if [ ! -f "$REQFILE" ]; then echo "Файла $REQFILE нет. Создайте его: по одному модулю в строке (например, iblock)."; exit 0; fi
    need_running
    INST=" $(module_php list | awk -F'\t' 'NF==3 {print $1}' | tr '\n' ' ') "
    for m in $(required_list); do
      [[ $INST == *" $m "* ]] && echo "  $m — установлен" || echo "  $m — НЕ установлен (bx modules sync)"
    done
    ;;
  install)
    [ $# -gt 0 ] || { echo "Укажите модули: bx modules install iblock catalog"; exit 1; }
    need_running
    act_many install N "$@"
    ;;
  uninstall)
    save=Y; ids=()
    for a in "$@"; do [ "$a" = "--drop-tables" ] && save=N || ids+=("$a"); done
    [ ${#ids[@]} -gt 0 ] || { echo "Укажите модули: bx modules uninstall vote [--drop-tables]"; exit 1; }
    need_running
    act_many uninstall "$save" "${ids[@]}"
    ;;
  sync)
    need_running
    INST=" $(module_php list | awk -F'\t' 'NF==3 {print $1}' | tr '\n' ' ') "
    todo=()
    for m in $(required_list); do [[ $INST == *" $m "* ]] || todo+=("$m"); done
    if [ ${#todo[@]} = 0 ]; then echo "Все обязательные модули уже установлены ($(required_list | wc -l | tr -d ' ') шт.)"; exit 0; fi
    echo "Устанавливаю обязательные модули: ${todo[*]}"
    act_many install N "${todo[@]}"
    ;;
  *) echo "Используйте: bx modules [list | all | install <id…> | uninstall <id…> | required | sync]"; exit 1 ;;
esac

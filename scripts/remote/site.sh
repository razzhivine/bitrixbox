#!/usr/bin/env bash
# Выполняется НА СЕРВЕРЕ через ssh (bx import / bx pull передают его в `ssh хост bash -s`). Ничего не меняет на сервере.
#   site.sh <корень сайта> check                 проверить, что там Битрикс, и показать параметры
#   site.sh <корень сайта> dump                  дамп базы сайта в stdout (gzip)
#   site.sh <корень сайта> files [исключения…]   файлы сайта в stdout (tar.gz) без кеша и резервных копий
# Пароль базы читается из bitrix/.settings.php на сервере и передаётся mysqldump через переменную окружения,
# не в командной строке (её видно в списке процессов).
set -uo pipefail

ROOT=${1:?корень сайта}; MODE=${2:?режим}; shift 2
cd "$ROOT" 2>/dev/null || { echo "На сервере нет папки $ROOT" >&2; exit 2; }
[ -f bitrix/.settings.php ] || { echo "В $ROOT нет bitrix/.settings.php — это не корень сайта на Битриксе" >&2; exit 2; }

# host, database, login, password — по строке
db_params() {
  if command -v php >/dev/null 2>&1; then
    php -r '
      $c = include "bitrix/.settings.php";
      if (is_file("bitrix/.settings_extra.php")) { $e = include "bitrix/.settings_extra.php"; if (is_array($e)) $c = array_replace_recursive($c, $e); }
      $d = $c["connections"]["value"]["default"] ?? [];
      echo ($d["host"] ?? ""), "\n", ($d["database"] ?? ""), "\n", ($d["login"] ?? ""), "\n", ($d["password"] ?? ""), "\n";'
  else
    # без php на сервере: разбираем простой формат 'ключ' => 'значение'
    for k in host database login password; do
      sed -n "s/.*'$k' *=> *'\\([^']*\\)'.*/\\1/p" bitrix/.settings.php | head -1
    done
  fi
}

case "$MODE" in
  check)
    { read -r H; read -r N; read -r U; read -r _; } < <(db_params)
    echo "OK|$(hostname)|$H|$N|$U|$(du -sh . 2>/dev/null | cut -f1)|$(du -sh upload 2>/dev/null | cut -f1)"
    ;;

  dump)
    { read -r H; read -r N; read -r U; read -r P; } < <(db_params)
    [ -n "$N" ] || { echo "Не удалось прочитать параметры базы из bitrix/.settings.php" >&2; exit 3; }
    DUMP=$(command -v mysqldump || command -v mariadb-dump) || { echo "На сервере нет mysqldump" >&2; exit 3; }
    args=()
    case "$H" in
      *:/*) args+=(--socket="${H#*:}"); H=${H%%:*} ;;      # localhost:/путь/к/сокету
      *:*)  args+=(--port="${H##*:}"); H=${H%:*} ;;        # хост:порт
    esac
    export MYSQL_PWD="$P"
    err=$(mktemp)
    # --no-tablespaces: иначе обычному пользователю нужна привилегия PROCESS
    run_dump() { "$DUMP" -h"$H" -u"$U" ${args[@]+"${args[@]}"} --single-transaction --quick --no-tablespaces --default-character-set=utf8mb4 "$@" "$N" 2>"$err"; }
    # Клиент MariaDB 11 проверяет сертификат сервера и не подключается к MySQL с самоподписанным:
    # тогда пробуем ещё раз без проверки (соединение остаётся шифрованным). До первого байта дампа в stdout ничего нет.
    if ! run_dump --no-data >/dev/null && grep -qi 'ssl\|tls' "$err" && "$DUMP" --help 2>/dev/null | grep -q 'ssl-verify-server-cert'; then
      args+=(--skip-ssl-verify-server-cert)
    fi
    run_dump | gzip
    rc=${PIPESTATUS[0]}
    if [ "$rc" != 0 ]; then cat "$err" >&2; rm -f "$err"; exit "$rc"; fi
    rm -f "$err"
    ;;

  files)
    ex=(--exclude=./bitrix/cache --exclude=./bitrix/managed_cache --exclude=./bitrix/stack_cache --exclude=./bitrix/tmp
        --exclude=./bitrix/backup --exclude=./bitrix/html_pages)
    for e in "$@"; do ex+=("--exclude=./$e"); done
    err=$(mktemp)
    tar czf - "${ex[@]}" . 2>"$err"
    rc=$?
    # 1 = файл изменился во время чтения (на живом сайте это нормально)
    if [ "$rc" -gt 1 ]; then cat "$err" >&2; rm -f "$err"; exit "$rc"; fi
    rm -f "$err"
    ;;

  *) echo "Режим: check | dump | files" >&2; exit 1 ;;
esac

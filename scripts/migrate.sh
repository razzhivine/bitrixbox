#!/usr/bin/env bash
# Миграции структуры Битрикса (инфоблоки, свойства, группы, настройки…) через модуль sprint.migration — только консоль.
#   bx migrate install [--version X]   поставить модуль (по умолчанию закреплённая версия) и подготовить папку миграций
#   bx migrate add "описание"          создать файл миграции в local/php_interface/migrations
#   bx migrate ls [--new|--installed]  список миграций
#   bx migrate up [--no-backup]        применить новые: сначала bx modules sync, потом снимок (bx backup), потом миграции
#   bx migrate down [версия]           откатить
#   bx migrate redo|mark|delete|run|config …   остальные команды модуля передаются как есть
#
# Файлы миграций лежат в local/php_interface/migrations, то есть на вашем диске и в git вашего проекта.
# Сам модуль — инструмент окружения: он живёт в томе www и ставится командой bx migrate install.
# Обязательные модули проекта (например, iblock) перечисляются в local/bx-modules.txt (см. bx modules).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SPRINT_VERSION=5.15.1
MODDIR=/var/www/html/bitrix/modules/sprint.migration
MIGDIR=local/php_interface/migrations

need_running() {
  docker compose ps --status running --services </dev/null 2>/dev/null | grep -qx php || { echo "Контейнеры не запущены: bx up"; exit 1; }
  docker compose exec -T php test -f /var/www/html/bitrix/modules/main/include/prolog_before.php </dev/null \
    || { echo "Битрикс ещё не установлен — сначала bx install"; exit 1; }
}

module_present() { docker compose exec -T php test -f "$MODDIR/tools/migrate.php" </dev/null; }

# Запуск консоли модуля. С терминалом — интерактивно (конструкторы задают вопросы); без терминала ввод закрыт:
# иначе модуль ждёт ввода и не завершается.
sprint() {
  if [ -t 0 ] && [ -t 1 ]; then
    docker compose exec -u www-data php php "$MODDIR/tools/migrate.php" "$@"
  else
    docker compose exec -T -u www-data php php "$MODDIR/tools/migrate.php" "$@" </dev/null
  fi
}

cmd="${1:-help}"; [ $# -gt 0 ] && shift

case "$cmd" in
  help|-h|--help)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    ;;

  install)
    need_running
    ver=$SPRINT_VERSION
    while [ $# -gt 0 ]; do case $1 in --version) ver=${2:?}; shift ;; *) echo "Неизвестный параметр: $1"; exit 1 ;; esac; shift; done

    # Папка миграций на вашем диске: модуль берёт local/php_interface, только если она существует.
    # Права открыты, чтобы php-контейнер (www-data) мог писать в папку, созданную вашим пользователем.
    mkdir -p "$MIGDIR" && chmod -R a+rwx local 2>/dev/null || true

    if module_present; then
      echo "Модуль sprint.migration уже на диске."
    else
      echo "Скачиваю sprint.migration $ver с GitHub (около 150 КБ)..."
      docker compose exec -T -u www-data php sh -c "set -e; mkdir -p $MODDIR; curl -fsSL https://github.com/andreyryabin/sprint.migration/archive/refs/tags/$ver.tar.gz | tar xz --strip-components=1 -C $MODDIR" </dev/null \
        || { echo "Не удалось скачать версию $ver (нет такого тега или нет сети)"; exit 1; }
    fi
    bash scripts/modules.sh install sprint.migration || exit 1

    # В консоли конец запроса не наступает между операциями, и Битрикс не успевает сбросить отложенный кеш инфоблоков:
    # тип инфоблока, только что созданный миграцией, "не виден" в том же процессе (CIBlockType::GetByID), и следом
    # создание инфоблока падает с «Неверный тип блока». Отключаем эти кеши только для консольных процессов.
    docker compose exec -T -u www-data php php -r '
      $f = "/var/www/html/bitrix/php_interface/dbconn.php";
      $s = file_get_contents($f);
      if (strpos($s, "BEGIN bitrixbox-cli") !== false) { echo "  dbconn.php: блок для консоли уже есть\n"; exit(0); }
      $s = rtrim($s) . "\n\n// BEGIN bitrixbox-cli: в консоли (миграции, скрипты) без кеша инфоблоков, иначе свежие изменения не видны в том же процессе\n"
         . "if (PHP_SAPI === \x27cli\x27) {\n    define(\x27CACHED_b_iblock_type\x27, false);\n    define(\x27CACHED_b_iblock\x27, false);\n    define(\x27CACHED_b_iblock_property_enum\x27, false);\n}\n// END bitrixbox-cli\n";
      file_put_contents($f, $s);
      echo "  dbconn.php: добавлен блок для консоли\n";
    ' </dev/null || { echo "Не удалось поправить dbconn.php"; exit 1; }
    echo
    echo "Готово. Миграции будут лежать в $MIGDIR."
    echo "Начало работы:  bx migrate add \"описание\"   →  правьте up()/down()  →  bx migrate up"
    ;;

  up)
    need_running
    module_present || { echo "Модуль миграций не установлен: bx migrate install"; exit 1; }
    backup=1; args=()
    for a in "$@"; do [ "$a" = "--no-backup" ] && backup=0 || args+=("$a"); done

    # 1. обязательные модули проекта (если есть local/bx-modules.txt)
    bash scripts/modules.sh sync || { echo "Обязательные модули не установились — миграции не применяю"; exit 1; }

    # 2. есть ли что применять
    new=$(sprint ls --new | sed 's/\x1b\[[0-9;]*m//g' | grep -c 'Version[0-9]')
    if [ "$new" = 0 ]; then echo "Новых миграций нет."; exit 0; fi
    echo "Новых миграций: $new"

    # 3. снимок перед применением: если миграция что-то испортит — bx restore вернёт всё одной командой
    if [ "$backup" = 1 ]; then
      bash scripts/backup.sh backup before-migrate || { echo "Снимок не создан — миграции не применяю (или --no-backup)"; exit 1; }
      echo
    fi

    # 4. применить
    sprint up ${args[@]+"${args[@]}"}
    rc=$?
    if [ $rc != 0 ]; then
      echo
      echo "Миграции завершились с ошибкой (код $rc)."
      [ "$backup" = 1 ] && echo "Вернуть состояние до миграций: bx restore (снимок с меткой before-migrate)."
      exit $rc
    fi
    ;;

  *)
    need_running
    module_present || { echo "Модуль миграций не установлен: bx migrate install"; exit 1; }
    sprint "$cmd" "$@"
    ;;
esac

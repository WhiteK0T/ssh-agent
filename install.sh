#!/usr/bin/env bash

# Файл: install.sh. Установка, обновление и удаление SSH-меню одним Bash-скриптом.
# Управление выполняется только параметрами; исходники берутся локально или с GitHub.
# Установленная копия называется ssh-agent-setup и помнит префикс по своему пути.
# ssh-agent: managed-v1
if [[ -n "${BASH_SOURCE[0]:-}" && "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf 'Запускайте установщик отдельным процессом: bash install.sh --help\n' >&2
    return 1
fi
set -uo pipefail

SETUP_SCRIPT=${BASH_SOURCE[0]:-}
SETUP_MARKER='ssh-agent-installation-v1'
SETUP_SIGNATURE='# ssh-agent: managed-v1'
SETUP_TMP_DIR=''
SETUP_STAGE_DIR=''
SETUP_LAUNCH_STAGE=''
SETUP_MANAGER_STAGE=''
SETUP_SCRIPTS=(ssh-agent.sh lib/agent.bash lib/keys.bash lib/menu.bash lib/table.bash lib/askpass.sh)
SETUP_FILES=("${SETUP_SCRIPTS[@]}" LICENSE)

# Печатает сообщение об ошибке в stderr и возвращает код 1.
# Аргументы: части сообщения, которые printf выводит как данные.
setup_error() {
    printf 'Ошибка: %s\n' "$*" >&2
    return 1
}

# Показывает все параметры и примеры; ничего не устанавливает.
# Аргументов нет, вывод направляется в stdout.
setup_help() {
    cat <<'HELP'
Установка и удаление SSH-меню. Запуск: bash install.sh [параметры]
Без --uninstall выполняется установка или обновление.

  --uninstall        Удалить установленную программу, сохранив SSH-ключи.
  --user             Префикс ~/.local для текущего пользователя.
  --system           Системный префикс /usr/local; обычно нужны права root.
  --prefix КАТАЛОГ   Другой префикс установки, в том числе путь с пробелами.
  --source КАТАЛОГ   Установить из локальных исходников без сети.
  --repo РЕПОЗИТОРИЙ Скачать с GitHub: URL, git@github.com:owner/repo.git или owner/repo.
  --ref ВЕТКА        Ветка, тег или SHA для GitHub; по умолчанию HEAD.
  --dry-run          Только показать пути и действие, не скачивать и не менять файлы.
  --help, -h         Показать справку.

По умолчанию используются локальные файлы рядом с установщиком, если они есть,
иначе GitHub: https://github.com/WhiteK0T/ssh-agent.
Без выбора префикса: ~/.local для обычного пользователя, /usr/local для root.
Параметры --user, --system и --prefix взаимоисключающие; вопросов установщик не задаёт.

Примеры:
  bash install.sh --user
  sudo bash install.sh --system
  bash install.sh --prefix "$HOME/tools/ssh-menu"
  bash install.sh --repo WhiteK0T/ssh-agent --ref master --user
  ssh-agent-setup --uninstall
  bash install.sh --uninstall --prefix "$HOME/tools/ssh-menu"

Запуск установленного меню в Bash: source ssh-agent.sh
HELP
}

# Удаляет только временные файлы и каталоги, созданные текущим запуском.
# Вызывается ловушкой EXIT; каталоги установки и SSH-ключи не затрагиваются.
# shellcheck disable=SC2329
setup_cleanup() {
    [[ -z "$SETUP_LAUNCH_STAGE" ]] || rm -f -- "$SETUP_LAUNCH_STAGE"
    [[ -z "$SETUP_MANAGER_STAGE" ]] || rm -f -- "$SETUP_MANAGER_STAGE"
    [[ -z "$SETUP_STAGE_DIR" ]] || rm -rf -- "$SETUP_STAGE_DIR"
    [[ -z "$SETUP_TMP_DIR" ]] || rm -rf -- "$SETUP_TMP_DIR"
    return 0
}
trap 'setup_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Проверяет наличие команд из аргументов; при первой отсутствующей выдаёт ошибку.
setup_require() {
    local dependency
    for dependency in "$@"; do
        command -v "$dependency" >/dev/null || {
            case "$dependency" in
                ssh-agent | ssh-add | ssh-keygen) setup_error "Не найдена команда $dependency. Установите клиент OpenSSH." ;;
                *) setup_error "Не найдена команда $dependency." ;;
            esac
            return 1
        }
    done
}

# Определяет каталог установленного менеджера либо стандартный префикс.
# Выводит путь; установленный ssh-agent-setup сохраняет свой префикс даже под sudo.
setup_default_prefix() {
    if [[ "${SETUP_SCRIPT##*/}" == ssh-agent-setup && -f "$SETUP_SCRIPT" ]]; then
        dirname -- "$(dirname -- "$(realpath -- "$SETUP_SCRIPT")")"
    elif (( EUID == 0 )); then
        printf '/usr/local\n'
    else
        printf '%s/.local\n' "$HOME"
    fi
}

# Проверяет маркер каталога установки для префикса $1; возвращает 0 только для нашей установки.
# Содержимое маркера не исполняется; ссылки вместо каталога или маркера отклоняются.
setup_owned_package() {
    local prefix=$1 package="$1/libexec/ssh-agent" marker
    [[ -d "$package" && ! -L "$package" && -f "$package/.installation" && ! -L "$package/.installation" ]] || return 1
    marker=$(< "$package/.installation")
    [[ "$marker" == "$SETUP_MARKER"$'\n'"$prefix" ]]
}

# Проверяет подпись обычного файла $1 перед заменой или удалением запускных файлов.
setup_owned_command() {
    local content
    [[ -f "$1" && ! -L "$1" ]] || return 1
    content=$(< "$1")
    [[ "$content" == *"$SETUP_SIGNATURE"* ]]
}

# До изменений проверяет, что целевые пути префикса $1 свободны или принадлежат нам.
# Существующие посторонние файлы, ссылки и каталоги вместо модулей не заменяются.
setup_check_destination() {
    local prefix=$1 package="$1/libexec/ssh-agent" file target
    if [[ -e "$package" || -L "$package" ]]; then
        setup_owned_package "$prefix" || {
            setup_error "Каталог не принадлежит этому установщику: $package"
            return 1
        }
        [[ ! -L "$package/lib" && ( ! -e "$package/lib" || -d "$package/lib" ) ]] || {
            setup_error "Некорректный каталог модулей: $package/lib"
            return 1
        }
        for file in "${SETUP_FILES[@]}"; do
            target="$package/$file"
            if [[ -e "$target" || -L "$target" ]]; then
                [[ -f "$target" && ! -L "$target" ]] || {
                    setup_error "Вместо файла установлен каталог или ссылка: $target"
                    return 1
                }
            fi
        done
    fi
    for file in ssh-agent.sh ssh-agent-setup; do
        target="$prefix/bin/$file"
        if [[ -e "$target" || -L "$target" ]]; then
            if ! setup_owned_package "$prefix" || ! setup_owned_command "$target"; then
                setup_error "Посторонний запускной файл не будет изменён: $target"
                return 1
            fi
        fi
    done
}

# Загружает URL из $1 в файл $2 через curl или wget с проверкой ошибок HTTP.
setup_download() {
    if command -v curl >/dev/null; then
        curl --fail --location --silent --show-error --connect-timeout 15 --max-time 120 --output "$2" -- "$1"
    elif command -v wget >/dev/null; then
        wget --quiet --timeout=30 --tries=2 --output-document="$2" -- "$1"
    else
        setup_error 'Для скачивания с GitHub нужен curl или wget; локально используйте --source.'
    fi
}

# Скачивает один снимок GitHub и извлекает только известные файлы в каталог $3.
# Аргументы: $1 — репозиторий, $2 — ветка/тег/SHA, $3 — каталог исходников.
# tar пишет содержимое выбранных файлов в stdout, поэтому пути архива не извлекаются в ФС.
setup_github_source() {
    local repo=$1 ref=$2 source=$3 archive="$SETUP_TMP_DIR/source.tar.gz" listing root file
    repo=${repo#https://github.com/}
    repo=${repo#git@github.com:}
    repo=${repo%/}
    repo=${repo%.git}
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$repo" != *'..'* ]] || {
        setup_error 'Для --repo укажите GitHub-репозиторий в виде owner/repo или его URL.'
        return 1
    }
    [[ "$ref" =~ ^[A-Za-z0-9_./-]+$ && "$ref" != *'..'* && "$ref" != /* ]] || {
        setup_error 'Некорректное значение --ref.'
        return 1
    }
    setup_require tar || return 1
    printf 'Скачивание %s (%s)…\n' "$repo" "$ref"
    setup_download "https://codeload.github.com/$repo/tar.gz/$ref" "$archive" || {
        setup_error 'Не удалось скачать исходники. Проверьте публикацию репозитория и --ref; для закрытого репозитория используйте локальный клон.'
        return 1
    }
    listing=$(tar -tzf "$archive") || return 1
    root=${listing%%$'\n'*}
    root=${root%/}
    [[ "$root" =~ ^[A-Za-z0-9_.-]+$ && "$root" != . && "$root" != .. ]] || {
        setup_error 'Неожиданная структура архива GitHub.'
        return 1
    }
    mkdir -p -- "$source/lib" || return 1
    for file in "${SETUP_FILES[@]}" install.sh; do
        tar -xOzf "$archive" -- "$root/$file" > "$source/$file" || return 1
    done
}

# Проверяет полноту локальных или скачанных исходников: $1 — каталог, $2 — установщик.
# Не запускает полученный код: проверяется только синтаксис Bash и обычные читаемые файлы.
setup_validate_source() {
    local source=$1 manager=$2 file
    for file in "${SETUP_FILES[@]}"; do
        [[ -f "$source/$file" && -r "$source/$file" && -s "$source/$file" && ! -L "$source/$file" ]] || {
            setup_error "Отсутствует обычный читаемый файл: $source/$file"
            return 1
        }
    done
    for file in "${SETUP_SCRIPTS[@]}"; do
        bash -n "$source/$file" || return 1
    done
    [[ -f "$manager" && -r "$manager" && ! -L "$manager" ]] || {
        setup_error "Не найден установщик: $manager"
        return 1
    }
    bash -n "$manager" || return 1
    setup_owned_command "$manager" || {
        setup_error "Установщик источника не содержит ожидаемую подпись: $manager"
        return 1
    }
}

# Создаёт каталог $1 с правами 755, не меняя режим уже существующего каталога.
setup_directory() {
    [[ -d "$1" ]] || install -d -m 755 -- "$1"
}

# Собирает и устанавливает программу для префикса $1 из исходников $2 и установщика $3.
# Сначала готовит все файлы во временных каталогах, затем заменяет только известные файлы.
# Посторонние файлы внутри уже установленного пакета сохраняются при обновлении.
setup_install() {
    local prefix=$1 source=$2 manager=$3 package="$1/libexec/ssh-agent" file mode
    setup_require install mv || return 1
    setup_check_destination "$prefix" || return 1
    setup_directory "$prefix/bin" && setup_directory "$prefix/libexec" || return 1
    SETUP_STAGE_DIR=$(mktemp -d "$prefix/libexec/.ssh-agent.XXXXXX") || return 1
    install -d -m 755 -- "$SETUP_STAGE_DIR/lib" || return 1
    for file in "${SETUP_FILES[@]}"; do
        mode=644
        [[ "$file" != lib/askpass.sh ]] || mode=755
        install -m "$mode" -- "$source/$file" "$SETUP_STAGE_DIR/$file" || return 1
    done
    printf '%s\n%s\n' "$SETUP_MARKER" "$prefix" > "$SETUP_STAGE_DIR/.installation" || return 1
    chmod 644 "$SETUP_STAGE_DIR/.installation" && chmod 755 "$SETUP_STAGE_DIR" || return 1
    SETUP_LAUNCH_STAGE=$(mktemp "$prefix/bin/.ssh-agent.XXXXXX") || return 1
    {
        printf '#!/usr/bin/env bash\n\n%s\n' "$SETUP_SIGNATURE"
        printf '# Файл: ssh-agent.sh. Подключает установленное SSH-меню в текущем Bash.\n'
        cat <<'LAUNCHER'
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'Запустите в текущем Bash: source ssh-agent.sh\n' >&2
    exit 1
fi
LAUNCHER
        printf 'source %q "$@"\n' "$package/ssh-agent.sh"
    } > "$SETUP_LAUNCH_STAGE" || return 1
    chmod 755 "$SETUP_LAUNCH_STAGE" || return 1
    SETUP_MANAGER_STAGE=$(mktemp "$prefix/bin/.ssh-agent-setup.XXXXXX") || return 1
    install -m 755 -- "$manager" "$SETUP_MANAGER_STAGE" || return 1

    if [[ -d "$package" ]]; then
        setup_directory "$package/lib" || return 1
        for file in "${SETUP_FILES[@]}" .installation; do
            mv -f -- "$SETUP_STAGE_DIR/$file" "$package/$file" || return 1
        done
    else
        mv -- "$SETUP_STAGE_DIR" "$package" || return 1
        SETUP_STAGE_DIR=''
    fi
    mv -f -- "$SETUP_LAUNCH_STAGE" "$prefix/bin/ssh-agent.sh" || return 1
    SETUP_LAUNCH_STAGE=''
    mv -f -- "$SETUP_MANAGER_STAGE" "$prefix/bin/ssh-agent-setup" || return 1
    SETUP_MANAGER_STAGE=''
    printf 'Установлено в %s\n' "$prefix"
    printf 'Запуск: source %q\n' "$prefix/bin/ssh-agent.sh"
    if [[ ":$PATH:" != *":$prefix/bin:"* ]]; then
        # shellcheck disable=SC2016 # Печатаем команду с буквальным $PATH для пользователя.
        printf 'Чтобы запускать по имени, добавьте в PATH:\n  export PATH=%q:"$PATH"\n' "$prefix/bin"
    else
        printf 'Запуск по имени: source ssh-agent.sh\n'
    fi
    printf 'Удаление: %q --uninstall\n' "$prefix/bin/ssh-agent-setup"
}

# Удаляет только известные файлы нашей установки по префиксу $1, не обращаясь к сети.
# Сохраняет SSH-ключи, окружение оболочки и посторонние файлы; повторное удаление допустимо.
setup_uninstall() {
    local prefix=$1 package="$1/libexec/ssh-agent" file remaining=0
    setup_check_destination "$prefix" || return 1
    if [[ ! -e "$package" ]]; then
        printf 'Установка не найдена: %s\n' "$prefix"
        return 0
    fi
    for file in "$prefix/bin" "$package" "$package/lib"; do
        if [[ -d "$file" && ( ! -w "$file" || ! -x "$file" ) ]]; then
            setup_error "Недостаточно прав для удаления из $file; для системной установки используйте sudo."
            return 1
        fi
    done
    for file in "${SETUP_FILES[@]}"; do
        rm -f -- "$package/$file" || return 1
    done
    rm -f -- "$prefix/bin/ssh-agent.sh" "$prefix/bin/ssh-agent-setup" || return 1
    rmdir -- "$package/lib" 2>/dev/null || :
    for file in "$package"/* "$package"/.[!.]* "$package"/..?*; do
        [[ -e "$file" || -L "$file" ]] || continue
        [[ "$file" != "$package/.installation" ]] || continue
        remaining=1
        break
    done
    if (( remaining )); then
        printf 'Дополнительные файлы сохранены в %s\n' "$package"
    else
        rm -f -- "$package/.installation" && rmdir -- "$package" || return 1
    fi
    printf 'Программа удалена из %s. SSH-ключи и работающие агенты сохранены.\n' "$prefix"
}

# Разбирает параметры, выбирает источник и выполняет установку либо удаление.
# Аргументы — флаги из --help; при ошибке возвращает 1, при успехе 0.
setup_main() {
    local action=install destination='' prefix='' source='' source_set=0 repo='WhiteK0T/ssh-agent'
    local remote=0 ref=HEAD dry_run=0 manager script_dir=''
    while (( $# > 0 )); do
        case "$1" in
            --help | -h) setup_help; return 0 ;;
            --uninstall) action=uninstall; shift ;;
            --user | --system | --prefix)
                [[ -z "$destination" ]] || { setup_error '--user, --system и --prefix взаимоисключающие.'; return 1; }
                destination=$1
                case "$1" in
                    --user) prefix="$HOME/.local"; shift ;;
                    --system) prefix=/usr/local; shift ;;
                    --prefix)
                        (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || { setup_error '--prefix требует каталог.'; return 1; }
                        prefix=$2; shift 2 ;;
                esac
                ;;
            --source | --repo | --ref)
                (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || { setup_error "$1 требует значение."; return 1; }
                case "$1" in
                    --source) source=$2; source_set=1 ;;
                    --repo) repo=$2; remote=1 ;;
                    --ref) ref=$2; remote=1 ;;
                esac
                shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            *) setup_error "Неизвестный параметр: $1. Справка: --help"; return 1 ;;
        esac
    done
    (( source_set == 0 || remote == 0 )) || { setup_error '--source нельзя сочетать с --repo или --ref.'; return 1; }
    [[ "$action" != uninstall || "$source_set $remote" == '0 0' ]] || { setup_error 'При удалении источник не используется.'; return 1; }
    setup_require realpath dirname mktemp rm rmdir || return 1
    [[ -n "$prefix" ]] || prefix=$(setup_default_prefix) || return 1
    [[ "$prefix" != *$'\n'* && "$prefix" != *$'\r'* ]] || { setup_error 'Переводы строк в префиксе недопустимы.'; return 1; }
    prefix=$(realpath -m -- "$prefix") || return 1
    if (( dry_run )); then
        printf 'Действие: %s\nПрефикс: %s\nЗапуск: %s/bin/ssh-agent.sh\nМодули: %s/libexec/ssh-agent\nМенеджер: %s/bin/ssh-agent-setup\n' \
            "$action" "$prefix" "$prefix" "$prefix" "$prefix"
        return 0
    fi
    if [[ "$action" == uninstall ]]; then
        setup_uninstall "$prefix"
        return $?
    fi
    setup_require bash ssh-agent ssh-add ssh-keygen || return 1
    SETUP_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ssh-agent-setup.XXXXXX") || return 1
    if [[ -n "$SETUP_SCRIPT" && -f "$SETUP_SCRIPT" ]]; then
        script_dir=$(dirname -- "$(realpath -- "$SETUP_SCRIPT")") || return 1
    fi
    if (( source_set )); then
        source=$(realpath -- "$source") || return 1
    elif (( ! remote )) && [[ "${SETUP_SCRIPT##*/}" == ssh-agent-setup ]]; then
        source="$prefix/libexec/ssh-agent"
    elif (( ! remote )) && [[ -n "$script_dir" && -f "$script_dir/ssh-agent.sh" ]]; then
        source=$script_dir
    else
        source="$SETUP_TMP_DIR/source"
        setup_github_source "$repo" "$ref" "$source" || return 1
    fi
    manager="$source/install.sh"
    if [[ ! -f "$manager" && -n "$SETUP_SCRIPT" && -f "$SETUP_SCRIPT" ]]; then
        manager=$(realpath -- "$SETUP_SCRIPT") || return 1
    fi
    setup_validate_source "$source" "$manager" || return 1
    setup_install "$prefix" "$source" "$manager"
}

if setup_main "$@"; then
    exit 0
else
    exit 1
fi

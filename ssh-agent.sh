#!/usr/bin/env bash

# Файл: ssh-agent.sh. Точка входа для выбора и загрузки SSH-ключей.
# Подключает модули из lib/, проверяет окружение и запускает меню.
# Выполняется через source, чтобы сохранить переменные агента в текущей оболочке.
# Запуск: source ./ssh-agent.sh [каталог-с-ключами]
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'Запустите скрипт через source, чтобы агент был доступен в текущем терминале:\n' >&2
    printf '  source %q [каталог-с-ключами]\n' "$0" >&2
    exit 1
fi

# Проверяет зависимости, находит читаемые приватные ключи и запускает меню.
# Аргумент $1: необязательный каталог ключей; по умолчанию используется ~/.ssh.
# Возвращает 0 при обычном выходе, 1 при ошибке подготовки или действия в меню.
_ssh_agent_select_main() {
    local script_dir key_dir="${1:-$HOME/.ssh}" file dependency
    local -a keys=()

    if (( $# > 1 )); then
        printf 'Использование: source ./ssh-agent.sh [каталог-с-ключами]\n' >&2
        return 1
    fi
    script_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 1
    # shellcheck source=lib/keys.bash
    source "$script_dir/lib/keys.bash" || return 1
    # shellcheck source=lib/agent.bash
    source "$script_dir/lib/agent.bash" || return 1
    # shellcheck source=lib/menu.bash
    source "$script_dir/lib/menu.bash" || return 1
    # shellcheck source=lib/table.bash
    source "$script_dir/lib/table.bash" || return 1

    for dependency in ssh-agent ssh-add ssh-keygen; do
        if ! command -v "$dependency" >/dev/null; then
            printf 'Не найдена команда %s. Установите клиент OpenSSH.\n' "$dependency" >&2
            return 1
        fi
    done
    if [[ ! -d "$key_dir" ]]; then
        printf 'Каталог с ключами не найден: %s\n' "$key_dir" >&2
        return 1
    fi
    # Абсолютные пути не позволяют принять имя файла с '-' за параметр команды.
    key_dir=$(CDPATH='' cd -- "$key_dir" && pwd -P) || return 1
    for file in "$key_dir"/* "$key_dir"/.[!.]* "$key_dir"/..?*; do
        if _ssh_agent_is_private_key "$file"; then
            keys+=("$file")
        fi
    done
    if (( ${#keys[@]} == 0 )); then
        printf 'В каталоге %s нет доступных для чтения приватных SSH-ключей.\n' "$key_dir" >&2
        return 1
    fi

    _ssh_agent_menu "${keys[@]}"
}

# Удаляет все вспомогательные функции, включая себя, из вызывающей оболочки.
# Аргументов нет; переменные SSH_AUTH_SOCK и SSH_AGENT_PID сохраняются.
_ssh_agent_cleanup() {
    unset -f _ssh_agent_is_private_key _ssh_agent_key_details _ssh_agent_key_fingerprint \
        _ssh_agent_is_running _ssh_agent_ensure_running \
        _ssh_agent_loaded_fingerprints _ssh_agent_change_keys _ssh_agent_remove_keys \
        _ssh_agent_show_identities \
        _ssh_agent_read_action _ssh_agent_draw_menu _ssh_agent_terminal_layout \
        _ssh_agent_safe_text _ssh_agent_fit_cell _ssh_agent_format_cells \
        _ssh_agent_format_entry _ssh_agent_menu \
        _ssh_agent_select_main _ssh_agent_cleanup
}

# Условный вызов позволяет обработать ошибки и при включённом set -e.
if _ssh_agent_select_main "$@"; then
    _ssh_agent_cleanup
    return 0
else
    _ssh_agent_cleanup
    return 1
fi

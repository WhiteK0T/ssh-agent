#!/usr/bin/env bash

# Запуск: source ./ssh-agent.sh [каталог-с-ключами]
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'Запустите скрипт через source, чтобы агент был доступен в текущем терминале:\n' >&2
    printf '  source %q [каталог-с-ключами]\n' "$0" >&2
    exit 1
fi

_ssh_agent_select_main() {
    local key_dir="${1:-$HOME/.ssh}"
    local file header answer token index agent_env probe_status key_count add_status=0
    local -a keys=() choices=() selected=() seen=()

    if (( $# > 1 )); then
        printf 'Использование: source ./ssh-agent.sh [каталог-с-ключами]\n' >&2
        return 1
    fi
    if ! command -v ssh-agent >/dev/null || ! command -v ssh-add >/dev/null; then
        printf 'Не найдены ssh-agent и/или ssh-add. Установите клиент OpenSSH.\n' >&2
        return 1
    fi
    if [[ ! -d "$key_dir" ]]; then
        printf 'Каталог с ключами не найден: %s\n' "$key_dir" >&2
        return 1
    fi
    # Преобразуем пути в абсолютные, чтобы имена с '-' не воспринимались как параметры.
    if ! key_dir=$(CDPATH='' cd -- "$key_dir" && pwd -P); then
        return 1
    fi

    # Проверяем только маркер формата, не выводя содержимое приватного ключа.
    # Шаблон без совпадений безопасен и не требует изменения настроек оболочки.
    for file in "$key_dir"/* "$key_dir"/.[!.]* "$key_dir"/..?*; do
        [[ -f "$file" && -r "$file" ]] || continue
        header=''
        IFS= read -r header < "$file" || :
        case "${header%$'\r'}" in
            '-----BEGIN OPENSSH PRIVATE KEY-----' | \
            '-----BEGIN RSA PRIVATE KEY-----' | \
            '-----BEGIN DSA PRIVATE KEY-----' | \
            '-----BEGIN EC PRIVATE KEY-----' | \
            '-----BEGIN PRIVATE KEY-----' | \
            '-----BEGIN ENCRYPTED PRIVATE KEY-----')
                keys+=("$file")
                ;;
        esac
    done

    if (( ${#keys[@]} == 0 )); then
        printf 'В каталоге %s нет доступных для чтения приватных SSH-ключей.\n' "$key_dir" >&2
        return 1
    fi

    key_count=${#keys[@]}
    printf 'Доступные приватные SSH-ключи:\n'
    for index in "${!keys[@]}"; do
        printf '  %d) %q\n' "$((index + 1))" "${keys[index]}"
    done

    while :; do
        printf 'Выберите номера через пробел или запятую, all — все, Enter/q — отмена: '
        if ! IFS= read -r answer; then
            printf '\nВыбор отменён.\n'
            return 0
        fi
        case "$answer" in
            '' | q | Q) printf 'Выбор отменён.\n'; return 0 ;;
            all | ALL | '*' | все) selected=("${keys[@]}"); break ;;
        esac
        answer=${answer//,/ }
        IFS=$' \t' read -r -a choices <<< "$answer"
        selected=()
        seen=()
        for token in "${choices[@]}"; do
            # Ограничиваем длину до вычислений, чтобы избежать переполнения целого числа.
            if [[ ! "$token" =~ ^[1-9][0-9]*$ ]] ||
                (( ${#token} > ${#key_count} )) ||
                (( token > key_count )); then
                selected=()
                break
            fi
            index=$((token - 1))
            if [[ -z "${seen[index]:-}" ]]; then
                selected+=("${keys[index]}")
                seen[index]=1
            fi
        done
        if (( ${#selected[@]} > 0 )); then
            break
        fi
        printf 'Некорректный выбор. Укажите номера от 1 до %d.\n' "${#keys[@]}" >&2
    done

    # ssh-add возвращает 1, если агент доступен, но ключей нет, и 2, если агент недоступен.
    if ssh-add -l >/dev/null 2>&1; then
        probe_status=0
    else
        probe_status=$?
    fi
    case "$probe_status" in
        0 | 1) printf 'Используется уже запущенный SSH-агент.\n' ;;
        *)
            if ! agent_env=$(ssh-agent -s); then
                printf 'Не удалось запустить SSH-агент.\n' >&2
                return 1
            fi
            if ! eval "$agent_env" >/dev/null; then
                printf 'Не удалось установить окружение SSH-агента.\n' >&2
                return 1
            fi
            printf 'Запущен SSH-агент (PID %s).\n' "$SSH_AGENT_PID"
            ;;
    esac

    if ssh-add "${selected[@]}"; then
        printf '\nКлючи добавлены.\n'
    else
        add_status=1
        printf '\nНе все выбранные ключи удалось добавить.\n' >&2
    fi
    printf '\nКлючи в SSH-агенте (ssh-add -l):\n'
    if ! ssh-add -l; then
        add_status=1
    fi
    return "$add_status"
}

# В окружении вызывающей оболочки оставляем только SSH_AUTH_SOCK и SSH_AGENT_PID.
# Условный вызов позволяет обработать ошибки и при включённом set -e.
if _ssh_agent_select_main "$@"; then
    unset -f _ssh_agent_select_main
    return 0
else
    unset -f _ssh_agent_select_main
    return 1
fi

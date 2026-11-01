_ssh_agent_is_running() {
    local status
    # Код 1 означает доступный агент без ключей, код 2 — недоступный агент.
    if ssh-add -l >/dev/null 2>&1; then
        return 0
    else
        status=$?
    fi
    [[ "$status" == 1 ]]
}

_ssh_agent_ensure_running() {
    local agent_env
    if _ssh_agent_is_running; then
        return 0
    fi
    if ! agent_env=$(ssh-agent -s); then
        printf 'Не удалось запустить SSH-агент.\n' >&2
        return 1
    fi
    if ! eval "$agent_env" >/dev/null; then
        printf 'Не удалось установить окружение SSH-агента.\n' >&2
        return 1
    fi
    printf 'Запущен SSH-агент (PID %s).\n' "$SSH_AGENT_PID"
}

_ssh_agent_loaded_fingerprints() {
    local listing _bits fingerprint _comment
    listing=$(ssh-add -l -E sha256 2>/dev/null) || return 0
    while IFS=' ' read -r _bits fingerprint _comment; do
        if [[ "$fingerprint" == SHA256:* ]]; then
            printf '%s\n' "$fingerprint"
        fi
    done <<< "$listing"
}

_ssh_agent_change_keys() {
    local action=$1
    shift
    # Пустой список нельзя передавать ssh-add: он загрузит ключи по умолчанию.
    (( $# > 0 )) || return 1
    case "$action" in
        add)
            ssh-add "$@"
            ;;
        remove)
            if ! _ssh_agent_is_running; then
                printf 'SSH-агент недоступен.\n' >&2
                return 1
            fi
            _ssh_agent_remove_keys "$@"
            ;;
    esac
}

_ssh_agent_remove_keys() {
    local file fingerprint public_listing public_key details _bits public_fingerprint _comment
    local -a requested=() public_keys=()
    for file in "$@"; do
        if ! fingerprint=$(_ssh_agent_key_fingerprint "$file"); then
            printf 'Не удалось определить отпечаток для выгрузки: %q\n' "$file" >&2
            return 1
        fi
        requested+=("$fingerprint")
    done
    if ! public_listing=$(ssh-add -L); then
        # Если агент всё ещё доступен, пустой список означает, что выгружать нечего.
        _ssh_agent_is_running && return 0
        return 1
    fi
    while IFS= read -r public_key; do
        details=$(ssh-keygen -l -E sha256 -f /dev/stdin <<< "$public_key" 2>/dev/null) || continue
        IFS=' ' read -r _bits public_fingerprint _comment <<< "$details"
        for fingerprint in "${requested[@]}"; do
            if [[ "$public_fingerprint" == "$fingerprint" ]]; then
                public_keys+=("$public_key")
                break
            fi
        done
    done <<< "$public_listing"

    (( ${#public_keys[@]} > 0 )) || return 0
    # Выгружаем точные публичные ключи агента, не полагаясь на соседние .pub-файлы.
    printf '%s\n' "${public_keys[@]}" | ssh-add -d -
}

_ssh_agent_show_identities() {
    printf '\nКлючи в SSH-агенте (ssh-add -l):\n'
    if _ssh_agent_is_running; then
        # Пустой агент — нормальный результат после выгрузки всех ключей.
        ssh-add -l || :
    else
        printf 'SSH-агент не запущен или недоступен.\n'
    fi
}

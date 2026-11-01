setup() {
    SSH_AGENT_SCRIPT="$BATS_TEST_DIRNAME/../ssh-agent.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.ssh" "$BATS_TEST_TMPDIR/empty"
    # Не подключаемся к агенту пользователя и не останавливаем его.
    unset SSH_AUTH_SOCK SSH_AGENT_PID

    case "${SSH_AGENT_TEST_MODE:-real}" in
        real) ;;
        mock) install_mock_commands ;;
        *) printf 'SSH_AGENT_TEST_MODE must be real or mock\n' >&2; return 1 ;;
    esac

    ssh-keygen -q -t ed25519 -N '' -C first -f "$HOME/.ssh/01 first"
    ssh-keygen -q -t ed25519 -N '' -C second -f "$HOME/.ssh/02_second"
    ssh-keygen -q -t ed25519 -N '' -C hidden -f "$HOME/.ssh/.03_hidden"
    printf 'Host example\n' > "$HOME/.ssh/config"
}

teardown() {
    if [[ -n "${SSH_AGENT_PID:-}" ]]; then
        ssh-agent -k >/dev/null
    fi
}

source_script() {
    # Вызываем source напрямую: run в Bats использует подоболочку и скрывает изменения окружения.
    # Закрываем дескриптор вывода Bats, чтобы работающий агент не удерживал его открытым.
    # shellcheck disable=SC1090
    source "$SSH_AGENT_SCRIPT" "$@" 3>&-
}

install_mock_commands() {
    # Имитируем поведение команд, если Unix-сокеты недоступны.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat > "$BATS_TEST_TMPDIR/bin/ssh-agent" <<'MOCK_AGENT'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == -k ]]; then
    rm -f -- "$SSH_AUTH_SOCK"
    exit 0
fi
state=$(mktemp "$BATS_TEST_TMPDIR/agent-state.XXXXXX")
printf 'SSH_AUTH_SOCK=%q; export SSH_AUTH_SOCK;\n' "$state"
printf 'SSH_AGENT_PID=%d; export SSH_AGENT_PID;\n' "$$"
MOCK_AGENT
    cat > "$BATS_TEST_TMPDIR/bin/ssh-add" <<'MOCK_ADD'
#!/usr/bin/env bash
set -eu
[[ -f "${SSH_AUTH_SOCK:-}" ]] || exit 2
if [[ "${1:-}" == -l ]]; then
    if [[ -s "$SSH_AUTH_SOCK" ]]; then
        cat -- "$SSH_AUTH_SOCK"
        exit 0
    fi
    printf 'The agent has no identities.\n'
    exit 1
fi
for key in "$@"; do
    fingerprint=$(ssh-keygen -lf "$key")
    found=false
    while IFS= read -r existing; do
        if [[ "$existing" == "$fingerprint" ]]; then
            found=true
            break
        fi
    done < "$SSH_AUTH_SOCK"
    if ! "$found"; then
        printf '%s\n' "$fingerprint" >> "$SSH_AUTH_SOCK"
    fi
done
MOCK_ADD
    chmod +x "$BATS_TEST_TMPDIR/bin/ssh-agent" "$BATS_TEST_TMPDIR/bin/ssh-add"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

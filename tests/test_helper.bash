# Файл: tests/test_helper.bash. Общие фикстуры и помощники тестов Bats.
# Создаёт временные ключи и изолированное окружение; поддерживает реальные агенты
# и имитаторы команд при SSH_AGENT_TEST_MODE=mock. Загружается через load test_helper.

# Подготавливает отдельный HOME и тестовые ключи перед каждым тестом Bats.
# Аргументов нет; пользовательский агент отключается от тестового окружения.
setup() {
    SSH_AGENT_SCRIPT="$BATS_TEST_DIRNAME/../ssh-agent.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME/.ssh" "$BATS_TEST_TMPDIR/empty"
    # Не подключаемся к агенту пользователя и не останавливаем его.
    unset SSH_AUTH_SOCK SSH_AGENT_PID

    case "${SSH_AGENT_TEST_MODE:-real}" in
        real) ;;
        mock) install_mock_commands ;;
        *)
            printf 'SSH_AGENT_TEST_MODE должен быть real или mock\n' >&2
            return 1
            ;;
    esac

    ssh-keygen -q -t ed25519 -N '' -C first -f "$HOME/.ssh/01 first"
    ssh-keygen -q -t ed25519 -N '' -C second -f "$HOME/.ssh/02_second"
    ssh-keygen -q -t ed25519 -N '' -C hidden -f "$HOME/.ssh/.03_hidden"
    printf 'Host example\n' >"$HOME/.ssh/config"
}

# Останавливает только агент, созданный в окружении текущего теста.
# Вызывается Bats после теста без аргументов, в том числе при ошибке проверки.
teardown() {
    if [[ -n "${SSH_AGENT_PID:-}" ]]; then
        ssh-agent -k >/dev/null
    fi
}

# Подключает тестируемый скрипт в текущей оболочке, сохраняя изменения окружения.
# Передаёт скрипту все аргументы и возвращает его код; FD 3 Bats временно закрывается.
source_script() {
    # Вызываем source напрямую: run в Bats использует подоболочку и скрывает изменения окружения.
    # Закрываем дескриптор вывода Bats, чтобы работающий агент не удерживал его открытым.
    # shellcheck disable=SC1090
    source "$SSH_AGENT_SCRIPT" "$@" 3>&-
}

# Создаёт временные исполняемые имитаторы ssh-agent и ssh-add и добавляет их в PATH.
# Аргументов нет; состояние хранится в BATS_TEST_TMPDIR, Unix-сокеты не используются.
install_mock_commands() {
    # Имитируем поведение команд, если Unix-сокеты недоступны.
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/ssh-agent" <<'MOCK_AGENT'
#!/usr/bin/env bash
# Тестовый файл ssh-agent: выдаёт окружение с путём к файлу состояния вместо сокета.
# Параметр -k удаляет состояние; остальные вызовы создают пустой тестовый агент.
set -eu
if [[ "${1:-}" == -k ]]; then
    rm -f -- "$SSH_AUTH_SOCK"
    exit 0
fi
state=$(mktemp "$BATS_TEST_TMPDIR/agent-state.XXXXXX")
printf 'SSH_AUTH_SOCK=%q; export SSH_AUTH_SOCK;\n' "$state"
printf 'SSH_AGENT_PID=%d; export SSH_AGENT_PID;\n' "$$"
MOCK_AGENT
    cat >"$BATS_TEST_TMPDIR/bin/ssh-add" <<'MOCK_ADD'
#!/usr/bin/env bash
# Тестовый файл ssh-add: имитирует просмотр, добавление и удаление ключей агента.
# Использует публичные ключи в файле SSH_AUTH_SOCK; реальные сокеты не открывает.
set -eu
[[ -f "${SSH_AUTH_SOCK:-}" ]] || exit 2
if [[ "${1:-}" == -l ]]; then
    if [[ -s "$SSH_AUTH_SOCK" ]]; then
        ssh-keygen -l -E sha256 -f /dev/stdin < "$SSH_AUTH_SOCK"
        exit 0
    fi
    printf 'The agent has no identities.\n'
    exit 1
fi
if [[ "${1:-}" == -L ]]; then
    cat -- "$SSH_AUTH_SOCK"
    exit 0
fi
operation=add
if [[ "${1:-}" == -d ]]; then
    operation=remove
    shift
fi
# Обновляет файл состояния имитатора по отпечатку публичного ключа из аргумента $1.
# Действие берётся из внешней переменной operation: add добавляет, remove удаляет.
update_public_key() {
    local public_key=$1 fingerprint _bits key_hash _comment found=false remaining=''
    local existing existing_details existing_hash
    fingerprint=$(ssh-keygen -l -E sha256 -f /dev/stdin <<< "$public_key")
    read -r _bits key_hash _comment <<< "$fingerprint"
    while IFS= read -r existing; do
        existing_details=$(ssh-keygen -l -E sha256 -f /dev/stdin <<< "$existing")
        read -r _bits existing_hash _comment <<< "$existing_details"
        if [[ "$existing_hash" == "$key_hash" ]]; then
            found=true
        else
            remaining+="$existing"$'\n'
        fi
    done < "$SSH_AUTH_SOCK"
    if [[ "$operation" == remove ]]; then
        printf '%s' "$remaining" > "$SSH_AUTH_SOCK"
    elif ! "$found"; then
        printf '%s\n' "$public_key" >> "$SSH_AUTH_SOCK"
    fi
}
if [[ "$operation" == remove && "${1:-}" == '-' ]]; then
    while IFS= read -r public_key; do
        update_public_key "$public_key"
    done
else
    for key in "$@"; do
        public_key=$(ssh-keygen -y -P '' -f "$key")
        update_public_key "$public_key"
    done
fi
MOCK_ADD
    chmod +x "$BATS_TEST_TMPDIR/bin/ssh-agent" "$BATS_TEST_TMPDIR/bin/ssh-add"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

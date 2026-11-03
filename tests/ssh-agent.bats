#!/usr/bin/env bats

# Файл: tests/ssh-agent.bats. Поведенческие проверки скрипта и терминального меню.
# Названия блоков @test описывают проверяемые сценарии; фикстуры находятся в test_helper.bash.
# Запуск: bats tests; имитация агента: SSH_AGENT_TEST_MODE=mock bats tests.

load test_helper

@test "Space отмечает несколько ключей, a добавляет отмеченные" {
    source_script <<<$' \e[B aq'

    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" == *first* && "$output" == *second* ]]
    [[ "$output" != *hidden* ]]
}

@test "цифры и неизвестные клавиши не выбирают ключи" {
    source_script <<<$'1234567890+\e[A \e[B aq'

    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "окружение агента сохраняется и экспортируется дочерним процессам" {
    source_script <<<$'\nq'

    [ -n "$SSH_AUTH_SOCK" ]
    [ -n "$SSH_AGENT_PID" ]
    run bash -c 'ssh-add -l'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *first* ]]
    run declare -F
    [[ "$output" != *_ssh_agent_* ]]
}

@test "доступный агент используется повторно и сохраняет прежние ключи" {
    source_script <<<$'\nq'
    original_pid=$SSH_AGENT_PID
    original_socket=$SSH_AUTH_SOCK

    source_script <<<$'\e[B\nq'

    [ "$SSH_AGENT_PID" = "$original_pid" ]
    [ "$SSH_AUTH_SOCK" = "$original_socket" ]
    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "меню включает скрытые ключи и пропускает публичные ключи и конфигурацию" {
    source_script <<<$' \e[B \e[B aq'

    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [[ "$output" == *first* && "$output" == *second* && "$output" == *hidden* ]]
}

@test "пустой доступный агент используется повторно" {
    agent_env=$(ssh-agent -s 3>&-)
    eval "$agent_env" >/dev/null
    original_pid=$SSH_AGENT_PID
    original_socket=$SSH_AUTH_SOCK

    source_script <<<$' \e[B \e[B aq'

    [ "$SSH_AGENT_PID" = "$original_pid" ]
    [ "$SSH_AUTH_SOCK" = "$original_socket" ]
    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "q, Esc и конец ввода завершают меню без запуска агента" {
    source_script <<<'q'
    [ -z "${SSH_AUTH_SOCK:-}" ]
    [ -z "${SSH_AGENT_PID:-}" ]

    source_script <<<$'\e'
    [ -z "${SSH_AUTH_SOCK:-}" ]
    [ -z "${SSH_AGENT_PID:-}" ]

    source_script </dev/null
    [ -z "${SSH_AUTH_SOCK:-}" ]
    [ -z "${SSH_AGENT_PID:-}" ]
}

@test "пустой каталог возвращает ошибку без запуска агента" {
    if source_script "$BATS_TEST_TMPDIR/empty"; then
        return 1
    fi
    [ -z "${SSH_AUTH_SOCK:-}" ]
    [ -z "${SSH_AGENT_PID:-}" ]
}

@test "отсутствующий каталог возвращает ошибку без запуска агента" {
    if source_script "$BATS_TEST_TMPDIR/missing"; then
        return 1
    fi
    [ -z "${SSH_AUTH_SOCK:-}" ]
    [ -z "${SSH_AGENT_PID:-}" ]
}

@test "обычный запуск сообщает о необходимости source" {
    run bash "$SSH_AGENT_SCRIPT"

    [ "$status" -eq 1 ]
    [[ "$output" == *source* ]]
}

@test "меню показывает SHA256-отпечатки всех ключей" {
    run source_script <<<$'\e[B\e[Bq'

    [ "$status" -eq 0 ]
    for key in "$HOME/.ssh/01 first.pub" "$HOME/.ssh/02_second.pub" "$HOME/.ssh/.03_hidden.pub"; do
        details=$(ssh-keygen -l -E sha256 -f "$key")
        read -r _bits fingerprint _comment <<<"$details"
        [[ "$output" == *"$fingerprint"* ]]
    done
}

@test "состояние уже загруженного ключа определяется по отпечатку, включая ссылки" {
    source_script <<<$'\nq'
    ln -s "$HOME/.ssh/01 first" "$HOME/.ssh/alias"

    run source_script <<<'q'

    [ "$status" -eq 0 ]
    [[ "$output" == *'● [ ] alias '* ]]
    [[ "$output" == *'○ [ ] 02_second '* ]]
}

@test "несоответствующий .pub не меняет отпечаток и не мешает выгрузить нужный ключ" {
    source_script <<<$' \e[B aq'
    cp "$HOME/.ssh/02_second.pub" "$HOME/.ssh/01 first.pub"

    run source_script <<<'q'
    [ "$status" -eq 0 ]
    [[ "$output" == *'● [ ] 01 first '* ]]

    source_script <<<$'\nq'

    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *second* ]]
}

@test "Enter добавляет ключ, повторный Enter выгружает его" {
    source_script <<<$'\n\nq'

    run ssh-add -l
    [ "$status" -eq 1 ]
    [[ "$output" == *'no identities'* ]]
}

@test "d выгружает только отмеченные ключи" {
    source_script <<<$' \e[B \e[B aq'

    source_script <<<$' \e[B dq'

    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *hidden* ]]
}

@test "повторный Space снимает отметку, a без отметок не запускает агент" {
    source_script <<<'  aq'

    [ -z "${SSH_AUTH_SOCK:-}" ]
    [ -z "${SSH_AGENT_PID:-}" ]
}

@test "зашифрованный OpenSSH-ключ без .pub показывает отпечаток без запроса пароля" {
    ssh-keygen -q -t ed25519 -N test-password -C encrypted -f "$HOME/.ssh/00_encrypted"
    details=$(ssh-keygen -l -E sha256 -f "$HOME/.ssh/00_encrypted.pub")
    read -r _bits fingerprint _comment <<<"$details"
    mv "$HOME/.ssh/00_encrypted.pub" "$BATS_TEST_TMPDIR/encrypted.pub"

    run source_script <<<'q'

    [ "$status" -eq 0 ]
    [[ "$output" == *"$fingerprint"* ]]
    [[ "$output" != *'Отпечаток недоступен'* ]]
}

@test "ошибка добавления сохраняет меню и возвращает ненулевой код при выходе" {
    printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' invalid >"$HOME/.ssh/00_broken"

    if source_script <<<$'\nq' >"$BATS_TEST_TMPDIR/error.log" 2>&1; then
        return 1
    fi

    output=$(<"$BATS_TEST_TMPDIR/error.log")
    [[ "$output" == *'Отпечаток недоступен'* ]]
    [[ "$output" == *'Не все изменения применены'* ]]
    [[ "$output" == *'Ключи в SSH-агенте (ssh-add -l)'* ]]
}

@test "нечисловой интерфейс не использует очистку экрана при перенаправлении вывода" {
    run source_script <<<$' \e[B q'

    [ "$status" -eq 0 ]
    [[ "$output" == *'[x]'* ]]
    [[ "$output" != *$'\e'* ]]
}

@test "source работает с set -euo pipefail и не меняет настройки вызывающей оболочки" {
    run bash -c '
        set -euo pipefail
        trap '\''if [[ -n "${SSH_AGENT_PID:-}" ]]; then ssh-agent -k >/dev/null; fi'\'' EXIT
        source "$1" "$HOME/.ssh" 3>&- <<< $'\''\nq'\''
        [[ $- == *e* && $- == *u* ]]
        [[ -o pipefail ]]
        ssh-add -l
    ' _ "$SSH_AGENT_SCRIPT"

    [ "$status" -eq 0 ]
    [[ "$output" == *first* ]]
}

@test "меню в терминале сохраняет предыдущий вывод, итог и настройки терминала" {
    command -v python3 >/dev/null || skip 'Для проверки PTY нужен Python 3'

    run python3 "$BATS_TEST_DIRNAME/terminal_session.py" "$SSH_AGENT_SCRIPT" navigation

    [ "$status" -eq 0 ]
}

@test "длинный список листается в терминале без очистки предыдущего вывода" {
    command -v python3 >/dev/null || skip 'Для проверки PTY нужен Python 3'
    for index in {1..14}; do
        ln -s "$HOME/.ssh/01 first" "$HOME/.ssh/alias-$index-with-a-very-long-name-that-must-fit-the-menu"
    done

    run python3 "$BATS_TEST_DIRNAME/terminal_session.py" "$SSH_AGENT_SCRIPT" pages

    [ "$status" -eq 0 ]
}

@test "изменение размера терминала начинает новый блок меню" {
    command -v python3 >/dev/null || skip 'Для проверки PTY нужен Python 3'
    for index in {1..14}; do
        ln -s "$HOME/.ssh/01 first" "$HOME/.ssh/alias-$index-with-a-very-long-name-that-must-fit-the-menu"
    done

    run python3 "$BATS_TEST_DIRNAME/terminal_session.py" "$SSH_AGENT_SCRIPT" resize

    [ "$status" -eq 0 ]
}

@test "управляющие символы в имени ключа экранируются" {
    cp "$HOME/.ssh/01 first" "$HOME/.ssh/00_"$'\e[2J\rkey'

    run source_script <<<'q'

    [ "$status" -eq 0 ]
    [[ "$output" != *$'\e'* ]]
    [[ "$output" != *$'\r'* ]]
}

@test "Home и End поддерживают обе распространённые последовательности терминала" {
    source_script <<<$'\e[F\n\e[H\nq'

    source_script <<<$'\e[4~\n\e[1~\nq'

    run ssh-add -l
    [ "$status" -eq 1 ]
}

@test "таблица показывает один ключ на строку, алгоритм и комментарий" {
    run source_script <<<'q'

    [ "$status" -eq 0 ]
    row_count=0
    for line in "${lines[@]}"; do
        if [[ "$line" == *'[ ]'* ]]; then
            [[ "$line" == *'ed25519'* ]]
            [[ "$line" == *'SHA256:'* ]]
            [[ "$line" == *'│'* ]]
            row_count=$((row_count + 1))
        fi
    done
    [ "$row_count" -eq 3 ]
    [[ "$output" == *'Комментарий'* ]]
    [[ "$output" == *'first'* && "$output" == *'second'* && "$output" == *'hidden'* ]]
}

@test "имена ключей и комментарии на кириллице остаются читаемыми" {
    ssh-keygen -q -t ed25519 -N '' -C 'Рабочий сервер' -f "$HOME/.ssh/00_Работа"

    run source_script <<<'q'

    [ "$status" -eq 0 ]
    [[ "$output" == *'00_Работа'* ]]
    [[ "$output" == *'Рабочий сервер'* ]]
}

@test "широкая таблица показывает полные отпечатки в строках ключей" {
    command -v python3 >/dev/null || skip 'Для проверки PTY нужен Python 3'

    run python3 "$BATS_TEST_DIRNAME/terminal_session.py" "$SSH_AGENT_SCRIPT" wide

    [ "$status" -eq 0 ]
}

@test "очень узкий терминал использует последовательный вывод без перерисовки" {
    command -v python3 >/dev/null || skip 'Для проверки PTY нужен Python 3'

    run python3 "$BATS_TEST_DIRNAME/terminal_session.py" "$SSH_AGENT_SCRIPT" narrow

    [ "$status" -eq 0 ]
}

@test "повторная загрузка и выгрузка оставляют ровно одну таблицу в терминале" {
    command -v python3 >/dev/null || skip 'Для проверки PTY нужен Python 3'

    run python3 "$BATS_TEST_DIRNAME/terminal_session.py" "$SSH_AGENT_SCRIPT" actions

    [ "$status" -eq 0 ]
}

@test "пароль и повторный запрос после ошибки не создают копий меню и не выводят пароль" {
    command -v python3 >/dev/null || skip 'Для проверки PTY нужен Python 3'
    [[ "${SSH_AGENT_TEST_MODE:-real}" == real ]] || skip 'Нужен настоящий ssh-add'
    ssh-keygen -p -P '' -N test-password -f "$HOME/.ssh/01 first" >/dev/null

    run python3 "$BATS_TEST_DIRNAME/terminal_session.py" "$SSH_AGENT_SCRIPT" encrypted

    [ "$status" -eq 0 ]
}

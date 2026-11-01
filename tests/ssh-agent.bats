#!/usr/bin/env bats

load test_helper

@test "выбор нескольких ключей и игнорирование повторяющихся номеров" {
    source_script <<< '2,1,2'

    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" == *first* && "$output" == *second* ]]
    [[ "$output" != *hidden* ]]
}

@test "некорректный ввод запрашивается повторно" {
    source_script <<< $'999999999999999999999999999999999999\n1+1\n0\n4\n1 2'

    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "окружение агента сохраняется и экспортируется дочерним процессам" {
    source_script <<< '1'

    [ -n "$SSH_AUTH_SOCK" ]
    [ -n "$SSH_AGENT_PID" ]
    run bash -c 'ssh-add -l'
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    [[ "$output" == *first* ]]
    run declare -F _ssh_agent_select_main
    [ "$status" -eq 1 ]
}

@test "доступный агент используется повторно и сохраняет прежние ключи" {
    source_script <<< '1'
    original_pid=$SSH_AGENT_PID
    original_socket=$SSH_AUTH_SOCK

    source_script <<< '2'

    [ "$SSH_AGENT_PID" = "$original_pid" ]
    [ "$SSH_AUTH_SOCK" = "$original_socket" ]
    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
}

@test "all выбирает все приватные ключи, включая скрытые, и пропускает прочие файлы" {
    source_script <<< 'all'

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

    source_script <<< 'all'

    [ "$SSH_AGENT_PID" = "$original_pid" ]
    [ "$SSH_AUTH_SOCK" = "$original_socket" ]
    run ssh-add -l
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "пустой ввод и q отменяют выбор без запуска агента" {
    source_script <<< ''
    [ -z "${SSH_AUTH_SOCK:-}" ]
    [ -z "${SSH_AGENT_PID:-}" ]

    source_script <<< 'q'
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

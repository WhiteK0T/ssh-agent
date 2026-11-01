#!/usr/bin/env bash

# Файл: lib/askpass.sh. Исполняемый помощник OpenSSH для скрытого ввода пароля.
# Аргумент $1: подсказка OpenSSH; SSH_AGENT_MENU_COLUMNS задаёт ширину строки,
# SSH_AGENT_MENU_INLINE=1 размещает запрос в строке состояния без перевода строки.
# Возвращает пароль через stdout с кодом 0, при отмене или недоступном TTY — код 1.
# OpenSSH получает пароль через stdout; подсказка и ввод используют только /dev/tty.
exec 3<>/dev/tty || exit 1
prompt=${1:-Введите пароль SSH-ключа:}
columns=${SSH_AGENT_MENU_COLUMNS:-80}
if [[ ! "$columns" =~ ^[1-9][0-9]{0,4}$ ]] || (( columns < 60 )); then
    columns=80
fi

if [[ "${SSH_AGENT_MENU_INLINE:-0}" == 1 ]]; then
    # shellcheck source=lib/table.bash
    source "${BASH_SOURCE[0]%/*}/table.bash" || exit 1
    prompt=$(_ssh_agent_fit_cell "$prompt" "$((columns - 1))")
    printf '\r%s\033[K' "$prompt" >&3
else
    printf '%s ' "$prompt" >&3
fi

read_status=0
IFS= read -r -s -u 3 passphrase || read_status=$?
if [[ "${SSH_AGENT_MENU_INLINE:-0}" == 1 ]]; then
    printf '\r\033[K' >&3
else
    printf '\n' >&3
fi
(( read_status == 0 )) || exit 1
printf '%s\n' "$passphrase"

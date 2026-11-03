#!/usr/bin/env bash

# Файл: tools/smoke-install.sh. Короткая проверка установки и реального агента.
# Использует временные HOME, ключ и префиксы; вызывается в контейнерах и локально.
set -euo pipefail
project_dir=$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
smoke_dir=$(mktemp -d)
unset SSH_AUTH_SOCK SSH_AGENT_PID

# Останавливает только созданный проверкой агент и удаляет её временные файлы.
cleanup() {
    if [[ -n "${SSH_AGENT_PID:-}" ]]; then
        ssh-agent -k >/dev/null
    fi
    rm -rf -- "$smoke_dir"
}
trap cleanup EXIT
export HOME="$smoke_dir/home"
mkdir -p "$HOME/.ssh"
ssh-keygen -q -t ed25519 -N '' -C installation-smoke -f "$HOME/.ssh/test"
prefix="$smoke_dir/custom prefix"
bash "$project_dir/install.sh" --prefix "$prefix" --source "$project_dir" >"$smoke_dir/install.log"
cmp "$project_dir/LICENSE" "$prefix/libexec/ssh-agent/LICENSE"
cmp "$project_dir/VERSION" "$prefix/libexec/ssh-agent/VERSION"
# Подключение в этой оболочке проверяет сохранение переменных и доступ к агенту.
# shellcheck disable=SC1091
source "$prefix/bin/ssh-agent.sh" <<<$'\nq' >"$smoke_dir/menu.log"
[[ -n "$SSH_AUTH_SOCK" && -n "$SSH_AGENT_PID" ]]
identities=$(ssh-add -l)
[[ "$identities" == *installation-smoke* ]]
# shellcheck disable=SC1091
source "$prefix/bin/ssh-agent.sh" <<<$'\nq' >>"$smoke_dir/menu.log"
if ssh-add -l >/dev/null; then
    printf 'Ключ не выгружен.\n' >&2
    exit 1
else
    [[ $? == 1 ]]
fi
"$prefix/bin/ssh-agent-setup" >"$smoke_dir/reinstall.log"
"$prefix/bin/ssh-agent-setup" --uninstall >"$smoke_dir/uninstall.log"
[[ ! -e "$prefix/libexec/ssh-agent" && ! -e "$prefix/bin/ssh-agent.sh" ]]
bash "$project_dir/install.sh" --user >"$smoke_dir/user-install.log"
"$HOME/.local/bin/ssh-agent-setup" --uninstall >"$smoke_dir/user-uninstall.log"
[[ ! -e "$HOME/.local/libexec/ssh-agent" ]]
printf 'Установка, переустановка, агент, выгрузка и удаление проверены.\n'

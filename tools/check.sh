#!/usr/bin/env bash

# Файл: tools/check.sh. Общая точка запуска локальных проверок и GitHub Actions.
# Подкоманды: lint, test, mock, links, links-online, security, all (по умолчанию).
set -euo pipefail
project_dir=$(CDPATH='' cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
cd -- "$project_dir"
export PATH="$project_dir/tools/.bin:$project_dir/tools/node_modules/.bin:$PATH"

# Проверяет наличие всех команд из аргументов и поясняет способ подготовки среды.
require_tools() {
    local tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null || {
            printf 'Не найдена команда %s. Подготовка среды: docs/development.md\n' "$tool" >&2
            return 1
        }
    done
}

# Проверяет исходники, форматирование, документацию и определения GitHub Actions.
check_lint() {
    require_tools shellcheck shfmt ruff markdownlint-cli2 actionlint zizmor python3
    local -a shell_files=(install.sh ssh-agent.sh lib/*.bash lib/askpass.sh tools/*.sh tests/test_helper.bash tests/*.bats)
    shellcheck -x "${shell_files[@]}"
    shfmt -d "${shell_files[@]}"
    ruff check tools tests/terminal_session.py
    ruff format --check tools tests/terminal_session.py
    markdownlint-cli2
    python3 tools/release.py "v$(<VERSION)" --check
    actionlint
    zizmor --offline --persona auditor .github
}

# Выполняет тесты в указанном режиме; Python обязателен, чтобы проверки PTY не пропускались.
check_tests() {
    require_tools bats python3 ssh-agent ssh-add ssh-keygen
    SSH_AGENT_TEST_MODE=$1 bats tests
}

# Проверяет историю и изменения отслеживаемых файлов, скрывая найденные секреты в отчёте.
check_secrets() {
    require_tools git gitleaks
    gitleaks git --redact --no-banner
    gitleaks git --pre-commit --redact --no-banner
    gitleaks git --pre-commit --staged --redact --no-banner
}

case "${1:-all}" in
    lint) check_lint ;;
    test) check_tests real ;;
    mock) check_tests mock ;;
    links)
        require_tools lychee
        lychee --offline '*.md' 'docs/**/*.md'
        ;;
    links-online)
        require_tools lychee
        lychee '*.md' 'docs/**/*.md'
        ;;
    security) check_secrets ;;
    all)
        check_lint
        check_tests real
        check_tests mock
        require_tools lychee
        lychee --offline '*.md' 'docs/**/*.md'
        check_secrets
        ;;
    *)
        printf 'Использование: bash tools/check.sh [lint|test|mock|links|links-online|security|all]\n' >&2
        exit 1
        ;;
esac

# Repository Guidelines

Руководство для участников и агентов: структура проекта, правила изменения кода,
проверки и требования к работе с SSH-ключами.

## Project Structure & Module Organization

This project is a Bash utility for selecting private SSH keys and loading them
into an SSH agent.

- `ssh-agent.sh`: sourced entry point; discovers keys, handles selection, starts
  or reuses an agent, and lists loaded identities.
- `install.sh`: noninteractive installer and uninstaller; manages user, system,
  or custom prefixes and accepts local sources or a GitHub snapshot.
- `lib/`: agent operations, key metadata, menu, table, and askpass helper.
- `tests/ssh-agent.bats`: Bats behavioral tests.
- `tests/install.bats`: installer checks using temporary prefixes and mocked downloads.
- `tests/test_helper.bash`: isolated test setup, agent cleanup, and mock commands.
- `README.md`: Russian usage and testing instructions.
- `docs/screenshots/`: actual menu screenshots with temporary demonstration keys.
- `tools/`: shared checks, checksum-verified development tools, and installer smoke checks.
- `.github/`: CI workflows and Dependabot updates.
- `LICENSE`: MIT license, also included in installed distributions.

There is no build step or generated application output.

## Build, Test, and Development Commands

Install Bash, the OpenSSH client, Bats (`bats-core`), and ShellCheck. Run commands
from the repository root:

```bash
source ./ssh-agent.sh                 # Запуск в текущей оболочке
source ./ssh-agent.sh /path/to/keys    # Выбор другого каталога
bats tests                           # Тесты с настоящими агентами
SSH_AGENT_TEST_MODE=mock bats tests   # Тесты без Unix-сокетов
shellcheck -x install.sh ssh-agent.sh lib/*.bash lib/askpass.sh tests/test_helper.bash tests/*.bats
bash tools/check.sh lint             # Общий набор анализаторов
bash tools/check.sh all              # Анализ, реальные и имитированные агенты, ссылки и секреты
```

Sourcing is required to retain agent environment variables in the caller's shell.

## Coding Style & Naming Conventions

Use four-space indentation, `snake_case` function and local variable names, and
uppercase exported environment variables. Quote path expansions and use arrays
for selected keys. Keep explanatory comments and user-facing messages in Russian;
preserve executable shebangs and ShellCheck directives. Follow ShellCheck and
avoid changing the caller's shell options or leaving helper functions behind.
Use shfmt with `.editorconfig` and Ruff with `ruff.toml`; see `docs/development.md`.

## Testing Guidelines

Use descriptive Russian `@test` names in `tests/*.bats`. Add behavioral coverage
for changed selection, error, or agent lifecycle behavior; no numeric coverage
threshold is configured. Run ShellCheck and the Bats suite before submitting.
Report explicitly when only mock mode was available.

Keep each test's keys and home directory under `BATS_TEST_TMPDIR`, and stop test
agents in `teardown`. Use `source_script` directly when asserting environment
persistence: Bats `run` executes in a subshell. Use `run` for captured output and
exit-status assertions.

## Commit & Pull Request Guidelines

Use concise, imperative English commit subjects describing the change. Pull
requests should explain the resulting behavior, link relevant issues, list test
commands and results, and identify any validation limits. Update `README.md`
when usage changes.

## Security & Configuration

Never commit private keys or print their contents. Generate temporary test keys;
never use the contributor's existing agent or identities in tests. Preserve
`SSH_AUTH_SOCK` and `SSH_AGENT_PID` handling when changing agent startup.

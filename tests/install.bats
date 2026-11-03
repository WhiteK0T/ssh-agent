#!/usr/bin/env bats

# Файл: tests/install.bats. Установка, обновление и удаление в изолированных каталогах.
# Использует общие фикстуры Bats; загрузка GitHub проверяется через локальный архив.
# Системные каталоги проверяются только через --dry-run и никогда не изменяются.

load test_helper

# Запускает установщик проекта и сохраняет stdout и код завершения средствами Bats.
# Все аргументы передаются install.sh без изменений; рабочие файлы теста — в BATS_TEST_TMPDIR.
run_setup() {
    run bash "$BATS_TEST_DIRNAME/../install.sh" "$@"
}

# Создаёт снимок репозитория и имитатор curl для проверки загрузки без внешней сети.
# Подмена копирует архив и записывает URL в download.log внутри временного каталога теста.
github_fixture() {
    local snapshot="$BATS_TEST_TMPDIR/snapshot"
    mkdir -p "$snapshot/ssh-agent-snapshot/lib" "$BATS_TEST_TMPDIR/bin"
    cp "$BATS_TEST_DIRNAME/../install.sh" "$BATS_TEST_DIRNAME/../ssh-agent.sh" "$BATS_TEST_DIRNAME/../LICENSE" "$snapshot/ssh-agent-snapshot/"
    cp "$BATS_TEST_DIRNAME/../lib/"* "$snapshot/ssh-agent-snapshot/lib/"
    printf 'Не устанавливать\n' > "$snapshot/ssh-agent-snapshot/unrelated-file"
    tar -czf "$BATS_TEST_TMPDIR/source.tar.gz" -C "$snapshot" ssh-agent-snapshot
    cat > "$BATS_TEST_TMPDIR/bin/curl" <<'CURL'
#!/usr/bin/env bash
# Тестовый файл curl: копирует локальный архив и записывает запрошенный URL.
set -eu
[[ "${TEST_DOWNLOAD_FAILURE:-0}" == 0 ]] || exit 22
destination=''
while (( $# > 0 )); do
    case "$1" in
        --output) destination=$2; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
printf '%s\n' "$1" >> "$BATS_TEST_TMPDIR/download.log"
cp "$BATS_TEST_TMPDIR/source.tar.gz" "$destination"
CURL
    chmod +x "$BATS_TEST_TMPDIR/bin/curl"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "справка и dry-run не создают установку" {
    run_setup --help
    [ "$status" -eq 0 ]
    [[ "$output" == *'--uninstall'* && "$output" == *'--prefix'* ]]
    [[ "$output" != *'--install'* ]]

    run_setup --user --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"$HOME/.local/bin/ssh-agent.sh"* ]]
    [ ! -e "$HOME/.local" ]
}

@test "префикс по умолчанию зависит от прав пользователя" {
    run_setup --dry-run
    [ "$status" -eq 0 ]
    if (( EUID == 0 )); then
        [[ "$output" == *'Префикс: /usr/local'* ]]
    else
        [[ "$output" == *"Префикс: $HOME/.local"* ]]
    fi
    [ ! -e "$HOME/.local" ]
}

@test "параметр --system выбирает /usr/local" {
    run_setup --system --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'/usr/local/bin/ssh-agent.sh'* ]]
    [[ "$output" == *'/usr/local/libexec/ssh-agent'* ]]
}

@test "некорректные и несовместимые параметры отклоняются" {
    for args in '--unknown' '--prefix' '--install' '--user --system' '--user --prefix /tmp/unused'; do
        read -r -a options <<< "$args"
        run_setup "${options[@]}"
        [ "$status" -ne 0 ]
    done
    run_setup --source "$BATS_TEST_DIRNAME/.." --repo WhiteK0T/ssh-agent
    [ "$status" -ne 0 ]
    run_setup --uninstall --ref HEAD
    [ "$status" -ne 0 ]
    [ ! -e "$HOME/.local" ]
}

@test "локальная установка работает из другого рабочего каталога" {
    cd "$BATS_TEST_TMPDIR"
    run_setup --user

    [ "$status" -eq 0 ]
    [ -f "$HOME/.local/bin/ssh-agent.sh" ]
    [ -x "$HOME/.local/bin/ssh-agent-setup" ]
    [ -f "$HOME/.local/libexec/ssh-agent/ssh-agent.sh" ]
    [ -x "$HOME/.local/libexec/ssh-agent/lib/askpass.sh" ]
    cmp "$BATS_TEST_DIRNAME/../LICENSE" "$HOME/.local/libexec/ssh-agent/LICENSE"
    [ "$(find "$HOME/.local/bin" -maxdepth 1 -type f | wc -l)" -eq 2 ]
    [[ "$output" == *'export PATH='* ]]
}

@test "исходники без лицензии отклоняются до установки" {
    source_dir="$BATS_TEST_TMPDIR/without-license"
    mkdir "$source_dir"
    cp "$BATS_TEST_DIRNAME/../install.sh" "$BATS_TEST_DIRNAME/../ssh-agent.sh" "$source_dir/"
    cp -R "$BATS_TEST_DIRNAME/../lib" "$source_dir/"

    run_setup --user --source "$source_dir"

    [ "$status" -ne 0 ]
    [[ "$output" == *LICENSE* ]]
    [ ! -e "$HOME/.local" ]
}

@test "установленный запускной файл находится через PATH и сохраняет текущую оболочку" {
    run_setup --user
    [ "$status" -eq 0 ]

    run bash -c 'export PATH="$1/bin:$PATH"; source ssh-agent.sh "$2" <<< q; printf "SHELL_ALIVE\n"' \
        _ "$HOME/.local" "$HOME/.ssh"

    [ "$status" -eq 0 ]
    [[ "$output" == *'Ключи'* && "$output" == *'SHELL_ALIVE'* ]]
}

@test "обычный запуск установленного файла подсказывает source" {
    run_setup --user
    [ "$status" -eq 0 ]

    run "$HOME/.local/bin/ssh-agent.sh"

    [ "$status" -eq 1 ]
    [[ "$output" == *'source ssh-agent.sh'* ]]
}

@test "свой префикс с пробелами и символами shell не исполняется как код" {
    # shellcheck disable=SC2016 # Подстановки должны остаться буквальной частью пути.
    prefix="$BATS_TEST_TMPDIR/"'with spaces $HOME; $(touch injected)'
    run_setup --prefix "$prefix" --source "$BATS_TEST_DIRNAME/.."
    [ "$status" -eq 0 ]

    run bash -c 'cd "$3"; source "$1/bin/ssh-agent.sh" "$2" <<< q' _ "$prefix" "$HOME/.ssh" "$BATS_TEST_TMPDIR"

    [ "$status" -eq 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/injected" ]
    run "$prefix/bin/ssh-agent-setup" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"Префикс: $prefix"* ]]
}

@test "права установленных файлов не зависят от umask" {
    run bash -c 'umask 077; bash "$1" --user' _ "$BATS_TEST_DIRNAME/../install.sh"
    [ "$status" -eq 0 ]
    package="$HOME/.local/libexec/ssh-agent"
    [ "$(stat -c %a "$package")" = 755 ]
    [ "$(stat -c %a "$package/lib")" = 755 ]
    [ "$(stat -c %a "$package/lib/keys.bash")" = 644 ]
    [ "$(stat -c %a "$package/lib/askpass.sh")" = 755 ]
    [ "$(stat -c %a "$package/.installation")" = 644 ]
}

@test "повторная установка обновляет модули и сохраняет дополнительные файлы" {
    run_setup --user
    [ "$status" -eq 0 ]
    package="$HOME/.local/libexec/ssh-agent"
    printf '# старая версия\n' > "$package/lib/keys.bash"
    printf 'Мой файл\n' > "$package/notes.txt"

    run_setup --user

    [ "$status" -eq 0 ]
    cmp "$package/lib/keys.bash" "$BATS_TEST_DIRNAME/../lib/keys.bash"
    [ "$(< "$package/notes.txt")" = 'Мой файл' ]
}

@test "посторонний запускной файл не перезаписывается" {
    mkdir -p "$HOME/.local/bin"
    for command in ssh-agent.sh ssh-agent-setup; do
        printf 'чужая программа\n' > "$HOME/.local/bin/$command"
        run_setup --user
        [ "$status" -ne 0 ]
        [ "$(< "$HOME/.local/bin/$command")" = 'чужая программа' ]
        [ ! -e "$HOME/.local/libexec/ssh-agent" ]
        rm "$HOME/.local/bin/$command"
    done
}

@test "посторонний каталог и ссылка вместо пакета не изменяются" {
    prefix="$BATS_TEST_TMPDIR/prefix"
    mkdir -p "$prefix/libexec/ssh-agent"
    printf 'данные\n' > "$prefix/libexec/ssh-agent/precious"
    run_setup --prefix "$prefix"
    [ "$status" -ne 0 ]
    [ "$(< "$prefix/libexec/ssh-agent/precious")" = данные ]

    mkdir -p "$BATS_TEST_TMPDIR/linked/libexec"
    ln -s "$prefix/libexec/ssh-agent" "$BATS_TEST_TMPDIR/linked/libexec/ssh-agent"
    run_setup --uninstall --prefix "$BATS_TEST_TMPDIR/linked"
    [ "$status" -ne 0 ]
    [ "$(< "$prefix/libexec/ssh-agent/precious")" = данные ]
}

@test "неполные исходники отклоняются до создания установки" {
    mkdir -p "$BATS_TEST_TMPDIR/incomplete"
    run_setup --user --source "$BATS_TEST_TMPDIR/incomplete"
    [ "$status" -ne 0 ]
    [ ! -e "$HOME/.local" ]
}

@test "загрузка с GitHub принимает SSH URL и устанавливает только известные файлы" {
    github_fixture
    run_setup --user --repo git@github.com:WhiteK0T/ssh-agent.git --ref test/v1

    [ "$status" -eq 0 ]
    [ "$(< "$BATS_TEST_TMPDIR/download.log")" = 'https://codeload.github.com/WhiteK0T/ssh-agent/tar.gz/test/v1' ]
    [ ! -e "$HOME/.local/libexec/ssh-agent/unrelated-file" ]
    [ -f "$HOME/.local/libexec/ssh-agent/lib/keys.bash" ]
}

@test "установщик поддерживает передачу через stdin без соседних исходников" {
    github_fixture
    run bash -c 'cat "$1" | bash -s -- --user' _ "$BATS_TEST_DIRNAME/../install.sh"

    [ "$status" -eq 0 ]
    [ "$(< "$BATS_TEST_TMPDIR/download.log")" = 'https://codeload.github.com/WhiteK0T/ssh-agent/tar.gz/HEAD' ]
    [ -x "$HOME/.local/bin/ssh-agent-setup" ]
}

@test "ошибка скачивания не создаёт частичную установку" {
    github_fixture
    export TEST_DOWNLOAD_FAILURE=1
    run_setup --user --repo WhiteK0T/ssh-agent

    [ "$status" -ne 0 ]
    [ ! -e "$HOME/.local" ]
}

@test "архив без нужного модуля отклоняется до установки" {
    github_fixture
    mv "$BATS_TEST_TMPDIR/snapshot/ssh-agent-snapshot/lib/keys.bash" "$BATS_TEST_TMPDIR/keys.bash"
    tar -czf "$BATS_TEST_TMPDIR/source.tar.gz" -C "$BATS_TEST_TMPDIR/snapshot" ssh-agent-snapshot

    run_setup --user --repo WhiteK0T/ssh-agent

    [ "$status" -ne 0 ]
    [ ! -e "$HOME/.local" ]
}

@test "удаление установленным менеджером определяет свой префикс и сохраняет ключи" {
    prefix="$BATS_TEST_TMPDIR/custom"
    before=$(sha256sum "$HOME/.ssh/01 first")
    run_setup --prefix "$prefix"
    [ "$status" -eq 0 ]

    run "$prefix/bin/ssh-agent-setup" --uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$prefix/bin/ssh-agent.sh" ]
    [ ! -e "$prefix/bin/ssh-agent-setup" ]
    [ ! -e "$prefix/libexec/ssh-agent" ]
    [ "$(sha256sum "$HOME/.ssh/01 first")" = "$before" ]
    run_setup --uninstall --prefix "$prefix"
    [ "$status" -eq 0 ]
}

@test "удаление сохраняет дополнительные файлы и допускает повторный запуск" {
    run_setup --user
    [ "$status" -eq 0 ]
    package="$HOME/.local/libexec/ssh-agent"
    printf 'Мои данные\n' > "$package/notes.txt"

    run_setup --uninstall --user

    [ "$status" -eq 0 ]
    [ "$(< "$package/notes.txt")" = 'Мои данные' ]
    [ ! -e "$package/ssh-agent.sh" ]
    run_setup --uninstall --user
    [ "$status" -eq 0 ]
}

@test "подменённый запускной файл блокирует удаление до любых изменений" {
    run_setup --user
    [ "$status" -eq 0 ]
    printf 'чужой файл\n' > "$HOME/.local/bin/ssh-agent.sh"

    run_setup --uninstall --user

    [ "$status" -ne 0 ]
    [ "$(< "$HOME/.local/bin/ssh-agent.sh")" = 'чужой файл' ]
    [ -f "$HOME/.local/libexec/ssh-agent/ssh-agent.sh" ]
}

@test "ошибка подготовки обновления оставляет прежнюю установку целой" {
    run_setup --user
    [ "$status" -eq 0 ]
    manager_before=$(sha256sum "$HOME/.local/bin/ssh-agent-setup")
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    real_install=$(command -v install)
    {
        cat <<'FAKE_INSTALL'
#!/usr/bin/env bash
# Тестовая подмена install: имитирует ошибку копирования одного модуля.
for arg in "$@"; do case "$arg" in */lib/keys.bash) exit 1 ;; esac; done
FAKE_INSTALL
        printf 'exec %q "$@"\n' "$real_install"
    } > "$BATS_TEST_TMPDIR/bin/install"
    chmod +x "$BATS_TEST_TMPDIR/bin/install"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    run_setup --user

    [ "$status" -ne 0 ]
    [ "$(sha256sum "$HOME/.local/bin/ssh-agent-setup")" = "$manager_before" ]
    cmp "$HOME/.local/libexec/ssh-agent/lib/keys.bash" "$BATS_TEST_DIRNAME/../lib/keys.bash"
}

@test "установленное меню сохраняет доступ к новому агенту в вызывающей оболочке" {
    run_setup --user
    [ "$status" -eq 0 ]

    run bash -c '
        set -euo pipefail
        export PATH="$1/bin:$PATH"
        trap '\''if [[ -n "${SSH_AGENT_PID:-}" ]]; then ssh-agent -k >/dev/null; fi'\'' EXIT
        source ssh-agent.sh "$2" 3>&- <<< $'\''\nq'\''
        [[ -n "$SSH_AUTH_SOCK" && -n "$SSH_AGENT_PID" ]]
        bash -c "ssh-add -l"
    ' _ "$HOME/.local" "$HOME/.ssh"

    [ "$status" -eq 0 ]
    [[ "$output" == *first* ]]
}

@test "удаление работает без OpenSSH, curl и программы install" {
    run_setup --user
    [ "$status" -eq 0 ]
    tools_dir="$BATS_TEST_TMPDIR/only-tools"
    mkdir -p "$tools_dir"
    for tool in bash realpath dirname mktemp rm rmdir; do
        ln -s "$(command -v "$tool")" "$tools_dir/$tool"
    done

    run env PATH="$tools_dir" "$HOME/.local/bin/ssh-agent-setup" --uninstall

    [ "$status" -eq 0 ]
    [ ! -e "$HOME/.local/bin/ssh-agent.sh" ]
    [ ! -e "$HOME/.local/libexec/ssh-agent" ]
}

@test "установленный менеджер может переустановить программу без исходного клона" {
    run_setup --user
    [ "$status" -eq 0 ]

    run "$HOME/.local/bin/ssh-agent-setup"

    [ "$status" -eq 0 ]
    cmp "$HOME/.local/libexec/ssh-agent/ssh-agent.sh" "$BATS_TEST_DIRNAME/../ssh-agent.sh"
    [ -x "$HOME/.local/bin/ssh-agent-setup" ]
}

@test "переустановка менеджером сохраняет свой префикс и посторонние файлы" {
    prefix="$BATS_TEST_TMPDIR/custom"
    run_setup --prefix "$prefix"
    [ "$status" -eq 0 ]
    printf 'Мои данные\n' > "$prefix/libexec/ssh-agent/notes.txt"
    printf 'команда OpenSSH\n' > "$prefix/bin/ssh-agent"

    run "$prefix/bin/ssh-agent-setup"

    [ "$status" -eq 0 ]
    [ -x "$prefix/bin/ssh-agent.sh" ]
    [ -x "$prefix/bin/ssh-agent-setup" ]
    [ "$(< "$prefix/bin/ssh-agent")" = 'команда OpenSSH' ]
    [ "$(< "$prefix/libexec/ssh-agent/notes.txt")" = 'Мои данные' ]
    run bash -c 'source "$1/bin/ssh-agent.sh" "$2" <<< q' _ "$prefix" "$HOME/.ssh"
    [ "$status" -eq 0 ]
    [[ "$output" == *'Ключи'* ]]
}

@test "отсутствие OpenSSH обнаруживается до создания установки" {
    tools_dir="$BATS_TEST_TMPDIR/only-tools"
    mkdir -p "$tools_dir"
    for tool in bash realpath dirname mktemp rm rmdir; do
        ln -s "$(command -v "$tool")" "$tools_dir/$tool"
    done

    run env PATH="$tools_dir" bash "$BATS_TEST_DIRNAME/../install.sh" --user

    [ "$status" -ne 0 ]
    [[ "$output" == *'Установите клиент OpenSSH'* ]]
    [ ! -e "$HOME/.local" ]
}

@test "при отсутствии curl загрузка выполняется через wget" {
    github_fixture
    tools_dir="$BATS_TEST_TMPDIR/wget-tools"
    mkdir -p "$tools_dir"
    for tool in bash realpath dirname mktemp rm rmdir tar gzip mkdir install mv chmod cp cat; do
        ln -s "$(command -v "$tool")" "$tools_dir/$tool"
    done
    for tool in ssh-agent ssh-add ssh-keygen; do
        printf '#!/usr/bin/env bash\n# Заглушка проверки наличия OpenSSH; ключи не обрабатывает.\nexit 0\n' > "$tools_dir/$tool"
        chmod +x "$tools_dir/$tool"
    done
    cat > "$tools_dir/wget" <<'WGET'
#!/usr/bin/env bash
# Тестовый файл wget: имитирует скачивание подготовленного архива без сети.
set -eu
for argument in "$@"; do
    case "$argument" in
        --output-document=*) destination=${argument#*=} ;;
        https://*) printf '%s\n' "$argument" > "$BATS_TEST_TMPDIR/wget.log" ;;
    esac
done
cp "$BATS_TEST_TMPDIR/source.tar.gz" "$destination"
WGET
    chmod +x "$tools_dir/wget"

    run env PATH="$tools_dir" bash "$BATS_TEST_DIRNAME/../install.sh" --user --repo WhiteK0T/ssh-agent

    [ "$status" -eq 0 ]
    [[ "$(< "$BATS_TEST_TMPDIR/wget.log")" == *'/WhiteK0T/ssh-agent/tar.gz/HEAD' ]]
    [ -x "$HOME/.local/bin/ssh-agent-setup" ]
}

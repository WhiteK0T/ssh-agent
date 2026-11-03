#!/usr/bin/env bats

# Файл: tests/release.bats. Проверка версии, changelog и воспроизводимого архива релиза.
# Создаёт отдельный Git-репозиторий в BATS_TEST_TMPDIR и не обращается к GitHub.

# Подготавливает изолированные метаданные релиза и копию средства упаковки.
setup() {
    command -v python3 >/dev/null || skip 'Для подготовки релиза нужен Python 3'
    release_repo="$BATS_TEST_TMPDIR/repository"
    mkdir -p "$release_repo/tools"
    cp "$BATS_TEST_DIRNAME/../tools/release.py" "$release_repo/tools/"
    cp "$BATS_TEST_DIRNAME/../LICENSE" "$release_repo/"
    printf '1.0.0\n' >"$release_repo/VERSION"
    cat >"$release_repo/CHANGELOG.md" <<'CHANGELOG'
# История изменений тестового проекта

## [Не выпущено]

## [1.0.0] - 2026-11-03

### Добавлено

- Тестовый выпуск.

[Не выпущено]: https://example.org/compare/v1.0.0...HEAD
CHANGELOG
}

# Создаёт коммит без зависимости от имени, почты и настройки подписи пользователя.
commit_fixture() {
    git -C "$release_repo" add .
    git -C "$release_repo" -c user.name=ReleaseTest -c user.email=release@example.invalid \
        -c commit.gpgsign=false commit -qm 'Release fixture'
}

@test "версия и запись changelog согласованы, некорректные теги отклоняются" {
    run python3 "$release_repo/tools/release.py" v1.0.0 --check
    [ "$status" -eq 0 ]
    for invalid in v01.0.0 v1.0 v1.0.1 latest v1.0.0-rc.1; do
        run python3 "$release_repo/tools/release.py" "$invalid" --check
        [ "$status" -eq 1 ]
    done
}

@test "релиз без записи об изменениях отклоняется" {
    printf '# История изменений\n' >"$release_repo/CHANGELOG.md"

    run python3 "$release_repo/tools/release.py" v1.0.0 --check

    [ "$status" -eq 1 ]
    [[ "$output" == *CHANGELOG.md* ]]
}

@test "архив релиза содержит только файлы тега и соответствует SHA256" {
    git init -q "$release_repo"
    commit_fixture
    git -C "$release_repo" -c tag.gpgsign=false tag v1.0.0
    printf 'Не включать в архив\n' >"$release_repo/untracked.txt"
    release_output="$BATS_TEST_TMPDIR/artifacts"

    run python3 "$release_repo/tools/release.py" v1.0.0 --output "$release_output"

    [ "$status" -eq 0 ]
    run bash -c 'cd "$1" && sha256sum --check SHA256SUMS' _ "$release_output"
    [ "$status" -eq 0 ]
    run tar -tzf "$release_output/ssh-agent-1.0.0.tar.gz"
    [[ "$output" == *'ssh-agent-1.0.0/LICENSE'* ]]
    [[ "$output" == *'ssh-agent-1.0.0/VERSION'* ]]
    [[ "$output" != *untracked.txt* && "$output" != *'.git/'* ]]
    [[ "$(<"$release_output/notes.md")" == *'### Добавлено'* ]]
    [[ "$(<"$release_output/notes.md")" != *'[Не выпущено]:'* ]]
}

@test "упаковка отклоняет изменённые файлы и коммит за пределами тега" {
    git init -q "$release_repo"
    commit_fixture
    git -C "$release_repo" -c tag.gpgsign=false tag v1.0.0
    printf '\n' >>"$release_repo/CHANGELOG.md"

    run python3 "$release_repo/tools/release.py" v1.0.0 --output "$BATS_TEST_TMPDIR/artifacts"
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/artifacts" ]

    commit_fixture
    run python3 "$release_repo/tools/release.py" v1.0.0 --output "$BATS_TEST_TMPDIR/artifacts"
    [ "$status" -eq 1 ]
    [[ "$output" == *'коммит выпускаемого тега'* ]]
    [ ! -e "$BATS_TEST_TMPDIR/artifacts" ]
}

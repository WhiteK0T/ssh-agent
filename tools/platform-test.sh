#!/usr/bin/env bash

# Файл: tools/platform-test.sh. Подготовка зависимостей только внутри контейнера CI.
# DISTRO задаёт дистрибутив; исходники доступны в /work без права записи.
set -euo pipefail
if [[ "${SSH_AGENT_CI_CONTAINER:-}" != 1 || ! -f /.dockerenv ]] || ((EUID != 0)); then
    printf 'Этот скрипт предназначен только для контейнеров workflow Platforms.\n' >&2
    exit 1
fi
case "${DISTRO:-}" in
    ubuntu | debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install --yes --no-install-recommends bash coreutils diffutils openssh-client
        ;;
    arch)
        pacman -Syu --noconfirm --needed bash coreutils diffutils openssh
        ;;
    gentoo)
        emerge-webrsync
        emerge --getbinpkgonly --oneshot --noreplace net-misc/openssh sys-apps/diffutils
        ;;
    *)
        printf 'Неизвестный дистрибутив: %s\n' "${DISTRO:-}" >&2
        exit 1
        ;;
esac
bash tools/smoke-install.sh

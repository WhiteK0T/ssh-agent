_ssh_agent_is_private_key() {
    local file=$1 header=''
    [[ -f "$file" && -r "$file" ]] || return 1
    # Проверяем только маркер формата, не выводя содержимое приватного ключа.
    IFS= read -r header < "$file" || :
    case "${header%$'\r'}" in
        '-----BEGIN OPENSSH PRIVATE KEY-----' | \
        '-----BEGIN RSA PRIVATE KEY-----' | \
        '-----BEGIN DSA PRIVATE KEY-----' | \
        '-----BEGIN EC PRIVATE KEY-----' | \
        '-----BEGIN PRIVATE KEY-----' | \
        '-----BEGIN ENCRYPTED PRIVATE KEY-----') return 0 ;;
        *) return 1 ;;
    esac
}

_ssh_agent_key_details() {
    local file=$1 details public_details _bits fingerprint public_fingerprint _comment
    # Чтение через stdin исключает автоматическую подмену отпечатка соседним .pub.
    # Для старых зашифрованных PEM-ключей всё же нужен соответствующий .pub.
    if ! details=$(ssh-keygen -l -E sha256 -f /dev/stdin 2>/dev/null < "$file"); then
        details=$(ssh-keygen -l -E sha256 -f "$file.pub" </dev/null 2>/dev/null) || return 1
    fi
    IFS=' ' read -r _bits fingerprint _comment <<< "$details"
    [[ "$fingerprint" == SHA256:* ]] || return 1

    # Комментарий берём из .pub только при совпадении отпечатков.
    if [[ -r "$file.pub" ]] &&
        public_details=$(ssh-keygen -l -E sha256 -f "$file.pub" </dev/null 2>/dev/null); then
        IFS=' ' read -r _bits public_fingerprint _comment <<< "$public_details"
        if [[ "$public_fingerprint" == "$fingerprint" ]]; then
            details=$public_details
        fi
    fi
    printf '%s\n' "$details"
}

_ssh_agent_key_fingerprint() {
    local details _bits fingerprint _comment
    details=$(_ssh_agent_key_details "$1") || return 1
    IFS=' ' read -r _bits fingerprint _comment <<< "$details"
    printf '%s\n' "$fingerprint"
}

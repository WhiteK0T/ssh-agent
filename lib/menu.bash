_ssh_agent_read_action() {
    local key suffix direction terminator
    IFS= read -r -s -n 1 key || return 1
    case "$key" in
        $'\e')
            # Короткое ожидание отличает одиночный Esc от последовательности стрелки.
            if ! IFS= read -r -s -n 1 -t 0.1 suffix; then
                printf 'quit'
            elif [[ "$suffix" == '[' || "$suffix" == O ]]; then
                IFS= read -r -s -n 1 -t 0.1 direction || return 0
                case "$direction" in
                    A) printf 'up' ;;
                    B) printf 'down' ;;
                    H) printf 'home' ;;
                    F) printf 'end' ;;
                    1 | 4 | 7 | 8)
                        IFS= read -r -s -n 1 -t 0.1 terminator || return 0
                        if [[ "$terminator" == '~' ]]; then
                            case "$direction" in
                                1 | 7) printf 'home' ;;
                                4 | 8) printf 'end' ;;
                            esac
                        fi
                        ;;
                esac
            fi
            ;;
        '') printf 'toggle' ;;
        ' ') printf 'mark' ;;
        a | A) printf 'add' ;;
        d | D) printf 'remove' ;;
        q | Q) printf 'quit' ;;
        k) printf 'up' ;;
        j) printf 'down' ;;
    esac
}

_ssh_agent_draw_menu() {
    local redraw=$1 interactive=$2 page_size=$3 offset=$4 cursor=$5 message=$6
    shift 6
    local -a entries=("$@")
    local row index line eol='' height=$((page_size * 2 + 5))

    (( interactive )) && eol=$'\e[K'

    if (( redraw )); then
        # Возвращаемся только к началу собственного блока, не очищая экран.
        printf '\033[%dA\r' "$height"
    fi
    printf 'Приватные SSH-ключи%s\n' "$eol"
    printf 'Позиция %d из %d; [x] — отмечен%s\n' "$((cursor + 1))" "${#entries[@]}" "$eol"
    for ((row = 0; row < page_size; row++)); do
        index=$((offset + row))
        if (( index < ${#entries[@]} )); then
            while IFS= read -r line; do
                printf '%s%s\n' "$line" "$eol"
            done <<< "${entries[index]}"
        else
            printf '%s\n%s\n' "$eol" "$eol"
        fi
    done
    printf '%s%s\n' "$message" "$eol"
    printf '↑/↓ — перемещение; Space — отметка; Enter — +/-%s\n' "$eol"
    printf 'a — добавить отмеченные; d — выгрузить; q/Esc — выход%s\n' "$eol"
}

_ssh_agent_terminal_layout() {
    local rows=24 columns=80 interactive=0 size
    if size=$(stty size 2>/dev/null); then
        IFS=' ' read -r rows columns <<< "$size"
        if [[ "$rows" =~ ^[1-9][0-9]{0,4}$ && "$columns" =~ ^[1-9][0-9]{0,4}$ ]]; then
            if (( rows >= 12 && columns >= 60 )); then
                interactive=1
            fi
        else
            rows=24 columns=80
        fi
    fi
    printf '%s %s %s\n' "$rows" "$columns" "$interactive"
}

_ssh_agent_format_entry() {
    local file=$1 fingerprint=$2 loaded_fingerprints=$3 current=$4 marked=$5 columns=$6
    local pointer=' ' marker=' ' state='не загружен' label name_width

    (( current )) && pointer='>'
    (( marked )) && marker=x
    if [[ -z "$fingerprint" ]]; then
        state='статус неизвестен'
        fingerprint='Отпечаток недоступен'
    elif [[ "$loaded_fingerprints" == *$'\n'"$fingerprint"$'\n'* ]]; then
        state='уже загружен'
    fi
    # ASCII-представление имени исключает управляющие символы и переносы широких символов.
    LC_ALL=C printf -v label '%q' "${file##*/}"
    name_width=$((columns - 10 - ${#state}))
    (( name_width >= 5 )) || name_width=5
    if (( ${#label} > name_width )); then
        label="${label:0:name_width-3}..."
    fi
    printf '%s [%s] %s — %s\n      %s\n' "$pointer" "$marker" "$label" "$state" "$fingerprint"
}

_ssh_agent_menu() {
    local -a keys=("$@") fingerprints=() marked=() entries=() selected=()
    local index cursor=0 offset page_size=1 rows=24 columns=80 previous_size=''
    local interactive=0 redraw=0 loaded_fingerprints action operation fingerprint marked_count
    local message='Изменения применяются сразу.' result=0

    for index in "${!keys[@]}"; do
        fingerprints[index]=$(_ssh_agent_key_fingerprint "${keys[index]}") ||
            fingerprints[index]=''
        marked[index]=0
    done

    while :; do
        # Размер проверяется заново: при изменении окна выводим новый блок ниже.
        if [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]]; then
            IFS=' ' read -r rows columns interactive < <(_ssh_agent_terminal_layout)
        else
            rows=24 columns=80 interactive=0
        fi
        if [[ "$rows $columns" != "$previous_size" ]]; then
            redraw=0
        fi
        previous_size="$rows $columns"
        page_size=$(((rows - 7) / 2))
        (( page_size >= 1 )) || page_size=1
        (( page_size <= ${#keys[@]} )) || page_size=${#keys[@]}
        offset=$((cursor / page_size * page_size))
        loaded_fingerprints=$'\n'"$(_ssh_agent_loaded_fingerprints)"$'\n'
        marked_count=0

        for index in "${!keys[@]}"; do
            marked_count=$((marked_count + marked[index]))
            entries[index]=$(_ssh_agent_format_entry "${keys[index]}" "${fingerprints[index]}" \
                "$loaded_fingerprints" "$((index == cursor))" "${marked[index]}" "$columns")
        done

        _ssh_agent_draw_menu "$((redraw && interactive))" "$interactive" \
            "$page_size" "$offset" "$cursor" "$message" "${entries[@]}"
        redraw=$interactive
        action=$(_ssh_agent_read_action) || break
        case "$action" in
            up) (( cursor > 0 )) && cursor=$((cursor - 1)); continue ;;
            down) (( cursor + 1 < ${#keys[@]} )) && cursor=$((cursor + 1)); continue ;;
            home) cursor=0; continue ;;
            end) cursor=$((${#keys[@]} - 1)); continue ;;
            mark) marked[cursor]=$((1 - marked[cursor])); continue ;;
            quit) break ;;
            toggle)
                selected=("${keys[cursor]}")
                operation=add
                loaded_fingerprints=$'\n'"$(_ssh_agent_loaded_fingerprints)"$'\n'
                fingerprint=${fingerprints[cursor]}
                if [[ -n "$fingerprint" && "$loaded_fingerprints" == *$'\n'"$fingerprint"$'\n'* ]]; then
                    operation=remove
                fi
                ;;
            add | remove)
                if (( marked_count == 0 )); then
                    message='Сначала отметьте ключи пробелом.'
                    continue
                fi
                selected=()
                for index in "${!keys[@]}"; do
                    if (( marked[index] )); then
                        selected+=("${keys[index]}")
                    fi
                done
                operation=$action
                ;;
            *) continue ;;
        esac

        # Вывод ssh-add и запрос пароля остаются под меню, а не внутри перерисовки.
        printf '\n'
        redraw=0
        if _ssh_agent_change_keys "$operation" "${selected[@]}"; then
            if [[ "$operation" == add ]]; then
                message='Ключи добавлены.'
            else
                message='Ключи выгружены.'
            fi
            for index in "${!keys[@]}"; do
                marked[index]=0
            done
        else
            result=1
            message='Не все изменения применены. Подробности выше.'
        fi
    done

    _ssh_agent_show_identities
    return "$result"
}

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

_ssh_agent_menu() {
    local -a keys=("$@") fingerprints=() algorithms=() comments=() cells=() marked=() entries=() selected=()
    local index cursor=0 offset page_size=1 rows=24 columns=80 previous_size=''
    local interactive=0 redraw=0 loaded_fingerprints action operation fingerprint marked_count
    local message='Изменения применяются сразу.' result=0
    local details _bits description algorithm

    for index in "${!keys[@]}"; do
        fingerprints[index]='' algorithms[index]='—' comments[index]='—'
        if details=$(_ssh_agent_key_details "${keys[index]}"); then
            IFS=' ' read -r _bits fingerprint description <<< "$details"
            fingerprints[index]=$fingerprint
            algorithm=${description##* (}
            algorithm=${algorithm%)}
            algorithms[index]=$(printf '%s' "$algorithm" | tr '[:upper:]' '[:lower:]')
            comments[index]=${description%" ($algorithm)"}
            [[ "${comments[index]}" != '(no comment)' ]] || comments[index]='—'
        fi
        marked[index]=0
    done

    while :; do
        # Размер проверяется заново: при изменении окна выводим новый блок ниже.
        if [[ -t 0 && -t 1 && "${TERM:-dumb}" != dumb ]]; then
            IFS=' ' read -r rows columns interactive < <(_ssh_agent_terminal_layout)
        else
            rows=24 columns=80 interactive=0
        fi
        # В очень узком окне вывод последовательный; минимальная ширина сохраняет колонки.
        (( columns >= 60 )) || columns=60
        if [[ "$rows $columns" != "$previous_size" ]]; then
            redraw=0
            # Ширину колонок пересчитываем только при изменении размеров окна.
            for index in "${!keys[@]}"; do
                cells[index]=$(_ssh_agent_format_cells "$columns" "${keys[index]##*/}" \
                    "${algorithms[index]}" "${fingerprints[index]}" "${comments[index]}")
            done
        fi
        previous_size="$rows $columns"
        page_size=$((rows - 11))
        (( page_size >= 1 )) || page_size=1
        (( page_size <= ${#keys[@]} )) || page_size=${#keys[@]}
        offset=$((cursor / page_size * page_size))
        loaded_fingerprints=$'\n'"$(_ssh_agent_loaded_fingerprints)"$'\n'
        marked_count=0

        for index in "${!keys[@]}"; do
            marked_count=$((marked_count + marked[index]))
            entries[index]=$(_ssh_agent_format_entry "${cells[index]}" "${fingerprints[index]}" \
                "$loaded_fingerprints" "$((index == cursor))" "${marked[index]}" "$interactive")
        done

        _ssh_agent_draw_menu "$((redraw && interactive))" "$interactive" \
            "$page_size" "$offset" "$cursor" "$message" "$columns" \
            "${fingerprints[cursor]}" "$marked_count" "${entries[@]}"
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

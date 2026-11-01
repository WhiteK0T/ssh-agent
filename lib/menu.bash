# Файл: lib/menu.bash. Обработка клавиатуры и основной цикл меню SSH-ключей.
# Связывает чтение метаданных, отрисовку таблицы и операции с агентом.
# Требует подключённых lib/keys.bash, lib/agent.bash и lib/table.bash.

# Читает клавишу или последовательность терминала и выводит имя действия.
# Аргументов нет; неизвестной клавише соответствует пустая строка с кодом 0.
# При конце ввода возвращает 1; Enter, стрелки и Esc обрабатываются отдельно.
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

# Определяет размеры терминала и возможность перерисовывать меню на месте.
# Аргументов нет; выводит три числа: строки, столбцы и признак перерисовки 0/1.
# При недоступном stty использует 24×80 без перерисовки; ожидает терминал на stdin.
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

# Показывает таблицу и обрабатывает выбор, загрузку, выгрузку и выход.
# Аргументы: непустой список абсолютных путей к приватным ключам.
# Сохраняет окружение нового агента; возвращает 1, если хотя бы одно действие не удалось.
# В обычном терминале обновляет один блок, оставляя его на экране после выхода.
_ssh_agent_menu() {
    local -a keys=("$@") fingerprints=() algorithms=() comments=() cells=() marked=() entries=() selected=()
    local index cursor=0 offset page_size=1 rows=24 columns=80 previous_size=''
    local interactive=0 redraw=0 loaded_fingerprints action operation fingerprint marked_count
    local message='Изменения применяются сразу.' result=0
    local details _bits description algorithm
    local askpass="${BASH_SOURCE[0]%/*}/askpass.sh"

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

        # Агент запускается в вызывающей оболочке, чтобы сохранить его окружение.
        if [[ "$operation" == add ]] && ! _ssh_agent_ensure_running >/dev/null 2>&1; then
            result=1
            message='Не удалось запустить SSH-агент.'
            continue
        fi
        if (( interactive )); then
            # Строка состояния находится на четыре строки выше конца блока меню.
            printf '\033[4A\r\033[K Выполняется…'
        fi
        # Вывод команды сохраняем в памяти; askpass читает пароль прямо из терминала.
        # Изменения ключей выполняет сам агент, поэтому команду можно захватить в подоболочке.
        if details=$(SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
            SSH_AGENT_MENU_COLUMNS="$columns" SSH_AGENT_MENU_INLINE="$interactive" \
            _ssh_agent_change_keys "$operation" "${selected[@]}" 2>&1); then
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
            details=${details%%$'\n'*}
            message=$(_ssh_agent_fit_cell "Не все изменения применены. ${details##*: }" "$((columns - 2))")
        fi
        if (( interactive )); then
            # Запрос пароля не переводит строку; возвращаемся к концу того же блока.
            printf '\033[4B\r'
        fi
    done

    _ssh_agent_show_identities
    return "$result"
}

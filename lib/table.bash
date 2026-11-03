# Файл: lib/table.bash. Форматирование колонок и отрисовка таблицы SSH-ключей.
# Подключается через source; отвечает за экранирование текста, цвета и рамку.
# Не читает файлы ключей и не меняет состояние агента.

# Подготавливает текст для ячейки: экранирует управляющие и мешающие ширине символы.
# Аргумент $1: исходный текст. Выводит обработанную строку без завершающего перевода строки.
_ssh_agent_safe_text() {
    local text=$1 index character code result=''
    for ((index = 0; index < ${#text}; index++)); do
        character=${text:index:1}
        printf -v code '%d' "'$character"
        case "$character" in
            $'\e') character='\e' ;;
            $'\n') character='\n' ;;
            $'\r') character='\r' ;;
            $'\t') character='\t' ;;
            '—' | '…') ;;
            *)
                # Обычный текст, включая кириллицу, остаётся читаемым.
                # Широкие и управляющие символы экранируем ради точной ширины таблицы.
                if ((code < 32 || code >= 127 && code <= 159 || \
                    code >= 768 && code <= 879 || code >= 1155 && code <= 1161 || code >= 4352)); then
                    LC_ALL=C printf -v character '%q' "$character"
                fi
                ;;
        esac
        result+=$character
    done
    printf '%s' "$result"
}

# Экранирует текст, сокращает его многоточием и дополняет пробелами до ширины ячейки.
# Аргументы: $1 — текст, $2 — положительная ширина. Вывод не содержит перевода строки.
_ssh_agent_fit_cell() {
    local text width=$2 padding
    text=$(_ssh_agent_safe_text "$1")
    if ((${#text} > width)); then
        text="${text:0:width-1}…"
    fi
    printf -v padding '%*s' "$((width - ${#text}))" ''
    printf '%s%s' "$text" "$padding"
}

# Формирует колонки ключа или заголовка с учётом ширины окна, не добавляя рамку.
# Аргументы: $1 — ширина не менее 60; $2 — имя; $3 — алгоритм;
# $4 — отпечаток; $5 — комментарий. Выводит одну строку ячеек без перевода строки.
_ssh_agent_format_cells() {
    local columns=$1 name=$2 algorithm=$3 fingerprint=$4 comment=$5
    local name_width=$((columns / 5)) algorithm_width=9 fingerprint_width=18 comment_width
    ((name_width <= 32)) || name_width=32
    if ((columns >= 108)); then
        fingerprint_width=50
    fi
    comment_width=$((columns - 4 - 8 - name_width - algorithm_width - fingerprint_width - 6))
    _ssh_agent_fit_cell "$name" "$name_width"
    printf '  '
    _ssh_agent_fit_cell "$algorithm" "$algorithm_width"
    printf '  '
    _ssh_agent_fit_cell "${fingerprint:-—}" "$fingerprint_width"
    printf '  '
    _ssh_agent_fit_cell "${comment:-—}" "$comment_width"
}

# Дополняет ячейки курсором, отметкой выбора и индикатором загрузки в агент.
# Аргументы: $1 — готовые ячейки, $2 — отпечаток, $3 — список загруженных отпечатков
# с разделителями-переводами строк; $4/$5/$6 — признаки курсора, отметки и цвета 0/1.
# Выводит готовую строку ключа; ANSI-оформление добавляется только при $6=1.
_ssh_agent_format_entry() {
    local cells=$1 fingerprint=$2 loaded_fingerprints=$3 current=$4 marked=$5 color=$6
    local pointer=' ' marker=' ' indicator='○' tone=90 row_style='' indicator_style='' reset=''
    ((current)) && pointer='›'
    ((marked)) && marker=x
    if [[ -z "$fingerprint" ]]; then
        indicator='?' tone=33
    elif [[ "$loaded_fingerprints" == *$'\n'"$fingerprint"$'\n'* ]]; then
        indicator='●' tone=32
    fi
    if ((color)); then
        reset=$'\e[0m'
        row_style=$reset
        ((current)) && row_style=$'\e[48;5;236m\e[1;36m'
        printf -v indicator_style '\033[%sm' "$tone"
    fi
    printf '%s%s %s%s%s [%s] %s%s' \
        "$row_style" "$pointer" "$indicator_style" "$indicator" "$row_style" "$marker" "$cells" "$reset"
}

# Печатает один блок меню либо перерисовывает существующий, не очищая экран.
# Аргументы: $1 — перерисовка 0/1; $2 — цвет 0/1; $3 — число видимых строк;
# $4 — смещение списка; $5 — индекс курсора (оба с нуля); $6 — сообщение;
# $7 — ширина; $8 — полный отпечаток; $9 — число отметок; остальные — строки ключей.
# После вывода курсор находится под блоком; его высота равна $3 + 9 строкам.
_ssh_agent_draw_menu() {
    local redraw=$1 color=$2 page_size=$3 offset=$4 cursor=$5 message=$6 columns=$7
    local fingerprint=$8 marked_count=$9
    shift 9
    local -a entries=("$@")
    local index row border_line header title counter padding
    local border='' accent='' tab='' loaded_color='' reset='' eol='' height=$((page_size + 9))

    if ((color)); then
        border=$'\e[90m' accent=$'\e[1;35m' tab=$'\e[30;105m' reset=$'\e[0m' eol=$'\e[K'
        loaded_color=$'\e[32m'
    fi
    if ((redraw)); then
        # Перерисовываем только собственный блок, сохраняя историю терминала.
        printf '\033[%dA\r' "$height"
    fi
    printf -v counter '%d/%d  отмечено: %d' "$((cursor + 1))" "${#entries[@]}" "$marked_count"
    title=' ssh-agent   Ключи '
    printf -v padding '%*s' "$((columns - 1 - ${#title} - ${#counter}))" ''
    printf ' %sssh-agent%s  %s Ключи %s%s%s%s\n' \
        "$accent" "$reset" "$tab" "$reset" "$padding" "$counter" "$eol"
    printf -v border_line '%*s' "$((columns - 4))" ''
    border_line=${border_line// /─}
    printf ' %s╭%s╮%s%s\n' "$border" "$border_line" "$reset" "$eol"
    header=$(_ssh_agent_format_cells "$columns" 'Ключ' 'Алгоритм' 'Отпечаток' 'Комментарий')
    printf ' %s│        %s│%s%s\n' "$border" "$header" "$reset" "$eol"
    for ((row = 0; row < page_size; row++)); do
        index=$((offset + row))
        if ((index < ${#entries[@]})); then
            printf ' %s│%s%s%s│%s%s\n' "$border" "$reset" "${entries[index]}" "$border" "$reset" "$eol"
        else
            printf ' %s│%*s│%s%s\n' "$border" "$((columns - 4))" '' "$reset" "$eol"
        fi
    done
    printf ' %s╰%s╯%s%s\n' "$border" "$border_line" "$reset" "$eol"
    printf ' %s%s\n' "${fingerprint:-Отпечаток недоступен}" "$eol"
    printf ' %s%s\n' "$message" "$eol"
    printf ' %s●%s уже загружен  ○ не загружен  ? статус неизвестен%s\n' "$loaded_color" "$reset" "$eol"
    printf ' ↑/↓ — перемещение; Space — отметка; Enter — +/-%s\n' "$eol"
    printf ' a — добавить отмеченные; d — выгрузить; q/Esc — выход%s\n' "$eol"
}

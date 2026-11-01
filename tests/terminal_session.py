"""Файл tests/terminal_session.py: проверка меню в настоящем псевдотерминале.

Запускается из Bats с путём к ssh-agent.sh и именем сценария. Имитирует клавиатуру,
проверяет сохранение истории, отсутствие копий меню и скрытый ввод пароля.
Использует стандартную библиотеку Python; ключи и HOME предоставляет фикстура Bats.
"""

import errno
import fcntl
import os
import pathlib
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time
import unicodedata


class Terminal:
    """Модель используемых меню команд терминала и истории прокрутки."""

    def __init__(self, rows, columns):
        """Создаёт пустой экран rows×columns, историю прокрутки и курсор в начале."""
        self.rows = rows
        self.columns = columns
        self.screen = [[" "] * columns for _ in range(rows)]
        self.history = []
        self.row = 0
        self.column = 0

    def render(self, text):
        """Применяет текст и поддерживаемые ANSI-команды; возвращает историю и экран."""
        tokens = re.findall(r"\x1b\[[0-9;?]*[A-Za-z]|[^\x1b]", text)
        for token in tokens:
            if token.startswith("\x1b["):
                if token.endswith("A"):
                    self.row = max(0, self.row - int(token[2:-1]))
                elif token.endswith("B"):
                    self.row = min(self.rows - 1, self.row + int(token[2:-1]))
                elif token == "\x1b[K":
                    self.screen[self.row][self.column:] = [" "] * (self.columns - self.column)
                elif token.endswith("m"):
                    pass
                else:
                    raise AssertionError(f"Неожиданная команда терминала: {token!r}")
            elif token == "\r":
                self.column = 0
            elif token == "\n":
                self.new_line()
            elif token >= " ":
                width = 2 if unicodedata.east_asian_width(token) in ("F", "W") else 1
                if self.column + width > self.columns:
                    self.column = 0
                    self.new_line()
                self.screen[self.row][self.column] = token
                self.column += width
        return "\n".join(self.history + ["".join(row).rstrip() for row in self.screen])

    def new_line(self):
        """Сдвигает курсор вниз, при выходе за экран переносит верхнюю строку в историю."""
        self.row += 1
        if self.row == self.rows:
            self.history.append("".join(self.screen.pop(0)).rstrip())
            self.screen.append([" "] * self.columns)
            self.row -= 1


def check_session(script, mode):
    """Запускает Bash со скриптом script в PTY и проверяет выбранный сценарий mode.

    Режимы: navigation, pages, wide, narrow, resize, actions и encrypted.
    При нарушении ожидаемого поведения поднимает AssertionError и печатает сеанс.
    После проверки завершает дочерний процесс и закрывает дескрипторы PTY.
    """
    rows, columns = (14, 60) if mode == "pages" else (24, 80)
    if mode == "wide":
        columns = 140
    elif mode == "narrow":
        columns = 40
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
    original_settings = termios.tcgetattr(slave)
    environment = dict(os.environ, TERM="xterm-256color")
    shell = r"""
        set -euo pipefail
        trap 'if [[ -n "${SSH_AGENT_PID:-}" ]]; then ssh-agent -k >/dev/null; fi' EXIT
        printf 'BEFORE_MENU_SENTINEL\n'
        source "$1" "$HOME/.ssh"
        printf 'AFTER_MENU_SENTINEL\n'
        ssh-add -l
    """

    def attach_terminal():
        """Создаёт сессию дочернего процесса и назначает stdin управляющим терминалом."""
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    process = subprocess.Popen(
        ["bash", "--noprofile", "--norc", "-c", shell, "menu-test", script],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=environment,
        preexec_fn=attach_terminal,
    )

    def send_keys(keys):
        """Ожидает отключения эха и отправляет байты keys; таймаут готовности — 2 секунды."""
        # Подсказка уже видна, но read мог ещё не успеть отключить эхо ввода.
        ready_deadline = time.monotonic() + 2
        while termios.tcgetattr(slave)[3] & termios.ECHO:
            assert time.monotonic() < ready_deadline, "Терминал не готов к скрытому вводу"
            time.sleep(0.005)
        os.write(master, keys)

    transcript = bytearray()
    stage = 0
    resize_start = None
    deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            readable, _, _ = select.select([master], [], [], 0.1)
            if readable:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                transcript.extend(chunk)
                current_text = transcript.decode("utf-8", errors="replace")
                frames = current_text.count("q/Esc — выход")
                if stage == 0 and frames >= 1:
                    if mode == "resize":
                        keys = b" "
                    elif mode == "encrypted":
                        keys = b"\n"
                    elif mode == "actions":
                        keys = b"\n\n\n\x1b[B\nq"
                    else:
                        keys = b"\x1b[F\nq" if mode == "pages" else b"\x1b[B \x1b[A aq"
                    send_keys(keys)
                    stage = 1
                elif mode == "resize" and stage == 1 and frames >= 2:
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 14, 60, 0, 0))
                    resize_start = len(transcript)
                    send_keys(b"\x1b[Baq")
                    stage = 2
                elif mode == "encrypted":
                    if stage == 1 and "Enter passphrase" in current_text:
                        send_keys(b"incorrect-test\n")
                        stage = 2
                    elif stage == 2 and "Bad passphrase" in current_text:
                        send_keys(b"test-password\n")
                        stage = 3
                    elif stage == 3 and frames >= 2:
                        # Выгружаем ключ и снова загружаем, проверяя повторный запрос пароля.
                        send_keys(b"\n\n")
                        stage = 4
                    elif stage == 4 and current_text.count("Enter passphrase") >= 2:
                        send_keys(b"test-password\n")
                        stage = 5
                    elif stage == 5 and frames >= 4:
                        send_keys(b"q")
                        stage = 6
            if process.poll() is not None and not readable:
                break

        assert process.poll() is not None, "Меню не завершилось за 15 секунд"
        assert process.returncode == 0, f"Код завершения: {process.returncode}"
        assert termios.tcgetattr(slave) == original_settings, "Настройки терминала изменились"
        output = transcript.decode("utf-8", errors="replace")
        if mode == "narrow":
            assert "\x1b" not in output, "В узком окне включена перерисовка"
        else:
            assert re.search(r"\x1b\[\d+A", output), "Не проверена перерисовка меню"
        if mode == "wide":
            plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", output)
            key_rows = [line for line in plain.splitlines() if "│" in line and "[ ]" in line]
            assert key_rows, "Строки таблицы не найдены"
            for line in key_rows:
                assert re.search(r"SHA256:[A-Za-z0-9+/]{43}", line), "Отпечаток сокращён в широком окне"
        sections = [(output, columns)]
        if resize_start is not None:
            after_resize = transcript[resize_start:].decode("utf-8", errors="replace")
            plain_after_resize = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", after_resize)
            assert plain_after_resize.startswith(" ssh-agent"), "При изменении размера затронут старый блок"
            sections = [(transcript[:resize_start].decode("utf-8"), columns), (after_resize, 60)]
        for section, section_columns in sections:
            in_menu = False
            for line in re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", section).splitlines():
                if line.startswith(" ssh-agent"):
                    in_menu = True
                if in_menu and mode != "narrow":
                    assert len(line) <= section_columns, "Строка меню выходит за ширину терминала"
                if line.lstrip().startswith("a — добавить отмеченные"):
                    in_menu = False
        if mode == "resize":
            assert resize_start is not None, "Не проверено изменение размера окна"
            visible = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", output)
        else:
            visible = Terminal(rows, columns).render(output)
        assert "BEFORE_MENU_SENTINEL" in visible, "Вывод перед меню был затёрт"
        assert "AFTER_MENU_SENTINEL" in visible, "Оболочка не продолжила работу после source"
        assert "ssh-agent   Ключи" in visible, "Меню исчезло после выхода"
        if mode != "narrow":
            assert "\x1b[48;5;236m" in output, "Текущая строка не подсвечена"
            assert "\x1b[32m●" in output, "Индикатор загрузки не окрашен зелёным"
        assert "● [ ]" in visible, "Загруженный ключ не отмечен в таблице"
        assert "уже загружен" in visible, "Состояние загруженного ключа не обновилось"
        assert "Ключи в SSH-агенте (ssh-add -l):" in visible, "Итоговый список не сохранён"
        if mode == "pages":
            assert ".03_hidden" in visible, "Последняя страница не показана"
        elif mode not in ("encrypted", "actions"):
            assert "[x]" in output, "Отметка ключа не отображается"
        if mode == "encrypted":
            assert stage == 6, "Не проверен повторный ввод пароля"
            assert "test-password" not in output, "Пароль оказался в выводе терминала"
            assert "incorrect-test" not in output, "Неверный пароль оказался в выводе терминала"
        if mode not in ("resize", "narrow"):
            assert visible.count("ssh-agent   Ключи") == 1, "После действия остались копии меню"
        print("Вывод до меню, само меню, итоговый список и настройки терминала сохранены.")
    except (AssertionError, OSError):
        print(transcript.decode("utf-8", errors="replace"))
        raise
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        os.close(master)
        os.close(slave)


if __name__ == "__main__":
    check_session(str(pathlib.Path(sys.argv[1]).resolve()), sys.argv[2])

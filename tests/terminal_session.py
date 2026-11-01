"""Проверка меню в псевдотерминале и сохранности предыдущего вывода."""

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
        self.rows = rows
        self.columns = columns
        self.screen = [[" "] * columns for _ in range(rows)]
        self.history = []
        self.row = 0
        self.column = 0

    def render(self, text):
        tokens = re.findall(r"\x1b\[[0-9;?]*[A-Za-z]|[^\x1b]", text)
        for token in tokens:
            if token.startswith("\x1b["):
                if token.endswith("A"):
                    self.row = max(0, self.row - int(token[2:-1]))
                elif token == "\x1b[K":
                    self.screen[self.row][self.column:] = [" "] * (self.columns - self.column)
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
        self.row += 1
        if self.row == self.rows:
            self.history.append("".join(self.screen.pop(0)).rstrip())
            self.screen.append([" "] * self.columns)
            self.row -= 1


def check_session(script, mode):
    rows, columns = (14, 60) if mode == "pages" else (24, 80)
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
    process = subprocess.Popen(
        ["bash", "--noprofile", "--norc", "-c", shell, "menu-test", script],
        stdin=slave,
        stdout=slave,
        stderr=slave,
        env=environment,
    )
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
                frames = transcript.decode("utf-8", errors="replace").count("q/Esc — выход")
                if stage == 0 and frames >= 1:
                    # Меню уже напечатано; даём read перейти к чтению клавиши.
                    time.sleep(0.03)
                    if mode == "resize":
                        keys = b" "
                    else:
                        keys = b"\x1b[F\nq" if mode == "pages" else b"\x1b[B \x1b[A aq"
                    os.write(master, keys)
                    stage = 1
                elif mode == "resize" and stage == 1 and frames >= 2:
                    time.sleep(0.03)
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 14, 60, 0, 0))
                    resize_start = len(transcript)
                    os.write(master, b"\x1b[Baq")
                    stage = 2
            if process.poll() is not None and not readable:
                break

        assert process.poll() is not None, "Меню не завершилось за 15 секунд"
        assert process.returncode == 0, f"Код завершения: {process.returncode}"
        assert termios.tcgetattr(slave) == original_settings, "Настройки терминала изменились"
        output = transcript.decode("utf-8", errors="replace")
        assert re.search(r"\x1b\[\d+A", output), "Не проверена перерисовка меню"
        sections = [(output, columns)]
        if resize_start is not None:
            after_resize = transcript[resize_start:].decode("utf-8", errors="replace")
            assert after_resize.startswith("Приватные SSH-ключи"), "При изменении размера затронут старый блок"
            sections = [(transcript[:resize_start].decode("utf-8"), columns), (after_resize, 60)]
        for section, section_columns in sections:
            in_menu = False
            for line in re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", section).splitlines():
                if line == "Приватные SSH-ключи":
                    in_menu = True
                if in_menu:
                    assert len(line) <= section_columns, "Строка меню выходит за ширину терминала"
                if line.startswith("a — добавить отмеченные"):
                    in_menu = False
        if mode == "resize":
            assert resize_start is not None, "Не проверено изменение размера окна"
            visible = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", output)
        else:
            visible = Terminal(rows, columns).render(output)
        assert "BEFORE_MENU_SENTINEL" in visible, "Вывод перед меню был затёрт"
        assert "AFTER_MENU_SENTINEL" in visible, "Оболочка не продолжила работу после source"
        assert "Приватные SSH-ключи" in visible, "Меню исчезло после выхода"
        assert "уже загружен" in visible, "Состояние загруженного ключа не обновилось"
        assert "Ключи в SSH-агенте (ssh-add -l):" in visible, "Итоговый список не сохранён"
        if mode == "pages":
            assert ".03_hidden" in visible, "Последняя страница не показана"
        else:
            assert "[x]" in visible, "Отметка ключа не отображается"
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

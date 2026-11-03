"""Файл tools/bootstrap.py: загрузка анализаторов для Linux x86_64 с проверкой SHA256.

Устанавливает официальные бинарные выпуски в tools/.bin без изменения системы.
Версии и контрольные суммы заданы в tools/versions.json; нужен только Python 3.
"""

import argparse
import hashlib
import io
import json
import os
import pathlib
import platform
import tarfile
import tempfile
import urllib.request


def install_tool(name, specification, destination):
    """Проверяет архив инструмента и атомарно сохраняет только его исполняемый файл."""
    request = urllib.request.Request(
        specification["url"], headers={"User-Agent": "ssh-agent-development-tools"}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read()
    if hashlib.sha256(payload).hexdigest() != specification["sha256"]:
        raise ValueError(f"Не совпадает SHA256 инструмента {name}")
    if specification["url"].endswith((".tar.gz", ".tar.xz")):
        with tarfile.open(fileobj=io.BytesIO(payload)) as archive:
            members = [
                member
                for member in archive.getmembers()
                if member.isfile() and pathlib.PurePosixPath(member.name).name == name
            ]
            if len(members) != 1:
                raise ValueError(f"Не найден единственный исполняемый файл {name}")
            with archive.extractfile(members[0]) as executable:
                payload = executable.read()
    with tempfile.NamedTemporaryFile(dir=destination, delete=False) as temporary:
        temporary_path = pathlib.Path(temporary.name)
        try:
            temporary.write(payload)
            temporary.flush()
            temporary_path.chmod(0o755)
            os.replace(temporary_path, destination / name)
        finally:
            temporary_path.unlink(missing_ok=True)
    print(f"Установлен {name} {specification['version']}", flush=True)


def main():
    """Устанавливает зафиксированный набор; неподдерживаемую платформу отклоняет."""
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise SystemExit(
            "Для этой платформы установите инструменты из docs/development.md вручную."
        )
    directory = pathlib.Path(__file__).resolve().parent
    specifications = json.loads((directory / "versions.json").read_text())
    destination = directory / ".bin"
    destination.mkdir(exist_ok=True)
    parser = argparse.ArgumentParser(
        description="Подготовка анализаторов разработки для Linux x86_64."
    )
    parser.add_argument("tools", nargs="*", help="Имена инструментов; без аргументов — весь набор.")
    names = parser.parse_args().tools or list(specifications["tools"])
    for name in names:
        if name not in specifications["tools"]:
            parser.error(f"Неизвестный инструмент: {name}")
        install_tool(name, specifications["tools"][name], destination)


if __name__ == "__main__":
    main()

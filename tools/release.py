"""Файл tools/release.py: проверка версии и подготовка архива, SHA256 и заметок релиза.

VERSION содержит версию без v. CHANGELOG.md содержит раздел версии и дату выпуска.
Архив создаётся из точного тега Git; локальные бинарники и неотслеживаемые файлы
в него не попадают. --check проверяет метаданные до создания тега.
"""

import argparse
import datetime
import hashlib
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def release_notes(tag):
    """Проверяет стабильную SemVer-версию, VERSION и запись changelog; возвращает текст."""
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Для стабильного релиза нужен тег vX.Y.Z без ведущих нулей.")
    version = tag[1:]
    if (ROOT / "VERSION").read_text().strip() != version:
        raise ValueError("Тег не соответствует VERSION.")
    changelog = (ROOT / "CHANGELOG.md").read_text()
    pattern = (
        rf"^## \[{re.escape(version)}\] - (\d{{4}}-\d{{2}}-\d{{2}})\n(.*?)(?=^## |^\[[^\]]+\]:|\Z)"
    )
    match = re.search(pattern, changelog, re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError("В CHANGELOG.md нет раздела версии с датой YYYY-MM-DD.")
    datetime.date.fromisoformat(match[1])
    notes = match[2].strip()
    if not notes or not re.search(r"^- \S", notes, re.MULTILINE):
        raise ValueError("Раздел версии должен описывать изменения.")
    return notes + "\n"


def build_release(tag, notes, output):
    """Создаёт архив точного тега текущего коммита, контрольную сумму и notes.md."""
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    tagged = subprocess.check_output(
        ["git", "rev-parse", f"{tag}^{{commit}}"], cwd=ROOT, text=True
    ).strip()
    if head != tagged:
        raise ValueError("Для сборки переключитесь на коммит выпускаемого тега.")
    subprocess.run(["git", "diff-index", "--quiet", "HEAD", "--"], cwd=ROOT, check=True)
    version = tag[1:]
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"ssh-agent-{version}.tar.gz"
    subprocess.run(
        [
            "git",
            "archive",
            "--format=tar.gz",
            f"--prefix=ssh-agent-{version}/",
            f"--output={archive}",
            tag,
        ],
        cwd=ROOT,
        check=True,
    )
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{digest}  {archive.name}\n")
    (output / "notes.md").write_text(notes)
    print(f"Подготовлен {archive}")


def main():
    """Разбирает параметры и выполняет проверку метаданных либо подготовку файлов релиза."""
    parser = argparse.ArgumentParser(description="Подготовка стабильного релиза SSH-меню.")
    parser.add_argument("tag", help="Тег стабильной версии, например v1.0.0.")
    parser.add_argument(
        "--check", action="store_true", help="Проверить метаданные без тега и архива."
    )
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "dist")
    arguments = parser.parse_args()
    try:
        notes = release_notes(arguments.tag)
        if arguments.check:
            print(f"Метаданные {arguments.tag} согласованы.")
        else:
            build_release(arguments.tag, notes, arguments.output.resolve())
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Ошибка подготовки релиза: {error}\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Format manually maintained App.strings files."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ENTRY_PATTERN = re.compile(r'^\s*"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')


def unescape(text: str) -> str:
    return (
        text.replace(r"\\", "\\")
        .replace(r'\"', '"')
        .replace(r"\n", "\n")
        .replace(r"\t", "\t")
    )


def escape(text: str) -> str:
    return (
        text.replace("\\", r"\\")
        .replace('"', r'\"')
        .replace("\n", r"\n")
        .replace("\t", r"\t")
    )


def parse_strings_file(path: Path) -> dict[str, str]:
    entries: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("/*") or line.startswith("//"):
            continue

        match = ENTRY_PATTERN.match(raw_line)
        if not match:
            raise ValueError(f"Unsupported .strings syntax in {path}:{line_number}: {raw_line}")

        key, value = match.groups()
        key = unescape(key)
        if key in entries:
            raise ValueError(f"Duplicate key in {path}:{line_number}: {key}")
        entries[key] = unescape(value)

    return entries


def section_key(key: str) -> str:
    components = key.split(".")
    if components[0] == "app" and len(components) >= 3:
        return ".".join(components[:2])
    return components[0]


def formatted_content(entries: dict[str, str]) -> str:
    lines: list[str] = []
    previous_section: str | None = None

    for key in sorted(entries, key=lambda entry_key: (section_key(entry_key), entry_key)):
        section = section_key(key)
        if previous_section is not None and section != previous_section:
            lines.append("")
        previous_section = section
        lines.append(f'"{escape(key)}" = "{escape(entries[key])}";')

    return "\n".join(lines) + "\n"


def app_strings_paths(project_root: Path) -> list[Path]:
    localization_root = project_root / "ShichiZip" / "Resources" / "Localization"
    return sorted(localization_root.glob("*.lproj/App.strings"))


def format_file(path: Path, check: bool) -> bool:
    entries = parse_strings_file(path)
    formatted = formatted_content(entries)
    original = path.read_text(encoding="utf-8")
    if original == formatted:
        return False

    if check:
        print(f"Would format {path}")
        return True

    path.write_text(formatted, encoding="utf-8")
    print(f"Formatted {path}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, help="App.strings files to format")
    parser.add_argument("--check", action="store_true", help="report files that would change without writing them")
    args = parser.parse_args()

    project_root = Path(__file__).resolve().parents[2]
    paths = args.paths or app_strings_paths(project_root)
    changed = False

    try:
        for path in paths:
            changed = format_file(path, args.check) or changed
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1

    return 1 if args.check and changed else 0


if __name__ == "__main__":
    raise SystemExit(main())
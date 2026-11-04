#!/usr/bin/env python3
"""Render and validate Arti configuration for install-arti-service.bash.

This is a standalone helper, not an embedded heredoc. It has two commands:

  arti-config.py validate PATH
  arti-config.py render SOURCE TARGET CONFIG DATA STATE CACHE

See the LICENSE file at the top of the project tree for copyright and
license details.
"""

from __future__ import annotations

import sys
from pathlib import Path


def fail(message: str) -> None:
    print(f"arti-config: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate(path: str) -> None:
    try:
        import tomllib
    except ImportError:
        fail("Python 3.11+ with tomllib is required")
    try:
        with open(path, "rb") as source:
            tomllib.load(source)
    except (OSError, ValueError) as error:
        fail(f"invalid TOML in {path}: {error}")


def quote(value: str, command: bool) -> str:
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        fail("control characters are not supported in XDG paths")
    value = value.replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"')
    if command:
        value = value.replace("$", "$$")
    return '"' + value + '"'


def render(
    source: str, target: str, config: str, data: str, state: str, cache: str
) -> None:
    paths = {
        "%h/.config/arti": config,
        "%h/.local/share/arti": data,
        "%h/.local/state/arti": state,
        "%h/.cache/arti": cache,
    }
    result: list[str] = []
    for line in Path(source).read_text(encoding="utf-8").splitlines():
        command = line.startswith("Exec")
        for placeholder, path in paths.items():
            if "UNIX-LISTEN:" + placeholder in line:
                if "," in path:
                    fail("socat socket paths cannot contain commas")
                old = "UNIX-LISTEN:" + placeholder + "/arti-socks.sock,fork,mode=0600"
                new = quote(
                    "UNIX-LISTEN:" + path + "/arti-socks.sock,fork,mode=0600",
                    True,
                )
                line = line.replace(old, new)
            for suffix in ("/arti.toml", "/arti-socks.sock", ""):
                line = line.replace(
                    placeholder + suffix,
                    quote(path + suffix, command),
                )
        result.append(line)
    Path(target).write_text("\n".join(result) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "validate":
        validate(argv[1])
        return 0
    if len(argv) == 7 and argv[0] == "render":
        render(argv[1], argv[2], argv[3], argv[4], argv[5], argv[6])
        return 0
    fail(
        "usage: arti-config.py validate PATH | render SOURCE TARGET CONFIG DATA STATE CACHE"
    )


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))

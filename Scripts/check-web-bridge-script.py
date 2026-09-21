#!/usr/bin/env python3
"""Assemble the injected web-bridge script from its Swift sources and syntax-check it.

The bridge is authored as several Swift raw-string constants that are concatenated
at runtime (`sourcePartOne + sourcePartTwo + sourcePartThree`), and one of them is
itself composed with the stylesheet constant. A stray backtick, an unbalanced
brace, or a fragment that opens a template literal the next fragment is expected to
close therefore never shows up in any single Swift file — which is exactly the class
of mistake this check exists to catch.

Usage:
    python3 Scripts/check-web-bridge-script.py [--node <path-to-node>] [--print]

Exits 1 when the assembled script is not valid JavaScript.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BRIDGE_DIR = Path("DSH Studio/Sources/App/Web/SettingsBridge")
ASSEMBLY = ("sourcePartOne", "sourcePartTwo", "sourcePartThree")
TOKEN = re.compile(r'#"""\n(.*?)\n\s*"""#|([A-Za-z_][A-Za-z0-9_]*)', re.S)


def read_expressions() -> dict[str, str]:
    """Collect the full initializer expression of every bridge constant.

    The scan is line based because an expression can span several raw-string
    chunks joined by `+` (and may itself contain blank lines), so a simple
    "up to the next blank line" pattern would truncate it.
    """
    expressions: dict[str, str] = {}
    start = re.compile(r"^\s*static let (\w+) = (.*)$")
    for path in sorted(BRIDGE_DIR.glob("AppSettingsWebBridge*.swift")):
        lines = path.read_text(encoding="utf-8").split("\n")
        for index, line in enumerate(lines):
            match = start.match(line)
            if not match:
                continue
            pieces = [match.group(2)]
            cursor = index
            while True:
                joined = "\n".join(pieces)
                open_chunks = joined.count('#"""')
                close_chunks = joined.count('"""#')
                if open_chunks == close_chunks and not pieces[-1].rstrip().endswith("+"):
                    break
                cursor += 1
                if cursor >= len(lines):
                    break
                pieces.append(lines[cursor])
            expressions[match.group(1)] = "\n".join(pieces)
    return expressions


def resolve(name: str, expressions: dict[str, str], seen: tuple[str, ...] = ()) -> str:
    """Expand one constant into its literal text, following constant references."""
    pieces: list[str] = []
    for chunk, identifier in TOKEN.findall(expressions[name]):
        if chunk:
            pieces.append(chunk)
        elif identifier in expressions and identifier != name and identifier not in seen:
            pieces.append(resolve(identifier, expressions, seen + (name,)))
    return "\n".join(pieces)


def assemble(expressions: dict[str, str]) -> str:
    """Build the JavaScript exactly as `AppSettingsWebBridge.source` does."""
    return "\n".join(resolve(name, expressions) for name in ASSEMBLY)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", default=None, help="node binary to use")
    parser.add_argument("--print", action="store_true", help="print the assembled script")
    args = parser.parse_args()

    expressions = read_expressions()
    missing = [name for name in ASSEMBLY if name not in expressions]
    if missing:
        print(f"missing bridge constant(s): {', '.join(missing)}", file=sys.stderr)
        return 1

    script = assemble(expressions)
    if args.print:
        print(script)
    if len(script.strip()) < 100:
        print("assembled bridge script is unexpectedly small", file=sys.stderr)
        return 1

    node = args.node or shutil.which("node")
    if not node:
        print("node not found; skipping the JavaScript syntax check", file=sys.stderr)
        return 0

    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as handle:
        handle.write(script)
        path = handle.name

    completed = subprocess.run([node, "--check", path], capture_output=True, text=True)
    if completed.returncode != 0:
        print("assembled bridge script is not valid JavaScript:", file=sys.stderr)
        print(completed.stderr.strip(), file=sys.stderr)
        return 1

    print(f"assembled bridge script is valid JavaScript ({len(script.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

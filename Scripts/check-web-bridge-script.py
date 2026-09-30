#!/usr/bin/env python3
"""Assemble every injected web-bridge script from its Swift sources and syntax-check it.

Each bridge is authored as one or more Swift raw-string constants that are
concatenated at runtime, so a stray backtick, an unbalanced brace, or a fragment
that opens a template literal the next fragment is expected to close never shows
up in any single Swift file — which is exactly the class of mistake this check
exists to catch. Node is the parser; the file only has to find the constants and
put them back together the way the app does.

Usage:
    python3 Scripts/check-web-bridge-script.py [--node <path-to-node>] [--print]

Exits 1 when any assembled script is not valid JavaScript.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Bridge:
    """One injected script: the Swift files holding it and its concatenation order."""

    name: str
    directory: Path
    pattern: str
    assembly: tuple[str, ...]


BRIDGES = (
    # The layout bridge is the concatenation this check was originally written
    # for: two halves that only form valid JavaScript once joined.
    Bridge(
        name="HarnessLayoutWebBridge",
        directory=Path("DSH Studio/Sources/Harness/Web/Layout"),
        pattern="HarnessLayoutWebBridge+*.swift",
        assembly=("sourcePartOne", "sourcePartTwo"),
    ),
    Bridge(
        name="PluginMarketRestartWebBridge",
        directory=Path("DSH Studio/Sources/App/Web/WebView"),
        pattern="PluginMarketRestartWebBridge.swift",
        assembly=("source",),
    ),
    Bridge(
        name="SessionLogExportWebBridge",
        directory=Path("DSH Studio/Sources/Harness/Diagnostics/SessionLogExport"),
        pattern="SessionLogExportWebBridge.swift",
        assembly=("interceptDialogScript",),
    ),
)

TOKEN = re.compile(r'(?:#?)"""\n(.*?)\n\s*"""(?:#?)|([A-Za-z_][A-Za-z0-9_]*)', re.S)
START = re.compile(r"^\s*(?:public\s+|internal\s+|private\s+|package\s+)*static let (\w+) = (.*)$")


def read_expressions(bridge: Bridge) -> dict[str, str]:
    """Collect the full initializer expression of every constant a bridge declares.

    The scan is line based because an expression can span several raw-string
    chunks joined by `+` (and may itself contain blank lines), so a simple
    "up to the next blank line" pattern would truncate it.
    """
    expressions: dict[str, str] = {}
    for path in sorted(bridge.directory.glob(bridge.pattern)):
        lines = path.read_text(encoding="utf-8").split("\n")
        for index, line in enumerate(lines):
            match = START.match(line)
            if not match:
                continue
            pieces = [match.group(2)]
            cursor = index
            while True:
                joined = "\n".join(pieces)
                # A complete raw string contributes exactly two `"""` delimiters,
                # whether it is written `"""` or `#"""`.
                if joined.count('"""') % 2 == 0 and not pieces[-1].rstrip().endswith("+"):
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


def assemble(bridge: Bridge, expressions: dict[str, str]) -> str:
    """Build the JavaScript exactly as the Swift constant concatenation does."""
    return "\n".join(resolve(name, expressions) for name in bridge.assembly)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--node", default=None, help="node binary to use")
    parser.add_argument("--print", action="store_true", help="print each assembled script")
    args = parser.parse_args()

    status = 0
    for bridge in BRIDGES:
        expressions = read_expressions(bridge)
        missing = [name for name in bridge.assembly if name not in expressions]
        if missing:
            print(f"{bridge.name}: missing bridge constant(s): {', '.join(missing)}", file=sys.stderr)
            status = 1
            continue

        script = assemble(bridge, expressions)
        if args.print:
            print(f"--- {bridge.name} ---")
            print(script)
        if len(script.strip()) < 100:
            print(f"{bridge.name}: assembled script is unexpectedly small", file=sys.stderr)
            status = 1
            continue

        node = args.node or shutil.which("node")
        if not node:
            print("node not found; skipping the JavaScript syntax check", file=sys.stderr)
            return status

        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as handle:
            handle.write(script)
            path = handle.name

        completed = subprocess.run([node, "--check", path], capture_output=True, text=True)
        Path(path).unlink(missing_ok=True)
        if completed.returncode != 0:
            print(f"{bridge.name}: assembled script is not valid JavaScript:", file=sys.stderr)
            print(completed.stderr.strip(), file=sys.stderr)
            status = 1
            continue
        print(f"{bridge.name}: assembled script is valid JavaScript ({len(script.splitlines())} lines)")
    return status


if __name__ == "__main__":
    sys.exit(main())

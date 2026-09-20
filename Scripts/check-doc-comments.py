#!/usr/bin/env python3
"""Fail when an in-scope Swift declaration has no doc comment.

Scope is "internal and above": `private` and `fileprivate` declarations are
skipped, as are function-local variables, `switch` cases, and anything inside a
multi-line string literal.

Usage:
    python3 scripts/check-doc-comments.py [root ...]

Exits 1 and prints every offender as `<path>:<line>  <kind> <name>` when any
in-scope declaration lacks a `///` doc comment.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

DEFAULT_ROOTS = ("DSH Studio/Sources",)

TYPE_KEYWORDS = ("class", "struct", "enum", "actor", "protocol", "extension")
FUNC_KEYWORDS = ("func", "init", "subscript", "deinit")
MEMBER_KEYWORDS = ("var", "let", "case", "typealias")

MODIFIERS = (
    "public|internal|open|private|fileprivate|final|static|class|mutating|"
    "nonisolated|override|required|convenience|weak|unowned|lazy|dynamic|"
    "indirect|prefix|postfix|infix|isolated|borrowing|consuming|package"
)
ATTRIBUTE = r"@\w+(?:\([^)]*\))?"
DECL_RE = re.compile(
    r"^(?P<indent>[ \t]*)"
    rf"(?P<mods>(?:(?:{MODIFIERS}|{ATTRIBUTE})\s+)*)"
    rf"(?P<kw>{'|'.join(TYPE_KEYWORDS + FUNC_KEYWORDS + MEMBER_KEYWORDS)})\b"
)
# A standalone attribute line (`@MainActor`, `@discardableResult`) belongs to the
# declaration below it, so documentation may sit above the attribute rather than
# directly above the declaration.
STANDALONE_ATTRIBUTE_RE = re.compile(rf"^{ATTRIBUTE}$")


def strip_strings(line: str) -> str:
    """Drop string literals so braces inside them cannot shift the depth count."""
    out, index, in_string = [], 0, False
    while index < len(line):
        char = line[index]
        if char == '"':
            backslashes, cursor = 0, index - 1
            while cursor >= 0 and line[cursor] == "\\":
                backslashes += 1
                cursor -= 1
            if backslashes % 2 == 0:
                in_string = not in_string
        if not in_string:
            out.append(char)
        index += 1
    return "".join(out)


def raw_string_terminator(line: str, pending: str | None) -> tuple[str | None, bool]:
    """Track multi-line literals; return the terminator awaited and whether this line opened one."""
    stripped = line.strip()
    if pending is not None:
        return (None, False) if stripped.endswith(pending) else (pending, False)
    for hashes in ("###", "##", "#", ""):
        opener = hashes + '"' * 3
        if opener in stripped and stripped.count('"' * 3) % 2 == 1:
            return '"' * 3 + hashes, True
    return None, False


def context_kind(keyword: str) -> str:
    """Brace context introduced by a declaration."""
    if keyword == "enum":
        return "enum_body"
    if keyword in TYPE_KEYWORDS:
        return "type"
    if keyword in FUNC_KEYWORDS:
        return "func"
    if keyword in ("var", "let"):
        return "property"
    return "other"


def is_documented(lines: list[str], index: int) -> bool:
    """Whether the declaration at `index` carries a doc comment above it."""
    cursor = index - 1
    while cursor >= 0 and STANDALONE_ATTRIBUTE_RE.match(lines[cursor].strip()):
        cursor -= 1
    return cursor >= 0 and lines[cursor].lstrip().startswith("///")


def scan(path: Path) -> list[tuple[int, str, str]]:
    lines = path.read_text(encoding="utf-8").split("\n")
    context: list[dict] = []
    depth = 0
    pending: dict | None = None
    in_block_comment = False
    string_terminator: str | None = None
    missing: list[tuple[int, str, str]] = []

    for number, raw in enumerate(lines, start=1):
        string_terminator, opened_here = raw_string_terminator(raw, string_terminator)
        if string_terminator is not None and not opened_here:
            depth += raw.count("{") - raw.count("}")
            continue

        line = strip_strings(raw)
        stripped = line.strip()
        if in_block_comment:
            if "*/" in stripped:
                in_block_comment = False
            depth += line.count("{") - line.count("}")
            continue
        if stripped.startswith("/*") and "*/" not in stripped:
            in_block_comment = True
            continue
        if stripped.startswith("//"):
            depth += line.count("{") - line.count("}")
            continue

        match = DECL_RE.match(line)
        if match:
            keyword = match.group("kw")
            modifiers = match.group("mods")
            innermost = context[-1]["kind"] if context else None
            inside_callable = any(c["kind"] in ("func", "property", "other") for c in context)
            is_private = "private" in modifiers or any(c["private"] for c in context)

            in_scope = not is_private
            if keyword == "case":
                # Only a case whose innermost brace is the enum itself declares a member.
                in_scope = in_scope and innermost == "enum_body"
            if keyword in ("var", "let", "typealias"):
                in_scope = in_scope and not inside_callable

            if in_scope and not is_documented(lines, number - 1):
                name = line[match.end():].strip().rstrip("{").strip() or keyword
                missing.append((number, keyword, name[:60]))

            if "{" in line:
                context.append(
                    {
                        "kind": context_kind(keyword),
                        "depth": depth + 1,
                        "private": "private" in modifiers,
                    }
                )
                pending = None
            else:
                pending = {"keyword": keyword, "depth": depth + 1, "private": "private" in modifiers}
        elif pending is not None and "{" in line:
            context.append(
                {
                    "kind": context_kind(pending["keyword"]),
                    "depth": depth + 1,
                    "private": pending["private"],
                }
            )
            pending = None

        depth += line.count("{") - line.count("}")
        while context and depth < context[-1]["depth"]:
            context.pop()

    return missing


def main(argv: list[str]) -> int:
    roots = [Path(item) for item in argv[1:]] or [Path(item) for item in DEFAULT_ROOTS]
    files = sorted(path for root in roots if root.exists() for path in root.rglob("*.swift"))
    offenders = 0
    for path in files:
        for number, keyword, name in scan(path):
            print(f"{path}:{number}  {keyword} {name}")
            offenders += 1
    if offenders:
        print(f"\n{offenders} in-scope declaration(s) without a doc comment.")
        return 1
    print(f"{len(files)} file(s) checked: every in-scope declaration is documented.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

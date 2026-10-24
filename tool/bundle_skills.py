#!/usr/bin/env python3
"""Bundle claude-red's SKILL.md files into PocketStrike's assets at build time.

Reads a cloned claude-red repo (its Skills/<category>/<name>/SKILL.md tree) and
writes, under assets/skills/:
  <name>.md            each skill's full text
  index.json           [{name, category, description}] for fast load + matching

Run: python3 tool/bundle_skills.py <path-to-claude-red> [--out assets/skills]
Hand-parses the YAML frontmatter (name, description) so CI needs no pyyaml.
"""
import argparse
import json
import re
import sys
from pathlib import Path

FM = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)


def field(front: str, key: str) -> str:
    m = re.search(rf"^{key}:\s*(.*)$", front, re.MULTILINE)
    if not m:
        return ""
    v = m.group(1).strip()
    if len(v) >= 2 and v[0] in "\"'" and v[-1] == v[0]:
        v = v[1:-1]
    return v.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("repo")
    ap.add_argument("--out", default="assets/skills")
    args = ap.parse_args()

    skills_dir = Path(args.repo) / "Skills"
    if not skills_dir.is_dir():
        print(f"no Skills/ in {args.repo}", file=sys.stderr)
        return 1
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.md"):
        old.unlink()

    index = []
    for md in sorted(skills_dir.glob("*/*/SKILL.md")):
        text = md.read_text(encoding="utf-8")
        m = FM.match(text)
        front = m.group(1) if m else ""
        name = field(front, "name") or md.parent.name
        category = md.relative_to(skills_dir).parts[0]
        desc = field(front, "description")
        if not re.fullmatch(r"[a-z0-9-]+", name):
            print(f"skip odd name {name!r} in {md}", file=sys.stderr)
            continue
        (out / f"{name}.md").write_text(text, encoding="utf-8")
        index.append({"name": name, "category": category, "description": desc})

    (out / "index.json").write_text(
        json.dumps(index, ensure_ascii=False, indent=0), encoding="utf-8")
    print(f"bundled {len(index)} skills into {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

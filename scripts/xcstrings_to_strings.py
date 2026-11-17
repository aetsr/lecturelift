#!/usr/bin/env python3
"""Fallback for toolchains whose SwiftPM does not compile String Catalogs (e.g. Xcode 16):
writes <out>/<lang>.lproj/Localizable.strings from an .xcstrings file (no plural variations used)."""
import json, os, sys

src, out = sys.argv[1], sys.argv[2]
cat = json.load(open(src, encoding="utf-8"))
esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
langs = {}
for key, entry in cat["strings"].items():
    for lang, loc in entry.get("localizations", {}).items():
        langs.setdefault(lang, []).append(f'"{esc(key)}" = "{esc(loc["stringUnit"]["value"])}";')
for lang, lines in langs.items():
    d = os.path.join(out, f"{lang}.lproj"); os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8") as f:
        f.write("\n".join(sorted(lines)) + "\n")
print(f"generated string tables for {', '.join(sorted(langs))}")

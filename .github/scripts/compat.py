#!/usr/bin/env python3
"""Weekly compatibility check against the latest Hyprland release and Noctalia main.

Reads scroll-indicator/widget.luau to find what it depends on, then searches the upstream
sources (cloned by the workflow into $HYPR_SRC and $NOCT_SRC) for each item:

  - Noctalia: every noctalia.* / barWidget.* function the widget calls is still registered,
    and the plugin's plugin_api is inside Noctalia's supported range.
  - Hyprland: the hyprctl JSON fields and socket2 event names the widget reads still exist.

Writes compat-report.md and compat-report.json, and exits 1 if anything is missing.
"""
import json
import os
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "scroll-indicator"
HYPR = Path(os.environ["HYPR_SRC"])
NOCT = Path(os.environ["NOCT_SRC"])
HYPR_VERSION = os.environ.get("HYPR_VERSION", "?")
NOCT_VERSION = os.environ.get("NOCT_VERSION", "?")

# hyprctl -j fields the widget reads (keep in sync with widget.luau)
HYPR_JSON_FIELDS = ["tiledLayout", "address", "at", "floating", "mapped", "hidden", "workspace", "name", "title", "class"]


def grep(root: Path, needle: str, exts=(".cpp", ".hpp", ".h", ".cc")) -> str | None:
    """Return the first file (relative) under root/src containing needle, or None."""
    for p in (root / "src").rglob("*"):
        if p.suffix in exts and p.is_file():
            try:
                if needle in p.read_text(errors="ignore"):
                    return str(p.relative_to(root))
            except OSError:
                pass
    return None


widget = (PLUGIN / "widget.luau").read_text()
manifest = tomllib.loads((PLUGIN / "plugin.toml").read_text())

# --- what the widget uses -------------------------------------------------------------
api_calls = set()
for ns, a, b in re.findall(r"\b(noctalia|barWidget)\.([A-Za-z_]+)(?:\.([A-Za-z_]+))?", widget):
    api_calls.add(b or a)  # noctalia.json.decode -> "decode"
relevant = re.search(r"local RELEVANT = \{(.*?)\n\}", widget, re.S)
events = sorted(re.findall(r"(\w+)\s*=\s*true", relevant.group(1))) if relevant else []

checks = []  # (area, item, ok, where)

# --- Noctalia -------------------------------------------------------------------------
for name in sorted(api_calls):
    where = grep(NOCT, f'"{name}"')
    checks.append(("Noctalia API", f"{name}()", where is not None, where or "not found"))

api_h = (NOCT / "src/scripting/plugin_api.h").read_text() if (NOCT / "src/scripting/plugin_api.h").exists() else ""
m_old = re.search(r"kOldestSupportedPluginApiVersion\s*=\s*(\d+)", api_h)
oldest = int(m_old.group(1)) if m_old else None
want = manifest["plugin_api"]
api_ok = oldest is not None and want >= oldest
checks.append(("Noctalia API", f"plugin_api {want} supported (oldest supported: {oldest})", api_ok,
               "src/scripting/plugin_api.h" if m_old else "could not read plugin_api.h"))

# --- Hyprland -------------------------------------------------------------------------
# hyprctl's JSON is built from string templates like  "tiledLayout": "{}"  in one file.
# Find that file, then require every field to appear there as  "field":
hyprctl_file = grep(HYPR, '"tiledLayout":')
hyprctl_text = (HYPR / hyprctl_file).read_text(errors="ignore") if hyprctl_file else ""
for field in HYPR_JSON_FIELDS:
    ok = f'"{field}":' in hyprctl_text
    checks.append(("Hyprland JSON", field, ok, hyprctl_file if ok else "not found in hyprctl JSON output"))
for ev in events:
    where = grep(HYPR, f'"{ev}"')
    checks.append(("Hyprland event", ev, where is not None, where or "not found"))

# --- report ---------------------------------------------------------------------------
failed = [c for c in checks if not c[2]]
status = "PASS" if not failed else "FAIL"

lines = [
    f"# Compatibility report: {status}",
    "",
    f"- Plugin: `{manifest['id']}` v{manifest['version']} (plugin_api {want})",
    f"- Hyprland: `{HYPR_VERSION}` (latest release)",
    f"- Noctalia: `{NOCT_VERSION}` (main)",
    "",
    "| Area | Item | Result | Found in |",
    "|---|---|---|---|",
]
for area, item, ok, where in checks:
    lines.append(f"| {area} | `{item}` | {'✅' if ok else '❌'} | {where} |")
if failed:
    lines += ["", "Something the widget depends on was not found upstream. It may have been renamed or "
              "removed. Comment `@claude` on the issue to have it investigated."]
lines += ["", "_Static check only: it searches upstream source code. It cannot run the widget, so "
          "behavior changes that keep the same names won't show up here._"]

report = "\n".join(lines) + "\n"
(ROOT / "compat-report.md").write_text(report)
(ROOT / "compat-report.json").write_text(json.dumps({
    "status": status,
    "plugin": {"id": manifest["id"], "version": manifest["version"], "plugin_api": want},
    "hyprland": HYPR_VERSION,
    "noctalia": NOCT_VERSION,
    "checks": [{"area": a, "item": i, "ok": o, "where": w} for a, i, o, w in checks],
}, indent=2) + "\n")
print(report)
sys.exit(1 if failed else 0)

#!/usr/bin/env python3
"""Route Omarchy's Style → Theme / Background (and their keybindings, which
open those menu entries) to the card picker, through Omarchy's official user
menu extension. Only a marked block is added or removed; the rest of the file
stays byte-for-byte as it was. If the picker is not loaded, the actions fall
back to Omarchy's own pickers.

usage: menu-override.py enable|disable|status [--file PATH]
"""
import json
import os
import sys
import tempfile

BEGIN = "  // BEGIN Card picker (managed)"
END = "  // END Card picker (managed)"
THEME_FALLBACK = "omarchy-shell shell summon omarchy.image-picker '{\"source\":\"themes\"}'"
BACKGROUND_FALLBACK = 'background=$(omarchy-theme-bg-switcher); [[ -n $background ]] && omarchy-theme-bg-set "$background"'
ENTRIES = {
    "style.theme": "omarchy-shell card-picker open theme >/dev/null 2>&1 || " + THEME_FALLBACK,
    "style.background": "omarchy-shell card-picker open wallpaper >/dev/null 2>&1 || { " + BACKGROUND_FALLBACK + "; }",
}


# Omarchy fills fields a user entry leaves out with empty defaults, so an
# override must carry the original label, icon and aliases (the keybindings
# open these entries by alias: "theme", "background").
FALLBACK_FIELDS = {
    "style.theme": {"icon": "\U000f0e0c", "label": "Theme", "aliases": ["theme", "themes"]},
    "style.background": {"icon": "\uf03e", "label": "Background", "aliases": ["background", "wallpaper"]},
}


def default_entry(key):
    root = os.environ.get("OMARCHY_PATH") or os.path.expanduser("~/.local/share/omarchy")
    path = os.path.join(root, "default", "omarchy", "omarchy-menu.jsonc")
    prefix = json.dumps(key) + ":"
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line.startswith(prefix):
                return json.loads(line[len(prefix):].strip().rstrip(","))
    except (OSError, ValueError):
        pass
    return dict(FALLBACK_FIELDS[key])


def block():
    lines = [BEGIN]
    for key, action in ENTRIES.items():
        entry = default_entry(key)
        entry["action"] = action
        lines.append("  " + json.dumps(key) + ": " + json.dumps(entry, ensure_ascii=False) + ",")
    lines.append(END)
    return "\n".join(lines) + "\n"


def strip(text):
    if BEGIN not in text:
        return text
    start = text.index(BEGIN)
    end = text.index(END, start) + len(END)
    if text[end:end + 1] == "\n":
        end += 1
    return text[:start] + text[end:]


def write(path, text):
    st = os.stat(path) if os.path.exists(path) else None
    fd, tmp = tempfile.mkstemp(prefix=".menu-", dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        f.write(text)
    if st:
        os.chmod(tmp, st.st_mode & 0o777)
    os.replace(tmp, path)


def main():
    args = sys.argv[1:]
    path = os.path.expanduser("~/.config/omarchy/extensions/omarchy-menu.jsonc")
    if "--file" in args:
        path = args[args.index("--file") + 1]
    cmd = args[0] if args else "status"
    text = open(path).read() if os.path.exists(path) else "{\n}\n"
    if cmd == "status":
        print("enabled" if BEGIN in text else "disabled")
        return 0
    base = strip(text)
    if cmd == "disable":
        if base != text:
            write(path, base)
        print("disabled")
        return 0
    if cmd != "enable":
        print(__doc__.strip(), file=sys.stderr)
        return 2
    brace = base.index("{")
    nl = base.index("\n", brace) + 1
    new = base[:nl] + block() + base[nl:]
    if new != text:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        write(path, new)
    print("enabled")
    return 0


if __name__ == "__main__":
    sys.exit(main())

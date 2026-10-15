#!/usr/bin/env python3
"""Publish a complete Card Picker generation without restarting the shell.

Only the plugin manifest changes in place. Older code and manifests are retained
for rollback; shell.json, menu routing and user preferences are never modified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

PAYLOAD = ('Picker.qml', 'Deck.qml', 'Logic.js', 'LICENSE', 'bin/menu-override.py')


def atomic(path, text):
    fd, name = tempfile.mkstemp(prefix='.'+path.name+'.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
        os.chmod(name, 0o644)
        os.replace(name, path)
    finally:
        if Path(name).exists():
            Path(name).unlink()


def install(source, target):
    manifest = json.loads((source/'manifest.json').read_text())
    assert manifest['id'] == target.name == 'nerdibeard.card-picker'
    assert manifest['entryPoints'] == {'panel': 'Picker.qml'}
    digest = hashlib.sha256((source/'manifest.json').read_bytes())
    for name in PAYLOAD:
        digest.update(name.encode()+b'\0'+(source/name).read_bytes())
    generation = digest.hexdigest()[:16]
    folder = target/'generations'/generation
    folder.parent.mkdir(parents=True, exist_ok=True)
    if not folder.exists():
        # Stage outside the watched plugins tree, on the same filesystem.
        with tempfile.TemporaryDirectory(prefix='.card-picker-', dir=target.parent.parent) as temp:
            stage = Path(temp)/generation
            for name in PAYLOAD:
                dest = stage/name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source/name, dest)
            os.replace(stage, folder)
    else:
        for name in PAYLOAD:
            assert (folder/name).read_bytes() == (source/name).read_bytes(), 'Modified immutable generation'
    old = target/'manifest.json'
    if old.exists():
        backup = target.parent.parent/'card-picker-manifest-backups'
        backup.mkdir(exist_ok=True)
        previous = backup/(hashlib.sha256(old.read_bytes()).hexdigest()[:16]+'.json')
        if not previous.exists():
            shutil.copy2(old, previous)
    manifest['entryPoints']['panel'] = f'generations/{generation}/Picker.qml'
    atomic(old, json.dumps(manifest, indent=2)+'\n')
    print(generation)


if __name__ == '__main__':
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('source', type=Path)
    ap.add_argument('target', type=Path)
    a=ap.parse_args()
    install(a.source.resolve(), a.target.resolve())

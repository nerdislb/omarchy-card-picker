#!/usr/bin/env python3
"""Production QML, real Qt key events and subprocess fixtures; no desktop mutations."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import json
from PIL import Image
import render

out=Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix='picker-native-') as td:
    fixture=Path(td)
    media=fixture/'current/theme/backgrounds'
    media.mkdir(parents=True)
    (fixture/'current/theme.name').write_text('fixture\n')
    (fixture/'bin').mkdir()
    for name,colour in [('1-chrom.png','red'),('2-other.png','blue')]:
        Image.new('RGB',(320,180),colour).save(media/name)
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-f','lavfi','-i','testsrc2=size=160x90:rate=12:duration=2','-c:v','mpeg4',str(media/'3-video-a.mp4')],check=True)
    (media/'4-video-b.mp4').write_bytes((media/'3-video-a.mp4').read_bytes())
    Image.new('RGB',(160,90),'green').save(media/'5-animation.gif',save_all=True,append_images=[Image.new('RGB',(160,90),'yellow')],duration=200,loop=0)
    files=sorted(media.iterdir())
    for i,p in enumerate(files): os.utime(p,(1000+i,1000+i))
    (fixture/'current/background').symlink_to(files[0])
    rows=''.join(str(p)+'\t'+str(files[0] if p.suffix=='.mp4' else p)+'\n' for p in files)
    (fixture/'rows').write_text(rows)
    (fixture/'setter-mode').write_text('ok')
    for name in ['omarchy-theme-switcher','omarchy-menu-images']:
        p=fixture/'bin'/name
        p.write_text('#!/bin/sh\ncat '+repr(str(fixture/'rows'))+'\n')
        p.chmod(0o755)
    for name in ['omarchy-theme-set','omarchy-theme-bg-set']:
        p=fixture/'bin'/name
        p.write_text('#!/bin/sh\nmode=$(cat '+repr(str(fixture/'setter-mode'))+')\ncase "$mode" in fail) exit 7;; slow) sleep 1.5;; esac\nprintf "%s\\n" "$1" >> '+repr(str(fixture/'applied'))+'\n')
        p.chmod(0o755)
    os.environ['PATH']=str(fixture/'bin')+os.pathsep+os.environ['PATH']
    render.SHELL=(Path(__file__).with_name('native.qml').read_text().replace('__FIXTURE__',str(fixture)))
    render.run(out,(1280,900),False,[])
    log=(out/'render.log').read_text()
    assert 'NATIVE_WORKFLOW_PASSED' in log and 'FAIL!' not in log,log
    state=json.loads((out/'state.json').read_text())
    assert state['live'] is True and len(state['favourites']['wallpaper'])==1,state
    assert (fixture/'applied').read_text().splitlines()==[str(files[0]),str(files[0])]
    print('PASS native workflow + on-disk preferences + exactly two successful setter calls')

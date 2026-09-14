#!/usr/bin/env python3
"""Read-only ZIP header counts for the original long-name save format."""
import argparse
from collections import Counter
import hashlib
import json
import zipfile
from pathlib import Path

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('save',type=Path);ap.add_argument('output',type=Path);args=ap.parse_args()
    files=sorted(p for p in args.save.iterdir() if p.is_file())
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    rows=[]
    for p in files:
        if p.suffix not in ('.teag','.teaz'):continue
        with zipfile.ZipFile(p) as archive:
            assert archive.testzip() is None
            infos=archive.infolist()
            assert all(i.filename=='main' or '-0x' in i.filename for i in infos), 'expected original long object names'
            classes=Counter(i.filename.split('-0x')[0] for i in infos)
            players=[i for i in infos if i.filename.startswith('mod.class.Player-')]
            rows.append(dict(name=p.name,bytes=p.stat().st_size,entries=len(infos),players=len(players),
                player_raw_bytes=sum(i.file_size for i in players),objects=classes['mod.class.Object'],
                engine_objects=classes['engine.Object'],quests=classes['engine.Quest']))
    result=dict(source_sha256=hashes,source_total_bytes=sum(p.stat().st_size for p in files),archives=rows,
        total_players=sum(r['players'] for r in rows),
        zones_with_player=sum(r['players']>0 for r in rows if r['name'].endswith('.teaz')),
        total_zones=sum(r['name'].endswith('.teaz') for r in rows),
        total_player_raw_bytes=sum(r['player_raw_bytes'] for r in rows))
    assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    result['source_unchanged']=True
    args.output.write_text(json.dumps(result,indent=2)+'\n')

if __name__=='__main__':main()

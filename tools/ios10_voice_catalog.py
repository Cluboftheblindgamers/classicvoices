#!/usr/bin/env python3
"""Generate metadata for iOS 10's standard enhanced Vocalizer downloads.

Usage: ios10_voice_catalog.py <Apple Vocalizer catalog plist> <output JSON>
The compatibility-6/format-7 postings are Apple's iOS10.0 assets; older
format-7 postings belong to iOS9 and must not be relabelled as iOS10.
No voice data is copied into the output.
"""
import json
from pathlib import Path
import plistlib
import sys

def entries(data):
    result=[]
    for asset in plistlib.loads(data)['Assets']:
        if str(asset.get('_CompatibilityVersion')) != '6' or str(asset.get('FormatVersion')) != '7':
            continue
        if asset.get('Type') != 'vocalizer' or asset.get('Footprint') != 'premium':
            continue
        languages=asset.get('Languages',[])
        if len(languages)!=1 or '/ios10.0/' not in asset['__BaseURL']:
            raise ValueError('Unexpected iOS10 asset metadata')
        if asset.get('_MeasurementAlgorithm') != 'SHA-1':
            raise ValueError('Unsupported asset measurement algorithm')
        digest=asset['_Measurement']
        if not isinstance(digest,bytes) or len(digest)!=20:
            raise ValueError('Missing SHA-1 measurement')
        result.append(dict(build='ios10',language=languages[0],name=asset['Name'].title(),
            url=asset['__BaseURL']+asset['__RelativePath'],size=asset['_DownloadSize'],
            unarchivedSize=asset['_UnarchivedSize'],sha1=digest.hex()))
    if not result or len({v['language'] for v in result})!=len(result):
        raise ValueError('Missing or duplicate iOS10 languages')
    return sorted(result,key=lambda v:v['language'])

if __name__=='__main__':
    rows=entries(Path(sys.argv[1]).read_bytes())
    Path(sys.argv[2]).write_text(json.dumps(rows,indent=1)+'\n')
    print(f'{len(rows)} iOS10 enhanced voices')

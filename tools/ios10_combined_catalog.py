#!/usr/bin/env python3
"""Convert Apple's CombinedVocalizerVoices plist into downloadable package metadata.
Format 6 is the combined voice format referenced by the original iOS10 firmware;
its Apple URLs retain the ios9 release directory. No voice data is included.
"""
import json,plistlib,sys
from pathlib import Path

def entries(data):
    rows=[]
    for a in plistlib.loads(data)['Assets']:
        if str(a.get('FormatVersion'))!='6' or a.get('CombinedVoiceProject') is not True:continue
        languages=a.get('Languages',[]);name=a['Name'];digest=a['_Measurement']
        if len(languages)!=1 or '/' in name or name in ['.','..'] or not name:
            raise ValueError('Invalid combined voice identity')
        if a.get('_MeasurementAlgorithm')!='SHA-1' or not isinstance(digest,bytes) or len(digest)!=20:
            raise ValueError('Missing asset checksum')
        rows.append(dict(product='combined-'+name,era='ios10',name=name,locale=languages[0],
            voiceID=a['VoiceId'],version='',gender=a.get('Gender',''),url=a['__BaseURL']+a['__RelativePath'],
            size=a['_DownloadSize'],archive='combined-zip',sha1=digest.hex()))
    if not rows or len({r['product'] for r in rows})!=len(rows):raise ValueError('Missing/duplicate combined voices')
    return sorted(rows,key=lambda r:(r['locale'],r['name']))

if __name__=='__main__':
    voices=entries(Path(sys.argv[1]).read_bytes())
    Path(sys.argv[2]).write_text(json.dumps(dict(voices=voices),indent=1)+'\n')
    print(f'{len(voices)} combined voice packages')

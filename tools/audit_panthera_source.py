#!/usr/bin/env python3
"""Compare the local maintained Panthera Apple source against the port.

The report contains hashes, setting names and intentional differences only;
it never copies voice data, preferences or absolute source paths.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    report={'source':'Maintained Panthera Apple snapshot','files':{},'settings':{}}
    for name in ['SpeechText.swift','MacRoman.swift','Pronunciations.swift','SSMLRequest.swift','PantheraSettings.swift','Generation.swift']:
        old=(args.source/'apple/Shared'/name).read_text()
        new=(ROOT/'ios/Shared/Panthera'/name).read_text()
        normalized=new.removeprefix('// Adapted from Panthera Speech. See third_party/panthera/LICENSE.\n')
        item={'originalSHA256':hashlib.sha256(old.encode()).hexdigest(),
              'portedSHA256':hashlib.sha256(new.encode()).hexdigest(),
              'exactExceptAttribution':old==normalized}
        if old!=normalized:
            item['difference']=list(difflib.unified_diff(old.splitlines(),normalized.splitlines(),fromfile='Panthera/'+name,tofile='Classic/'+name,lineterm=''))
        report['files'][name]=item
    original=(args.source/'apple/Shared/PantheraSettings.swift').read_text()
    fields=set(re.findall(r'public var (\w+):[^\n=]+=',original))|set(re.findall(r'public var (\w+) =',original))
    port=(ROOT/'ios/Shared/Panthera/PantheraSettings.swift').read_text()
    ui=(ROOT/'ios/App/MacinTalkSettingsView.swift').read_text()
    for field in sorted(fields):
        report['settings'][field]={'stored':re.search(r'public var '+field+r'\b',port) is not None,
                                   'control':re.search(r'\b'+field+r'\b',ui) is not None}
    missing=[k for k,v in report['settings'].items() if not all(v.values())]
    report['missingSettings']=missing
    text=json.dumps(report,indent=2)+'\n'
    if args.output:args.output.write_text(text)
    else:print(text,end='')
    if missing:raise SystemExit('Missing settings: '+', '.join(missing))
    print('PASS all '+str(len(fields))+' original stored settings have controls; exact/difference hashes recorded', file=sys.stderr)

if __name__=='__main__':main()

#!/usr/bin/env python3
"""Stage a local Mac trial with distinct app, component, group and voice IDs.

Optional local MacinTalk data stays inside build/ and is never a release asset.
No installed app, selected system voice, or existing data container is changed.
"""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT=Path(__file__).resolve().parent.parent
PREFIX='org.pantheraspeech.classicvoices.port'
GROUP='group.org.pantheraspeech.ClassicVoices.Port'

def run(args):subprocess.run([str(x) for x in args],check=True)
def read(path):return plistlib.loads(path.read_bytes())
def write(path,value):path.write_bytes(plistlib.dumps(value,sort_keys=False))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--mt106',type=Path)
    parser.add_argument('--native',type=Path)
    args=parser.parse_args()
    output=ROOT/'build/private-mac/Classic Voices Panthera Test.app'
    if output.exists():raise SystemExit('The private test copy already exists; preserve or remove that copy explicitly before rebuilding.')
    output.parent.mkdir(parents=True,exist_ok=True)
    shutil.copytree(args.app,output,symlinks=True)
    extension=output/'Contents/PlugIns/Synth.appex'
    common={'ClassicVoicesTestCopy':'YES','ClassicVoicesAppGroup':GROUP,
            'ClassicVoicesVoicePrefix':PREFIX,'ClassicVoicesSubtype':'cvpt',
            'ClassicVoicesManufacturer':'PnTh'}
    for bundle,suffix in [(output,'.mac'),(extension,'.synthMac')]:
        path=bundle/'Contents/Info.plist';info=read(path)
        info.update(common);info['CFBundleIdentifier']=PREFIX+suffix
        info['CFBundleDisplayName']='Classic Voices Panthera Test'
        info['CFBundleName']='Classic Voices Panthera Test'
        if suffix=='.synthMac':
            component=info['NSExtension']['NSExtensionAttributes']['AudioComponents'][0]
            component.update(subtype='cvpt',manufacturer='PnTh',name='Classic Voices Panthera Test')
        write(path,info)
    resources=extension/'Contents/Resources'
    if args.mt106:
        target=resources/'Voices/mt106';target.mkdir(parents=True,exist_ok=True)
        for relative in ['MacinTalk','SpeechDictionary','lib']:
            source=args.mt106/relative;dest=target/relative
            if source.is_dir():shutil.copytree(source,dest,copy_function=shutil.copyfile)
            else:shutil.copyfile(source,dest)
        for voice in ['Alex','Fred']:
            source=args.mt106/'Voices'/(voice+'.SpeechVoice')
            if source.exists():
                shutil.copytree(source,target/'Voices'/source.name,copy_function=shutil.copyfile)
    if args.native:
        directory=resources/'Native';directory.mkdir(exist_ok=True)
        shutil.copyfile(args.native,directory/'cvmtnative_mt106.so')
        run(['codesign','-f','-s','-',directory/'cvmtnative_mt106.so'])
    for bundle,template,label in [(extension,'Synth/SynthMacPublic.entitlements','synth'),
                                  (output,'App/ClassicVoicesMacPublic.entitlements','app')]:
        entitlements=read(ROOT/'ios'/template)
        entitlements['com.apple.security.application-groups']=[GROUP]
        path=output.parent/(label+'-entitlements.plist');write(path,entitlements)
        run(['codesign','-f','-s','-','--entitlements',path,bundle])
    run(['codesign','--verify','--deep','--strict',output])
    print(output)

if __name__=='__main__':main()

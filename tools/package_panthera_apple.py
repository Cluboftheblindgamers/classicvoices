#!/usr/bin/env python3
"""Build an isolated local Mac app or sideloadable iOS IPA for the Panthera port.

All output is private local build material, not a GitHub release. Supply your
own voice data; nothing is downloaded. iOS requires generated engine code in
build/ (tools/build_engines.sh and tools/build_mt_native.sh). Mac uses the
public host with optional locally compiled Native libraries. App and voice
identities are separate from stable Panthera and upstream Classic Voices.
"""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
import yaml

ROOT = Path(__file__).resolve().parent.parent
PREFIX = 'org.pantheraspeech.classicvoices.port'
GROUP = 'group.org.pantheraspeech.ClassicVoices.Port'

def run(args, **kwargs):
    subprocess.run([str(x) for x in args], check=True, cwd=ROOT, **kwargs)

def configure_bundle(bundle, platform, extension, build_number=None):
    if build_number is None:
        build_number = max(9, int(subprocess.check_output(['git', 'rev-list', '--count', 'HEAD'], cwd=ROOT, text=True)))
    if not 1 <= build_number <= 65535:
        raise ValueError('Build number must be between 1 and 65535')
    path = bundle / ('Contents/Info.plist' if platform == 'mac' else 'Info.plist')
    info = plistlib.loads(path.read_bytes())
    suffix = ('.synthMac' if platform == 'mac' else '.ios.synth') if extension else ('.mac' if platform == 'mac' else '.ios')
    info.update(CFBundleIdentifier=PREFIX + suffix, CFBundleDisplayName='Classic Voices Panthera',
                CFBundleName='Classic Voices Panthera', CFBundleVersion=str(build_number),
                ClassicVoicesTestCopy='YES', ClassicVoicesAppGroup=GROUP,
                ClassicVoicesVoicePrefix=PREFIX, ClassicVoicesSubtype='cvpt', ClassicVoicesManufacturer='PnTh')
    for key in ['DTDeveloperName', 'DTDeveloperTeamID', 'DeveloperTeamIdentifier']:
        info.pop(key, None)
    if extension:
        component = info['NSExtension']['NSExtensionAttributes']['AudioComponents'][0]
        component.update(subtype='cvpt', manufacturer='PnTh', name='Classic Voices Panthera',
                         version=0x10000 + int(info['CFBundleVersion']))
    path.write_bytes(plistlib.dumps(info, sort_keys=False))

def copy_data(source, destination, macintalk_only=False):
    if not source:
        return
    for directory in source.iterdir():
        if macintalk_only and directory.name not in {'mt104','mt105','mt106','mt107'}:
            continue
        if directory.name.startswith('.') or not directory.is_dir():
            continue
        if directory.name not in {'ios3','ios4','ios5','ios6','ios70','ios7','ios10','mac107','mac108','mac109','siri7','mt104','mt105','mt106','mt107'}:
            continue
        shutil.copytree(directory, destination / directory.name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('_CodeSignature', '*.DS_Store'), copy_function=shutil.copyfile)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['mac','ios'], required=True)
    parser.add_argument('--voices', type=Path, help='Classic-format Voices folder, copied into the private app')
    parser.add_argument('--macintalk', type=Path, help='mt104..mt107 folders, copied over the voice data')
    parser.add_argument('--native', type=Path, help='Mac-only folder of locally built native .so libraries')
    parser.add_argument('--settings', type=Path, help='optional Classic settings JSON or export envelope; logging forced off')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--build-number',type=int,help='defaults to source commit count; advances the AU cache version')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = output / 'Classic Voices Panthera.app'
    if app.exists():
        raise SystemExit('Output app already exists. Preserve it or choose a new output directory.')
    spec = yaml.safe_load((ROOT/'ios/project.yml').read_text())
    spec['name'] = 'ClassicVoicesPortBuild'
    spec['settings']['base']['DEVELOPMENT_TEAM'] = ''
    spec['targetTemplates']['Synth']['postBuildScripts'] = []
    def fix(value, key=''):
        if isinstance(value, dict): return {k:fix(v,k) for k,v in value.items()}
        if isinstance(value, list): return [str((ROOT/'ios'/x).resolve()) if key=='sources' and isinstance(x,str) else fix(x,key) for x in value]
        if isinstance(value, str):
            if key in ('path','INFOPLIST_FILE','SWIFT_OBJC_BRIDGING_HEADER') and not value.startswith('$'): return str((ROOT/'ios'/value).resolve())
            if key in ('HEADER_SEARCH_PATHS','LIBRARY_SEARCH_PATHS'): return value.replace('$(SRCROOT)/../',str(ROOT)+'/').replace('$(SRCROOT)',str(ROOT/'ios'))
        return value
    if args.platform == 'mac':
        # Mac postbuild scripts package compiler sources relative to ios/.
        # Keep the canonical project location instead of moving SRCROOT.
        directory = ROOT/'ios'
        config = directory/'project.yml'
        derived = ROOT/'build/mac-derived'
        project = directory/'ClassicVoices.xcodeproj'
    else:
        directory = ROOT/'build/port-ios-project'
        directory.mkdir(parents=True,exist_ok=True)
        config = directory/'project.json';config.write_text(json.dumps(fix(spec),indent=2))
        derived = ROOT/'build/port-ios-derived'
        project = directory/'ClassicVoicesPortBuild.xcodeproj'
    scheme = 'ClassicVoicesMacPublic' if args.platform=='mac' else 'ClassicVoices'
    if not args.skip_build:
        run(['xcodegen','generate','-q','--spec',config,'--project',directory])
        run(['xcodebuild','-project',project,'-scheme',scheme,
             '-configuration','Release','-destination','generic/platform='+('macOS' if args.platform=='mac' else 'iOS'),
             '-derivedDataPath',derived,'-jobs','6','ARCHS=arm64','ONLY_ACTIVE_ARCH=YES',
             'CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO','CODE_SIGN_IDENTITY=','build'])
    products = derived/'Build/Products'/('Release' if args.platform=='mac' else 'Release-iphoneos')
    original = products/('Classic Voices.app' if args.platform=='mac' else 'ClassicVoices.app')
    shutil.copytree(original, app, symlinks=True)
    extension = app / ('Contents/PlugIns/Synth.appex' if args.platform=='mac' else 'PlugIns/Synth.appex')
    resources = extension / ('Contents/Resources' if args.platform=='mac' else '')
    voices = resources/'Voices';voices.mkdir(parents=True,exist_ok=True)
    copy_data(args.voices, voices)
    copy_data(args.macintalk, voices, macintalk_only=True)
    if args.native and args.platform=='mac':
        shutil.copytree(args.native, resources/'Native', dirs_exist_ok=True,copy_function=shutil.copyfile)
    if args.settings:
        settings = json.loads(args.settings.read_text())
        if settings.get('format')=='classicvoices-panthera-settings': settings=settings['settings']
        settings['logSpokenText']=False
        (voices/'settings.json').write_text(json.dumps(settings))
    for bundle in [extension,app]: configure_bundle(bundle,args.platform,bundle==extension,args.build_number)
    # Release build products still contain linker debug/local symbol paths.
    # Strip those from our executables before signing; runtime metadata and
    # exported AU/native ABI symbols remain available.
    for bundle in [extension, app]:
        info_path=bundle/('Contents/Info.plist' if args.platform=='mac' else 'Info.plist')
        executable=plistlib.loads(info_path.read_bytes())['CFBundleExecutable']
        binary=bundle/('Contents/MacOS' if args.platform=='mac' else '')/executable
        run(['xcrun','strip','-S','-x',binary])
    # Do not carry a provisioning profile or an old signature into a local IPA.
    for path in list(app.rglob('embedded.mobileprovision')) + list(app.rglob('embedded.provisionprofile')):
        path.unlink()
    with tempfile.TemporaryDirectory(prefix='cv-port-sign-') as temporary:
        temporary=Path(temporary)
        for path in resources.rglob('*'):
            if not path.is_file():continue
            with path.open('rb') as f: magic=f.read(4)
            if magic not in [bytes.fromhex(x) for x in ['cafebabe','feedface','cefaedfe','feedfacf','cffaedfe']]:continue
            # Stage bare Mach-O files so codesign cannot mistake a surrounding
            # SpeechDictionary folder for an application bundle.
            copied=temporary/'binary';shutil.copyfile(path,copied)
            run(['codesign','-f','-s','-',copied],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            shutil.copyfile(copied,path)
        for bundle,label in [(extension,'extension'),(app,'app')]:
            template = 'Synth/SynthMacPublic.entitlements' if args.platform=='mac' else 'Synth/Synth.entitlements'
            if label=='app':template='App/ClassicVoicesMacPublic.entitlements' if args.platform=='mac' else 'App/ClassicVoices.entitlements'
            entitlements=plistlib.loads((ROOT/'ios'/template).read_bytes())
            entitlements['com.apple.security.application-groups']=[GROUP]
            ent=temporary/(label+'.plist');ent.write_bytes(plistlib.dumps(entitlements))
            run(['codesign','-f','-s','-','--entitlements',ent,bundle])
    run(['codesign','--verify','--deep','--strict',app])
    if args.platform=='ios':
        archive=output/'Classic Voices Panthera.ipa'
        with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for path in app.rglob('*'):
                if path.is_file():z.write(path,'Payload/ClassicVoices.app/'+path.relative_to(app).as_posix())
        print('Private sideloadable IPA:',archive)
    else:
        run(['ditto','-c','-k','--keepParent',app,output/'Classic Voices Panthera Mac.zip'])
    print('Private local app:',app)

if __name__=='__main__':main()

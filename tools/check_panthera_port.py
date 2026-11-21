#!/usr/bin/env python3
"""Run port regression checks after building ClassicVoicesMacPublic.

--voice-root enables real-engine tests against local mt104..mt107 folders.
--native-objects can link a locally generated mt106 object directory for speed.
All generated binaries, logs and native code remain under ignored build/.
"""
import argparse
from pathlib import Path
import os
import subprocess

ROOT=Path(__file__).resolve().parent.parent
def run(command,**kwargs):subprocess.run([str(x) for x in command],check=True,cwd=ROOT,**kwargs)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--voice-root',type=Path)
    parser.add_argument('--native-objects',type=Path)
    args=parser.parse_args()
    build=ROOT/'build/tests';build.mkdir(parents=True,exist_ok=True)
    archive=ROOT/'build/mac-derived/Build/Products/Release/libEngineCode.a'
    if not archive.exists():raise SystemExit('Build ClassicVoicesMacPublic first (see ios/project.yml).')
    common=['swiftc','-O','-module-cache-path',ROOT/'build/swift-cache','-I',ROOT/'core',
            '-import-objc-header',ROOT/'ios/Shared/Bridging.h']
    sources=sorted((ROOT/'ios/Shared').glob('*.swift'))+sorted((ROOT/'ios/Shared/Panthera').glob('*.swift'))
    native=sorted(args.native_objects.resolve().glob('*.o')) if args.native_objects else []
    # Clang can leave unfinished temporary .o files next to compilation output.
    native=[p for p in native if p.name.endswith('.c.o') or p.stem.startswith('mt106_')]
    module=common+['-DCV_PUBLIC','-DCV_PORT_TEST','-enable-testing','-emit-library','-emit-module',
        '-module-name','ClassicPortTest','-emit-module-path',build/'ClassicPortTest.swiftmodule']+sources+[archive]+native+[
        '-lc++','-lz','-lbz2','-lsqlite3','-framework','AudioToolbox','-framework','Accelerate',
        '-framework','NaturalLanguage','-Xlinker','-install_name','-Xlinker','@rpath/libClassicPortTest.dylib',
        '-o',build/'libClassicPortTest.dylib']
    with (build/'module-build.log').open('w') as log:run(module,stdout=log,stderr=subprocess.STDOUT)
    checks=['panthera_maintenance','panthera_port','panthera_queue','panthera_scopes']
    if args.voice_root:checks.append('panthera_provider')
    for name in checks:
        command=common+['-parse-as-library','-I',build,ROOT/'tests'/(name+'.swift'),'-L',build,
            '-lClassicPortTest','-Xlinker','-rpath','-Xlinker','@executable_path','-o',build/name]
        with (build/(name+'-build.log')).open('w') as log:run(command,stdout=log,stderr=subprocess.STDOUT)
        env=dict(os.environ)
        if args.voice_root:env['CV_PORT_ROOT']=str(args.voice_root.resolve())
        with (build/(name+'.log')).open('w') as log:run([build/name],env=env,stdout=log,stderr=subprocess.STDOUT,timeout=90)
        print((build/(name+'.log')).read_text().strip(),flush=True)
    run(['clang','-O2','-Icore','-Icore/mt','tests/mt_port_render.c','-Lbuild/tests',
         '-lClassicPortTest','-Wl,-rpath,@executable_path','-o',build/'mt_port_render'])

if __name__=='__main__':main()

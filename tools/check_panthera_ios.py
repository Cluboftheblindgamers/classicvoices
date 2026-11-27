#!/usr/bin/env python3
"""Unsigned iOS compile check without firmware packaging or static Vocalizer code.

Requires Xcode, xcodegen, PyYAML and locally generated MacinTalk sources if
native MacinTalk compilation is desired. This does not produce a usable IPA.
Build output and the temporary Xcode project stay under ignored build/.
"""
from pathlib import Path
import argparse
import json
import subprocess
import yaml

ROOT = Path(__file__).resolve().parent.parent

def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    ios = ROOT / 'ios'
    spec = yaml.safe_load((ios / 'project.yml').read_text())
    spec['name'] = 'ClassicVoicesCompileCheck'
    spec['settings']['base']['GCC_PREPROCESSOR_DEFINITIONS'] = ['$(inherited)', 'VX_NO_STATIC_NATIVE=1']
    spec['targetTemplates']['Synth']['postBuildScripts'] = []

    def fix(value, key=''):
        if isinstance(value, dict):
            return {k: fix(v, k) for k, v in value.items()}
        if isinstance(value, list):
            return [str((ios / x).resolve()) if key == 'sources' and isinstance(x, str)
                    else fix(x, key) for x in value]
        if isinstance(value, str):
            if key in ('path', 'INFOPLIST_FILE', 'SWIFT_OBJC_BRIDGING_HEADER') and not value.startswith('$'):
                return str((ios / value).resolve())
            if key in ('HEADER_SEARCH_PATHS', 'LIBRARY_SEARCH_PATHS'):
                # Quoted: Xcode splits a literal search path at spaces ("Classic Voices - x" gave -I-).
                path = value.replace('$(SRCROOT)/../', str(ROOT) + '/').replace('$(SRCROOT)', str(ios))
                return '"' + path + '"' if ' ' in path and not path.startswith('"') else path
        return value

    directory = ROOT / 'build/ios-check'
    directory.mkdir(parents=True, exist_ok=True)
    project = directory / 'project.json'
    project.write_text(json.dumps(fix(spec), indent=2))
    subprocess.run(['xcodegen', 'generate', '-q', '--spec', str(project), '--project', str(directory)], check=True, cwd=ROOT)
    subprocess.run(['xcodebuild', '-project', str(directory / 'ClassicVoicesCompileCheck.xcodeproj'),
                    '-scheme', 'ClassicVoices', '-configuration', 'Release',
                    '-destination', 'generic/platform=iOS', '-derivedDataPath', str(ROOT / 'build/ios-derived'),
                    '-jobs', '6', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'CODE_SIGNING_ALLOWED=NO',
                    'CODE_SIGNING_REQUIRED=NO', 'CODE_SIGN_IDENTITY=', 'build'], check=True, cwd=ROOT)

if __name__ == '__main__':
    main()

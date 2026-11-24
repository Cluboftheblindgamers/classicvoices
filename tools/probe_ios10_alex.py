#!/usr/bin/env python3
"""Build/run an isolated, opt-in iOS ARM32 MacinTalk experiment on macOS.

Requires the existing Mac EngineCode archive and a locally extracted engine.
Does not install an app, register voices, download data, or change settings.
"""
import argparse
from pathlib import Path
import subprocess
import os

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('engine', type=Path)
    parser.add_argument('--voice', type=Path, help='Alex AssetData directory (optional voice-selection test)')
    parser.add_argument('--speak', action='store_true', help='Attempt a first sentence and save a private WAV under build/')
    parser.add_argument('--check-unicode', action='store_true', help='Run UTF-16, ICU-index and emoji adapter checks first')
    parser.add_argument('--check-mixed-root', type=Path, help='Existing mt106 root for engine-switching regression')
    parser.add_argument('--native-objects',type=Path,help='Optional existing x86 native objects for mixed checks')
    parser.add_argument('--pitch', type=float, help='Experimental pbas value, 20 through 80')
    parser.add_argument('--text', help='ASCII test sentence')
    parser.add_argument('--cancel-after-frames', type=int)
    parser.add_argument('--resume-after-cancel', action='store_true', help='Speak again on the same channel after cancelling')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--archive', type=Path, default=ROOT / 'build/mac-derived/Build/Products/Release/libEngineCode.a')
    args = parser.parse_args()
    if args.speak and not args.voice:
        parser.error('--speak requires --voice')
    if not args.speak and any(value is not None for value in [args.pitch, args.text, args.cancel_after_frames, args.output]):
        parser.error('speech test options require --speak')
    if args.pitch is not None and not 20 <= args.pitch <= 80:
        parser.error('--pitch must be from 20 through 80')
    if args.cancel_after_frames is not None and args.cancel_after_frames <= 0:
        parser.error('--cancel-after-frames must be positive')
    if args.resume_after_cancel and not args.cancel_after_frames:
        parser.error('--resume-after-cancel requires --cancel-after-frames')
    if args.check_mixed_root and not args.voice:
        parser.error('--check-mixed-root requires --voice')
    out = ROOT / 'build/ios10-alex-port'
    out.mkdir(parents=True, exist_ok=True)
    common = ['clang', '-O1', '-g', '-fblocks', '-DCV_MT_ARM32_EXPERIMENT=1',
              '-I' + str(ROOT / 'core/mt')]
    objects = []
    for relative in ['core/mt/mt.c', 'core/mt/mt_libc.c', 'core/mt/mtengine.c', 'core/thumb.c', 'core/mt/arm32/arm32_host.c', 'core/mt/arm32/arm_audio.c',
                     'core/mt/arm32/arm_dispatch.c', 'core/mt/arm32/arm_sqlite.c',
                     'core/mt/arm32/arm_threads.c', 'core/mt/arm32/arm_unicode.c', 'tests/ios10_alex/probe.c']:
        obj = out / (Path(relative).stem + '.o')
        subprocess.run(common + ['-c', str(ROOT / relative), '-o', str(obj)], check=True)
        objects.append(str(obj))
    binary = out / 'probe'
    subprocess.run(['clang', *objects, str(args.archive), '-lc++', '-lz', '-lbz2', '-lsqlite3', '-licucore',
                    '-framework', 'AudioToolbox', '-framework', 'Accelerate', '-framework', 'CoreFoundation',
                    '-o', str(binary)], check=True)
    if args.check_unicode:
        test_object=out/'unicode_checks.o'
        subprocess.run(common+['-c',str(ROOT/'tests/ios10_alex/unicode_checks.c'),'-o',str(test_object)],check=True)
        test_binary=out/'unicode-checks'
        subprocess.run(['clang', *[p for p in objects if Path(p).name!='probe.o'],str(test_object),str(args.archive),
                        '-lc++','-lz','-lbz2','-lsqlite3','-licucore','-framework','AudioToolbox',
                        '-framework','Accelerate','-framework','CoreFoundation','-o',str(test_binary)],check=True)
        subprocess.run([str(test_binary)],check=True,timeout=15)
    if args.check_mixed_root:
        renamed=out/'probe-renamed.o'; test_object=out/'mixed_checks.o'
        subprocess.run(common+['-Dmain=alex_probe_main','-c',str(ROOT/'tests/ios10_alex/probe.c'),'-o',str(renamed)],check=True)
        subprocess.run(common+['-c',str(ROOT/'tests/ios10_alex/mixed_checks.c'),'-o',str(test_object)],check=True)
        native=sorted(args.native_objects.resolve().glob('mt106_*.o')) if args.native_objects else []
        test_binary=out/'mixed-checks'
        subprocess.run(['clang',*[p for p in objects if Path(p).name!='probe.o'],str(renamed),str(test_object),
                        *map(str,native),str(args.archive),'-lc++','-lz','-lbz2','-lsqlite3','-licucore',
                        '-framework','AudioToolbox','-framework','Accelerate','-framework','CoreFoundation',
                        '-o',str(test_binary)],check=True)
        subprocess.run([str(test_binary),str(args.check_mixed_root.resolve()),str(args.engine.resolve()),str(args.voice.resolve()),str(out/'mixed-switch.wav')],check=True,timeout=60)
    command = [str(binary), str(args.engine.resolve())]
    if args.voice:
        command.append(str(args.voice.resolve()))
    if args.speak:
        output = args.output.resolve() if args.output else out / 'alex.wav'
        output.unlink(missing_ok=True)  # failed probes must not leave a stale success sample
        command.append(str(output))
    env = dict(os.environ)
    if args.pitch is not None:
        env['ALEX_PROBE_PITCH'] = str(args.pitch)
    if args.text is not None:
        env['ALEX_PROBE_TEXT'] = args.text
    if args.cancel_after_frames is not None:
        env['ALEX_PROBE_CANCEL_FRAMES'] = str(args.cancel_after_frames)
    if args.resume_after_cancel:
        resume = output.with_name(output.stem + '-resumed.wav')
        resume.unlink(missing_ok=True)
        env['ALEX_PROBE_RESUME_OUTPUT'] = str(resume)
    result = subprocess.run(command, timeout=35, env=env)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()

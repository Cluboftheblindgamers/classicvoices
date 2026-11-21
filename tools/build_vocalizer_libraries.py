#!/usr/bin/env python3
"""Compile locally translated Vocalizer sources into Mac native libraries.

No Apple data is downloaded or published. Generate build/gen* from your own
engines with tools/recomp.py or tools/build_engines.sh first.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parent.parent
DIRECTORIES={'ios3':'gen3','ios4':'gen4','ios5':'gen5','ios6':'gen','ios70':'gen70','ios7':'gen7','ios10':'gen10'}

def run(args):subprocess.run([str(x) for x in args],check=True,cwd=ROOT)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'build/port-native-mac')
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('generations',nargs='*',default=list(DIRECTORIES))
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    for generation in args.generations:
        if generation not in DIRECTORIES:raise SystemExit('Unknown engine '+generation)
        sources=sorted((ROOT/'build'/DIRECTORIES[generation]).glob('*.c'))
        if not sources:raise SystemExit('No generated source for '+generation)
        objects=ROOT/'build/port-vocalizer-mac-objects'/generation;objects.mkdir(parents=True,exist_ok=True)
        sources.append(ROOT/'nvda/src/native_glue.c')
        def compile(source):
            obj=objects/(source.name+'.o')
            run(['clang','-O2','-g0','-fno-slp-vectorize','-mllvm','-enable-newgvn',
                 '-std=gnu11','-ffp-contract=off','-w','-fPIC','-I',ROOT/'core',
                 '-DCV_BUILD='+generation,'-c',source,'-o',obj])
            return obj
        # Start large translation units first, avoiding one slow tail file.
        sources.sort(key=lambda p:p.stat().st_size,reverse=True)
        with ThreadPoolExecutor(max_workers=max(1,args.jobs)) as pool: compiled=list(pool.map(compile,sources))
        library=args.output/('cvnative_'+generation+'.so')
        run(['clang','-dynamiclib','-Wl,-install_name,@rpath/'+library.name,'-o',library]+compiled)
        run(['xcrun','strip','-S','-x',library])
        run(['codesign','-f','-s','-',library])
        print('Built',library,flush=True)

if __name__=='__main__':main()

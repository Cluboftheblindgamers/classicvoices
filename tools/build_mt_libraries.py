#!/usr/bin/env python3
"""Compile local MacinTalk translations into Mac native libraries (never publish).

Run tools/build_mt_native.sh first. Uses Apple's local clang; no downloads.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parent.parent

def run(command):subprocess.run([str(x) for x in command],check=True,cwd=ROOT)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'build/port-native-mac')
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('generations',nargs='*',default=['mt104','mt105','mt106','mt107'])
    args=parser.parse_args();args.output.mkdir(parents=True,exist_ok=True)
    for gen in args.generations:
        if gen not in ['mt104','mt105','mt106','mt107']:raise SystemExit('Unknown generation')
        sources=sorted((ROOT/'build'/('mtgen'+gen[2:])).glob('*.c'))
        if not sources:raise SystemExit('Generate native source for '+gen+' first')
        objects=ROOT/'build/port-native-objects'/gen;objects.mkdir(parents=True,exist_ok=True)
        sources+=[ROOT/'ports/apple/mt_native_glue.c']
        def compile(source):
            obj=objects/(source.name+'.o')
            run(['clang','-O2','-w','-g0','-I',ROOT/'core','-c',source,'-o',obj])
            return obj
        with ThreadPoolExecutor(max_workers=max(1,args.jobs)) as pool: compiled=list(pool.map(compile,sources))
        library=args.output/('cvmtnative_'+gen+'.so')
        run(['clang','-dynamiclib','-Wl,-install_name,@rpath/'+library.name,'-o',library]+compiled)
        run(['codesign','-f','-s','-',library])
        print('Built',library,flush=True)

if __name__=='__main__':main()

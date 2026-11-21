#!/usr/bin/env python3
"""Validate real Vocalizer native tables in a 64-bit Apple executable or Mac libraries.

Rejects the zero-entry placeholder that cannot accelerate a newly supplied
engine. Reads Mach-O metadata only; --mac-libraries calls the native table getter.
"""
import argparse
import ctypes
import json
from pathlib import Path
import struct

BUILDS=['ios3','ios4','ios5','ios6','ios70','ios7','ios10']

def executable_counts(path):
    data=path.read_bytes()
    if data[:4]!=b'\xcf\xfa\xed\xfe':raise ValueError('Expected little-endian 64-bit Mach-O')
    offset=32;segments=[];symbols=None
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        cmd,size=struct.unpack_from('<II',data,offset)
        if cmd==0x19:
            vmaddr,vmsize,fileoff,filesize=struct.unpack_from('<QQQQ',data,offset+24)
            segments.append((vmaddr,fileoff,filesize))
        elif cmd==2:symbols=struct.unpack_from('<IIII',data,offset+8)
        offset+=size
    if symbols is None:raise ValueError('Missing symbol table')
    symoff,count,stroff,strsize=symbols;result={}
    for i in range(count):
        index,kind,section,desc,address=struct.unpack_from('<IBBHQ',data,symoff+i*16)
        if not index or (kind&0x0e)!=0x0e:continue
        end=data.find(b'\0',stroff+index,stroff+strsize)
        name=data[stroff+index:end].decode('ascii','replace')
        for build in BUILDS:
            if name!='_vx_native_'+build+'_count':continue
            for start,fileoff,length in segments:
                if start<=address and address+8<=start+length:
                    result[build]=struct.unpack_from('<Q',data,fileoff+address-start)[0]
                    break
    return result

def library_counts(directory):
    result={}
    for build in BUILDS:
        library=ctypes.CDLL(str((directory/('cvnative_'+build+'.so')).resolve()))
        library.cv_native_abi.restype=ctypes.c_int
        if library.cv_native_abi()!=1:raise ValueError('Wrong native ABI for '+build)
        library.cv_native_table.argtypes=[ctypes.POINTER(ctypes.c_size_t)]
        library.cv_native_table.restype=ctypes.c_void_p
        count=ctypes.c_size_t()
        if not library.cv_native_table(ctypes.byref(count)):raise ValueError('Missing table '+build)
        result[build]=count.value
    return result

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--executable',type=Path)
    group.add_argument('--mac-libraries',type=Path)
    args=parser.parse_args()
    counts=executable_counts(args.executable) if args.executable else library_counts(args.mac_libraries)
    missing=[build for build in BUILDS if counts.get(build,0)<=0]
    if missing:raise SystemExit('Missing/empty native tables: '+', '.join(missing))
    print(json.dumps(counts,sort_keys=True))

if __name__=='__main__':main()

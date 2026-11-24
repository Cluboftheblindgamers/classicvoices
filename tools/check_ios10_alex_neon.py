#!/usr/bin/env python3
"""Test the ARM decoder with our own clang-assembled instruction fixtures."""
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
out = ROOT / 'build/ios10-alex-port'
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['clang', '-target', 'armv7s-apple-ios10', '-c', str(ROOT / 'tests/ios10_alex/neon.s'), '-o', str(out / 'neon.o')], check=True)
data = (out / 'neon.o').read_bytes()
assert struct.unpack_from('<II', data) == (0xfeedface, 12)
offset = 28
text = None
for _ in range(struct.unpack_from('<I', data, 16)[0]):
    command, size = struct.unpack_from('<II', data, offset)
    if command == 1:
        section = offset + 56
        for _ in range(struct.unpack_from('<I', data, offset + 48)[0]):
            if data[section:section+16].rstrip(b'\0') == b'__text':
                length, file_offset = struct.unpack_from('<II', data, section + 36)
                text = data[file_offset:file_offset+length]
            section += 68
    offset += size
assert text
(out / 'neon.bin').write_bytes(text)
subprocess.run(['clang', '-O2', '-I' + str(ROOT / 'core'), str(ROOT / 'tests/ios10_alex/neon.c'), '-o', str(out / 'neon-test')], check=True)
subprocess.run([str(out / 'neon-test'), str(out / 'neon.bin')], check=True)

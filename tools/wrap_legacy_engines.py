#!/usr/bin/env python3
"""Store guest Mach-O images as resources understood by the engine loader."""
from pathlib import Path
import sys

MACHO = {bytes.fromhex(x) for x in ("cafebabe", "bebafeca", "feedface", "cefaedfe", "feedfacf", "cffaedfe")}

def wrap(path):
    with path.open("rb") as stream:
        if stream.read(4) not in MACHO:
            return False
    path.write_bytes(b"CVENGINE" + path.read_bytes())
    return True

def main():
    root = Path(sys.argv[1])
    if not root.is_dir():
        raise SystemExit(f"Missing voice resources: {root}")
    print(f"Wrapped {sum(wrap(p) for p in root.rglob('*') if p.is_file())} guest engine resources")

if __name__ == "__main__":
    main()

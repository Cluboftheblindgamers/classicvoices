# Panthera Speech's disc reader

`pantherahfs.py` is from Panthera Speech by Tamas Geczy
(https://github.com/tgeczy/panthera-speech, commit 7a02c80,
`panthera/addon/synthDrivers/_panthera/pantherahfs.py`), MIT licensed (see
LICENSE), unchanged. It reads HFS+ volumes, Apple partition maps, UDIF disk
images, xar packages and cpio payloads. tools/fetch_old_macintalk.py uses it to
read the Tiger, Leopard and Snow Leopard install discs on archive.org without
downloading them whole.

## Local Apple speech compatibility port

The local `panthera-parity` branch also adapts the maintained Panthera Speech
Apple implementation as of 2026-11-21. Source is in `ios/Shared/Panthera`,
with number rewriting and measured volume tables in `core/mt/mt_numbers.c`
and `core/mt/mt_volume.c`. These files retain the MIT attribution in LICENSE.
The maintained source snapshot was a source directory, not a Git checkout;
no revision hash is available for that snapshot.

The integration, settings transfer, UI and tests are local modifications.
This source tree contains no Apple engine binaries, voice data, generated
Apple engine translations, rendered test audio or private app packages.
Those are local test inputs/output under ignored `extracted/` and `build/`.
See the dated port entry in NOTES.md and PANTHERA-PARITY.json for validation
and remaining work. This branch is not an upstream release.

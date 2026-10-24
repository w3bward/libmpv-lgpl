#!/usr/bin/env python3
"""Checks dist/ (or dist-single/) is an LGPL build before it's published: mpv built with -Dgpl=false, FFmpeg reporting
an LGPL licence, and no GPL-only code (x264, x265, FFmpeg's GPL configuration) in any DLL. FFmpeg is checked in its own
DLLs or, in the single-DLL variant, in libmpv-2.dll. Exits non-zero on the first problem."""

import pathlib
import re
import sys

dist = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "dist")
dlls = sorted(dist.glob("*.dll"))
problems = []


def contents(path):
    return path.read_bytes()


if not dlls:
    sys.exit("no DLLs in " + str(dist))

libmpv = dist / "libmpv-2.dll"
if not libmpv.exists():
    problems.append("libmpv-2.dll is missing")
else:
    data = contents(libmpv)
    # mpv embeds its build options (meson.build_options()) as its configuration string.
    if b"-Dgpl=false" not in data:
        problems.append("libmpv-2.dll's configuration doesn't say -Dgpl=false")

ffmpeg = [d for d in dlls if re.match(r"(avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample)-\d+\.dll", d.name)]
if ffmpeg:
    if not any(d.name.startswith("avcodec-") for d in ffmpeg):
        problems.append("no avcodec DLL")
elif libmpv.exists():
    # The single-DLL variant: FFmpeg is linked into libmpv-2.dll.
    ffmpeg = [libmpv]
for dll in ffmpeg:
    data = contents(dll)
    # av*_license() returns this for an LGPL build, and "GPL version 2 or later" for a GPL one.
    if b"LGPL version 2.1 or later" not in data:
        problems.append(f"{dll.name} doesn't report an LGPL licence")
    if re.search(rb"(?<!L)GPL version [23] or later", data):
        problems.append(f"{dll.name} reports a GPL licence")
    for flag in (b"--enable-gpl", b"--enable-nonfree", b"--enable-version3"):
        if flag in data:
            problems.append(f"{dll.name} was configured with {flag.decode()}")

# GPL-only encoders: their own banners, which are compiled into anything that links them, and FFmpeg's wrappers.
# Not "x264 - core %d" alone: FFmpeg's H.264 decoder has that too, to read the banner x264 writes into what it encodes
# (libavcodec/h2645_sei.c).
markers = {
    b"H.264/MPEG-4 AVC codec - Copy": "x264",
    b"x265 (build": "x265",
    b"libx264 H.264": "FFmpeg's libx264 encoder",
    b"libx265 H.265": "FFmpeg's libx265 encoder",
}
for dll in dlls:
    data = contents(dll)
    for marker, name in markers.items():
        if marker in data:
            problems.append(f"{dll.name} contains {name}")

for p in problems:
    print("FAIL:", p)
if problems:
    sys.exit(1)
print(f"OK: {len(dlls)} DLLs, libmpv built with -Dgpl=false, FFmpeg LGPL, no x264 or x265")

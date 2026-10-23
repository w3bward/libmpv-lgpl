# libmpv-lgpl

An LGPL build of [libmpv](https://mpv.io/) for 64-bit Windows, built from pinned sources and checked before each release.

mpv doesn't publish a stable libmpv for Windows, and the community builds include GPL code (x264, x265). This repository builds libmpv with mpv's `-Dgpl=false` option, against an FFmpeg configured without `--enable-gpl`, so it can be shipped under the LGPL.

## What's in a release

- `libmpv-lgpl-<tag>-x86_64.zip`: `libmpv-2.dll` and every DLL it loads (FFmpeg, libplacebo, libass, FreeType, HarfBuzz, FriBidi, dav1d, Little CMS, zlib, libiconv, and the MinGW-w64 runtime), mpv's headers, each project's licence notices in `licenses/`, and `BUILDINFO.txt` with the exact versions and build options.
- `libmpv-lgpl-<tag>-x86_64-single.zip`: the same, with libmpv and all of those libraries statically linked into one `libmpv-2.dll`.
- `libmpv-lgpl-<tag>-x86_64-sources.tar.xz`: every source tree both builds used, as built.
- `SHA256SUMS`.

### Which to use

- **Separate DLLs:** each dependency is its own DLL, loaded dynamically, so any of them can be replaced on its own.
- **Single DLL:** one file to deploy. It loads nothing but Windows' own DLLs, so it can't fail to find a dependency (for example when a .NET app started as `dotnet <app>.dll` loads it from a folder Windows doesn't search), and it can't clash with another program's FFmpeg DLLs. It exports only libmpv's API, and is smaller, since only the parts of each library libmpv uses are linked in. Its components can't be replaced one by one, but the whole DLL can: the sources and build scripts are published, so it can be rebuilt (`./build.sh single`) and swapped, which meets the LGPL for a program that loads it dynamically.

## What it leaves out

Only what libmpv's OpenGL render API needs is built: no Vulkan, shaderc, SPIRV-Cross or D3D11 renderer, no Lua or JavaScript, no Blu-ray, DVD or archive support. FFmpeg is built **without network support**: it plays local files only.

## How it's checked

Every build, before anything is published:

1. **Pinned sources.** Each git source is cloned at its tag and must be at the commit in `versions.env`; each tarball must match its SHA-256.
2. **LGPL.** `verify.py` checks that `libmpv-2.dll` was configured with `-Dgpl=false`, that every FFmpeg DLL (in the single DLL, `libmpv-2.dll` itself) reports "LGPL version 2.1 or later" and wasn't configured with `--enable-gpl`, `--enable-nonfree` or `--enable-version3`, and that no DLL contains x264 or x265 (their own banners, or FFmpeg's encoders for them).
3. **Single DLL.** `build.sh single` checks that `libmpv-2.dll` imports nothing but Windows' own DLLs, and exports libmpv's API (`mpv_*`) and nothing else.
4. **Smoke test.** For each variant, under Wine, `smoke/smoke.c` loads libmpv, checks no scripting is built in (mpv has no `load-scripts`, `scripts` or `ytdl` option), opens `smoke/clip.mp4` (a synthetic 20-second H.264 test pattern with keyframes only at 0 s and 10 s), seeks exactly to 6.2 s, and steps one frame (40 ms).

## Building

On Ubuntu 24.04 with MinGW-w64, nasm, ninja, pkg-config and meson 1.7:

```bash
./build.sh
python3 verify.py dist
```

For the single DLL, `./build.sh single` and `python3 verify.py dist-single`.

The workflow in `.github/workflows/build.yml` does the same on every push. Pushing a tag named `mpv-<version>-r<n>` (for example `mpv-0.41.0-r1`) publishes that build as a release.

## Updating

Change the pins in `versions.env` (tag and commit, or URL and SHA-256), push, and check the build and its checks pass. Then tag a new release.

## Licence

The build scripts are adapted from mpv's `ci/build-mingw64.sh` and licensed under the GNU Lesser General Public License, version 2.1 or later (`LICENSE`). Each built library keeps its own licence; see `licenses/` in a release.

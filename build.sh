#!/bin/bash
# Builds an LGPL libmpv for 64-bit Windows from the sources pinned in versions.env, cross-compiling with MinGW-w64 on
# Linux. Adapted from mpv's own ci/build-mingw64.sh (v0.41.0), with every source pinned, the GPL parts off, and only
# what libmpv's OpenGL render API needs: no Vulkan, shaderc, SPIRV-Cross, Lua or JavaScript.
#
# Usage: build.sh [separate|single]
#   separate (the default): libmpv and each dependency as its own DLL, so any of them can be replaced.
#   single: libmpv and every dependency, the MinGW runtime included, statically linked into one libmpv-2.dll.
#
# Output: dist/ (dist-single/ for single: the DLLs, headers, licences and BUILDINFO.txt) and sources/ (every source
# tree it was built from).
set -Eeuo pipefail
# set -e stops without saying why; this says which command failed, and where.
trap 'echo "error: build.sh line $LINENO: $BASH_COMMAND" >&2' ERR

root=$PWD
. "$root/versions.env"

variant=${1:-separate}
case $variant in
separate) suffix="" ;;
single) suffix="-single" ;;
*)
    echo "usage: build.sh [separate|single]" >&2
    exit 2
    ;;
esac

export TARGET=${TARGET:-x86_64-w64-mingw32}
src=$root/work/src
prefix=$root/work/prefix$suffix
dist=$root/dist$suffix
mkdir -p "$src" "$prefix" "$dist"
ln -snf . "$prefix/usr"
ln -snf . "$prefix/local"

# -posix is Ubuntu's variant with pthreads support.
export CC=$TARGET-gcc-posix
export CXX=$TARGET-g++-posix
export AR=$TARGET-ar
export NM=$TARGET-nm
export RANLIB=$TARGET-ranlib
export CFLAGS="-O2 -pipe"
export LDFLAGS="-fstack-protector-strong"

# Only what this build installs is visible to pkg-config, so nothing is picked up from the build machine.
export PKG_CONFIG_SYSROOT_DIR=$prefix
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig

if [ "$variant" = single ]; then
    libs="--enable-static --disable-shared"
    default_library=static
    prefer_static=true
    zlib_shared=0
    # The MinGW runtime (libgcc, libstdc++, winpthreads) too, as the GCC Runtime Library Exception allows, so
    # libmpv-2.dll imports only Windows' own DLLs.
    LDFLAGS="$LDFLAGS -static"
else
    libs="--disable-static --enable-shared"
    default_library=shared
    prefer_static=false
    zlib_shared=1
fi

cat >"$prefix/crossfile" <<EOF
[built-in options]
buildtype = 'release'
wrap_mode = 'nodownload'
default_library = '${default_library}'
prefer_static = ${prefer_static}
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
nm = '${NM}'
strip = '${TARGET}-strip'
pkg-config = 'pkg-config'
windres = '${TARGET}-windres'
dlltool = '${TARGET}-dlltool'
nasm = 'nasm'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

group() { echo "::group::$1"; }
endgroup() { echo "::endgroup::"; }

# Clones a git source at its tag and checks it's at the pinned commit (submodules come at the commits it pins).
clone() {
    local dir=$1 url=$2 tag=$3 commit=$4
    if [ ! -d "$src/$dir" ]; then
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules "$url" "$src/$dir"
    fi
    local head
    head=$(git -C "$src/$dir" rev-parse HEAD)
    if [ "$head" != "$commit" ]; then
        echo "error: $dir is at $head, but versions.env pins $commit ($tag)" >&2
        exit 1
    fi
}

# Downloads a tarball, checks its SHA-256, and unpacks it to a directory named after it.
fetch() {
    local url=$1 sum=$2 name=${1##*/} dir
    dir=${name%.tar.*}
    if [ ! -d "$src/$dir" ]; then
        curl -sSLf --retry 3 -o "$src/$name" "$url"
        echo "$sum  $src/$name" | sha256sum -c --quiet -
        tar -xaf "$src/$name" -C "$src"
    fi
}

builddir() {
    rm -rf "$1/builddir"
    mkdir -p "$1/builddir"
    cd "$1/builddir"
}

install_build() {
    if [ -f build.ninja ]; then
        ninja
        DESTDIR="$prefix" ninja install
    else
        make -j"$(nproc)"
        make DESTDIR="$prefix" install
    fi
}

group "Sources"
clone mpv "$MPV_URL" "$MPV_TAG" "$MPV_COMMIT"
clone ffmpeg "$FFMPEG_URL" "$FFMPEG_TAG" "$FFMPEG_COMMIT"
clone libplacebo "$LIBPLACEBO_URL" "$LIBPLACEBO_TAG" "$LIBPLACEBO_COMMIT"
clone dav1d "$DAV1D_URL" "$DAV1D_TAG" "$DAV1D_COMMIT"
clone lcms2 "$LCMS2_URL" "$LCMS2_TAG" "$LCMS2_COMMIT"
clone libass "$LIBASS_URL" "$LIBASS_TAG" "$LIBASS_COMMIT"
fetch "$FREETYPE_URL" "$FREETYPE_SHA256"
fetch "$HARFBUZZ_URL" "$HARFBUZZ_SHA256"
fetch "$FRIBIDI_URL" "$FRIBIDI_SHA256"
fetch "$ZLIB_URL" "$ZLIB_SHA256"
fetch "$ICONV_URL" "$ICONV_SHA256"
endgroup

group "libiconv"
builddir "$src/libiconv-1.18"
../configure --host="$TARGET" --prefix=/ $libs
install_build
endgroup

group "zlib"
cd "$src/zlib-1.3.2"
make -fwin32/Makefile.gcc clean
make -fwin32/Makefile.gcc PREFIX="$TARGET-" CC="$CC" SHARED_MODE=$zlib_shared \
    DESTDIR="$prefix" BINARY_PATH=/bin INCLUDE_PATH=/include LIBRARY_PATH=/lib install
endgroup

group "dav1d"
builddir "$src/dav1d"
meson setup .. --cross-file "$prefix/crossfile" --prefix=/ -Denable_tools=false -Denable_tests=false
install_build
endgroup

group "lcms2"
builddir "$src/lcms2"
meson setup .. --cross-file "$prefix/crossfile" --prefix=/ -Dtests=disabled -Dutils=false -Dversionedlibs=false
install_build
endgroup

# LGPL: no --enable-gpl, --enable-version3 or --enable-nonfree. No network: the app plays only local files (ADR-0009
# in media-manager).
ffmpeg_args=(
    --prefix=/ --target-os=mingw32 --arch=x86_64 --enable-cross-compile --cross-prefix="$TARGET-"
    --pkg-config=pkg-config --cc="$CC" --cxx="$CXX" $libs
    # iconv and zlib are found by the compiler, not pkg-config.
    --extra-cflags="-I$prefix/include" --extra-ldflags="-L$prefix/lib"
    --disable-doc --disable-programs --disable-network
    --enable-libdav1d --enable-zlib --enable-iconv
)
if [ "$variant" = single ]; then
    # So FFmpeg's checks link dav1d with everything dav1d's static library needs.
    ffmpeg_args+=(--pkg-config-flags=--static)
fi
group "FFmpeg"
builddir "$src/ffmpeg"
../configure "${ffmpeg_args[@]}"
install_build
endgroup

group "libplacebo"
# libplacebo always compiles with PL_EXPORT, which marks its API dllexport even in a static library, so libmpv-2.dll
# would export it too. Built static, it gets PL_STATIC instead (what its headers expect of a static build); built
# shared, nothing changes. Patched in the source tree, so the sources archive has it.
sed -i "s/c_args: \['-DPL_EXPORT'\],/c_args: get_option('default_library') == 'static' ? ['-DPL_STATIC'] : ['-DPL_EXPORT'],/" \
    "$src/libplacebo/src/meson.build"
grep -qF "['-DPL_STATIC'] : ['-DPL_EXPORT']" "$src/libplacebo/src/meson.build"
builddir "$src/libplacebo"
meson setup .. --cross-file "$prefix/crossfile" --prefix=/ \
    -Ddemos=false -Dtests=false -Dopengl=enabled -Dlcms=enabled \
    -Dd3d11=disabled -Dvulkan=disabled -Dshaderc=disabled -Dglslang=disabled
install_build
if [ "$variant" = single ]; then
    # libplacebo has C++ code, but its pkg-config file doesn't name the C++ runtime, which a static link into libmpv
    # (linked as C) needs.
    pc=$prefix/lib/pkgconfig/libplacebo.pc
    grep -q '^Libs.private:' "$pc" || echo 'Libs.private:' >>"$pc"
    sed -i 's/^Libs.private:.*/& -lstdc++/' "$pc"
fi
endgroup

group "FreeType"
builddir "$src/freetype-2.14.3"
meson setup .. --cross-file "$prefix/crossfile" --prefix=/ -Dharfbuzz=disabled -Dbrotli=disabled -Dbzip2=disabled -Dpng=disabled -Dtests=disabled
install_build
endgroup

group "FriBidi"
builddir "$src/fribidi-1.0.17"
meson setup .. --cross-file "$prefix/crossfile" --prefix=/ -Dtests=false -Ddocs=false -Dbin=false
install_build
endgroup

group "HarfBuzz"
builddir "$src/harfbuzz-15.0.0"
meson setup .. --cross-file "$prefix/crossfile" --prefix=/ -Dtests=disabled -Dutilities=disabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled -Dfreetype=enabled
install_build
endgroup

group "libass"
builddir "$src/libass"
meson setup .. --cross-file "$prefix/crossfile" --prefix=/ -Dtest=disabled -Dfontconfig=disabled -Ddirectwrite=enabled
install_build
endgroup

# LGPL (-Dgpl=false), libmpv only, and nothing that runs scripts or needs Vulkan.
mpv_args=(
    -Dgpl=false -Dlibmpv=true -Dcplayer=false -Dbuild-date=false -Dtests=false
    -Dlua=disabled -Djavascript=disabled -Dcplugins=disabled
    -Dvulkan=disabled -Dshaderc=disabled -Dspirv-cross=disabled -Dd3d11=disabled
    -Dlibarchive=disabled -Dlibbluray=disabled -Ddvdnav=disabled -Dcdda=disabled -Duchardet=disabled
    -Drubberband=disabled -Dvapoursynth=disabled -Dzimg=disabled -Djpeg=disabled
    -Dmanpage-build=disabled -Dhtml-build=disabled -Dpdf-build=disabled
    -Dgl=enabled -Dlcms2=enabled -Dlibavdevice=enabled -Dwasapi=enabled
)
group "mpv"
cd "$src/mpv"
rm -rf builddir
# libmpv is the one shared library either way.
CFLAGS="$CFLAGS -I$prefix/include" LDFLAGS="$LDFLAGS -L$prefix/lib" \
    meson setup builddir --cross-file "$prefix/crossfile" --prefix=/ -Ddefault_library=shared "${mpv_args[@]}"
meson compile -C builddir
DESTDIR="$prefix" meson install -C builddir
endgroup

group "Package"
rm -rf "$dist"
mkdir -p "$dist/include" "$dist/licenses"
cp -r "$prefix/include/mpv" "$dist/include/"

# libmpv and every DLL it loads, found by walking imports; Windows' own DLLs are left out.
toolchain_dirs=("$(dirname "$($CC -print-libgcc-file-name)")" "/usr/$TARGET/lib")
declare -A seen=()
queue=(libmpv-2.dll)
while [ ${#queue[@]} -gt 0 ]; do
    dll=${queue[0]}
    queue=("${queue[@]:1}")
    if [ -n "${seen[$dll]:-}" ]; then continue; fi
    seen[$dll]=1
    found=""
    for dir in "$prefix/bin" "${toolchain_dirs[@]}"; do
        if [ -f "$dir/$dll" ]; then found="$dir/$dll"; break; fi
    done
    if [ -z "$found" ]; then continue; fi
    cp -p "$found" "$dist/"
    while read -r dep; do queue+=("$dep"); done < <($TARGET-objdump -p "$found" | sed -n 's/^\s*DLL Name: //p')
done

# Without debug symbols, which nothing at runtime needs (the MinGW runtime's libstdc++ alone carries about 24 MB).
$TARGET-strip --strip-unneeded "$dist"/*.dll

if [ "$variant" = single ]; then
    # The walk found no DLL of this build or of the toolchain: libmpv-2.dll imports only Windows' own.
    others=$(cd "$dist" && ls *.dll | grep -vx libmpv-2.dll || true)
    if [ -n "$others" ]; then
        echo "error: libmpv-2.dll should be the only DLL, but it loads: $others" >&2
        exit 1
    fi
    # It exports libmpv's API, and nothing of the libraries linked into it.
    exports=$($TARGET-objdump -p "$dist/libmpv-2.dll" | sed -n '/^\[Ordinal\/Name Pointer\] Table/,/^$/p' |
        grep '^\s*\[' | awk '{print $NF}')
    if ! grep -qx mpv_create <<<"$exports"; then
        echo "error: libmpv-2.dll doesn't export mpv_create" >&2
        exit 1
    fi
    foreign=$(grep -v '^mpv_' <<<"$exports" || true)
    if [ -n "$foreign" ]; then
        echo "error: libmpv-2.dll exports more than libmpv's API:" >&2
        echo "$foreign" >&2
        exit 1
    fi
fi

# Each project's licence notices, as the LGPL and the others require: whichever of the files named it has, and at
# least one.
copy_licenses() {
    local name=$1 dir=$2 copied=0
    shift 2
    mkdir -p "$dist/licenses/$name"
    for f in "$@"; do
        if [ -f "$dir/$f" ]; then
            cp "$dir/$f" "$dist/licenses/$name/"
            copied=1
        fi
    done
    if [ "$copied" = 0 ]; then
        echo "error: no licence file for $name in $dir (looked for: $*)" >&2
        exit 1
    fi
}
copy_licenses mpv "$src/mpv" LICENSE.LGPL Copyright
copy_licenses ffmpeg "$src/ffmpeg" COPYING.LGPLv2.1 LICENSE.md
copy_licenses libplacebo "$src/libplacebo" LICENSE
copy_licenses dav1d "$src/dav1d" COPYING
copy_licenses lcms2 "$src/lcms2" LICENSE COPYING
copy_licenses libass "$src/libass" COPYING
copy_licenses freetype "$src/freetype-2.14.3" LICENSE.TXT docs/FTL.TXT
copy_licenses harfbuzz "$src/harfbuzz-15.0.0" COPYING
copy_licenses fribidi "$src/fribidi-1.0.17" COPYING
copy_licenses zlib "$src/zlib-1.3.2" LICENSE README
copy_licenses libiconv "$src/libiconv-1.18" COPYING.LIB
copy_licenses mingw-w64-runtime "/usr/share/doc/mingw-w64-common" copyright
copy_licenses gcc-runtime "/usr/share/doc/gcc-mingw-w64-base" copyright

{
    echo "libmpv, LGPL build, for 64-bit Windows (MinGW-w64)"
    if [ "$variant" = single ]; then
        echo "Single DLL: libmpv, every library below and the MinGW-w64 runtime statically linked into libmpv-2.dll"
    else
        echo "Separate DLLs: libmpv, each library below and the MinGW-w64 runtime as its own DLL"
    fi
    echo
    echo "Sources (pinned in versions.env):"
    grep -E '_(TAG|COMMIT|URL|SHA256)=' "$root/versions.env"
    echo
    echo "mpv configure options: ${mpv_args[*]}"
    echo "FFmpeg configure options: ${ffmpeg_args[*]}"
    echo
    echo "Toolchain: $($CC --version | head -1)"
    echo "Link options: $LDFLAGS"
    echo "Built from build repo commit: $(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)"
} >"$dist/BUILDINFO.txt"
cp "$root/versions.env" "$dist/"
endgroup

group "Sources archive"
mkdir -p "$root/sources"
# The source trees as built (tarballs unpacked), without build output or git metadata.
tar --exclude=builddir --exclude=.git --exclude='*.tar.gz' --exclude='*.tar.xz' -C "$root/work" -cJf "$root/sources/sources.tar.xz" src
endgroup

echo "Built: $(ls "$dist"/*.dll | wc -l) DLLs in dist$suffix/"

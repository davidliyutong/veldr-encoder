#!/usr/bin/env bash
# Builds the video encoder for Linux machines (encoder.c on a minimal LGPL
# FFmpeg with NVENC, VA-API, and libvpx), linked statically except for glibc
# 2.28 (AlmaLinux 8). Writes dist/release/veldr-encoder-linux-<arch>.tar.gz.
set -euo pipefail
cd "$(dirname "$0")"

FFMPEG=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
NVHEADERS=n12.2.72.0
NVHEADERS_SHA256=dbeaec433d93b850714760282f1d0992b1254fc3b5a6cb7d76fc1340a1e47563
LIBVPX=v1.17.0
LIBVPX_SHA256=1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a
LIBVA=2.24.1
LIBVA_SHA256=eec6050b52876f229bd35e9df17cd31a06785e18e6f7990c445b584628483d67
LIBDRM=2.4.134
LIBDRM_SHA256=ac5e74d157830eb8bee44c6a6bf3ad49774ef0dd2a72bdad74a8f20308b52a95
MESON=1.12.1
MESON_SHA256=930bc7542cbd9f57009e182fd014eba48cf1a0180a7b9006d2d32d8f168d8b02

image() {
  case $1 in
    linux/amd64) echo almalinux:8@sha256:1965cb10f9c392766b2d544d3c1b997eb008d0e413c808e6a20086e87c802a80 ;;
    linux/arm64) echo almalinux:8@sha256:29fdedeed8a6707558c9e03b5d3e8f09eac5307cdd0811218d7d55a2cc9ae522 ;;
    *) echo "no build image for $1" >&2; exit 1 ;;
  esac
}
PLATFORMS=${FFMPEG_PLATFORMS:-linux/amd64 linux/arm64}

sha256_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

src=dist/ffmpeg/src
mkdir -p "$src" dist/release
fetch() {
  if [[ ! -f "$src/$2" ]]; then curl -sSfL -o "$src/$2.part" "$1" && mv "$src/$2.part" "$src/$2"; fi
  echo "$3  $src/$2" | sha256_cmd -c - >/dev/null || { echo "$2: checksum mismatch" >&2; exit 1; }
}
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz" "ffmpeg-$FFMPEG.tar.xz" "$FFMPEG_SHA256"
fetch "https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/$NVHEADERS.tar.gz" "nv-codec-headers-$NVHEADERS.tar.gz" "$NVHEADERS_SHA256"
fetch "https://github.com/webmproject/libvpx/archive/refs/tags/$LIBVPX.tar.gz" "libvpx-$LIBVPX.tar.gz" "$LIBVPX_SHA256"
fetch "https://github.com/intel/libva/releases/download/$LIBVA/libva-$LIBVA.tar.bz2" "libva-$LIBVA.tar.bz2" "$LIBVA_SHA256"
fetch "https://dri.freedesktop.org/libdrm/libdrm-$LIBDRM.tar.xz" "libdrm-$LIBDRM.tar.xz" "$LIBDRM_SHA256"
fetch "https://files.pythonhosted.org/packages/py3/m/meson/meson-$MESON-py3-none-any.whl" "meson-$MESON-py3-none-any.whl" "$MESON_SHA256"

for p in $PLATFORMS; do
  plat=${p/\//-}
  out=dist/ffmpeg/$plat
  build=dist/ffmpeg/build-$plat
  img=$(image "$p")
  mkdir -p "$out" "$build"
  docker run --rm --platform "$p" -v "$PWD/$src:/src:ro" -v "$PWD/encoder.c:/encoder.c:ro" \
    -v "$PWD/$build:/b" -v "$PWD/$out:/out" \
    -e FFMPEG="$FFMPEG" -e NVHEADERS="$NVHEADERS" -e LIBVPX="$LIBVPX" -e LIBVA="$LIBVA" -e LIBDRM="$LIBDRM" -e MESON="$MESON" \
    -e RECIPE="$(sha256_cmd "$0" | cut -c1-12)" \
    "$img" bash -euo pipefail -c '
    dnf -y -q install dnf-plugins-core >/dev/null && dnf config-manager --set-enabled powertools
    dnf -y -q install gcc gcc-c++ make diffutils pkgconf-pkg-config xz bzip2 perl nasm python3.11 python3.11-pip ninja-build libatomic-static >/dev/null
    python3.11 -m pip install -q --no-index /src/meson-$MESON-py3-none-any.whl
    triplet=$(uname -m)-linux-gnu
    drivers=/usr/lib/$triplet/dri:/usr/lib64/dri:/usr/lib/dri
    export PKG_CONFIG_PATH=/b/deps/lib/pkgconfig
    cd /b
    stamp=$RECIPE
    if [[ ! -f done-$stamp ]]; then
      rm -rf deps ff src done-* && mkdir src && cd src
      tar xf /src/nv-codec-headers-$NVHEADERS.tar.gz && make -s -C nv-codec-headers-*/ PREFIX=/b/deps install
      tar xf /src/libdrm-$LIBDRM.tar.xz && cd libdrm-$LIBDRM
      meson setup build --prefix=/b/deps --libdir=lib --default-library=static --buildtype=release \
        -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled -Dvmwgfx=disabled \
        -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled -Dtegra=disabled -Dvc4=disabled \
        -Detnaviv=disabled -Dcairo-tests=disabled -Dman-pages=disabled -Dvalgrind=disabled \
        -Dudev=false -Dtests=false -Dinstall-test-programs=false >/dev/null
      ninja -C build install >/dev/null && cd ..
      tar xf /src/libva-$LIBVA.tar.bz2 && cd libva-$LIBVA
      ./configure --prefix=/b/deps --libdir=/b/deps/lib --enable-static --disable-shared --enable-drm \
        --disable-x11 --disable-glx --disable-wayland --disable-docs --with-drivers-path=$drivers >/dev/null
      make -s -j"$(nproc)" install >/dev/null && cd ..
      tar xf /src/libvpx-$LIBVPX.tar.gz && cd libvpx-*/
      as=; [[ $(uname -m) == x86_64 ]] && as=--as=nasm
      ./configure --prefix=/b/deps --enable-static --disable-shared --enable-pic --disable-examples --disable-tools \
        --disable-docs --disable-unit-tests --enable-vp8 --enable-vp9 --enable-realtime-only $as >/dev/null
      make -s -j"$(nproc)" install >/dev/null && cd ..
      tar xf /src/ffmpeg-$FFMPEG.tar.xz && cd ffmpeg-$FFMPEG
      ./configure --prefix=/b/ff --pkg-config-flags=--static \
        --disable-everything --disable-autodetect --disable-doc --disable-network --disable-debug \
        --disable-ffplay --disable-ffprobe --enable-ffmpeg --enable-swscale \
        --enable-ffnvcodec --enable-cuda --enable-nvenc --enable-vaapi --enable-libvpx \
        --enable-protocol=pipe,file --enable-demuxer=rawvideo --enable-decoder=rawvideo \
        --enable-encoder=h264_nvenc,hevc_nvenc,av1_nvenc,h264_vaapi,libvpx_vp8,libvpx_vp9,rawvideo \
        --enable-muxer=h264,hevc,ivf,mp4,nut,rawvideo,null \
        --enable-bsf=h264_metadata,hevc_metadata,extract_extradata,h264_mp4toannexb,vp9_superframe \
        --enable-parser=h264,hevc,vp8,vp9 --enable-filter=scale,format,pad,null,copy \
        --extra-ldflags="-static-libgcc -L/b/deps/lib" --extra-libs="-ldrm -ldl -lpthread" >/dev/null
      grep -q "define HAVE_VAAPI_DRM 1" config.h || { echo "VA-API without DRM" >&2; exit 1; }
      make -s -j"$(nproc)" install >/dev/null
      cd /b && touch done-$stamp
    fi
    libs=$(PKG_CONFIG_PATH=/b/ff/lib/pkgconfig:/b/deps/lib/pkgconfig pkg-config --static --libs libavcodec libswscale libavutil)
    gcc -O2 -Wall -I/b/ff/include /encoder.c -o /b/encoder -static-libgcc ${libs//-latomic/-l:libatomic.a} -L/b/deps/lib -ldrm -ldl
    strip -o /out/encoder /b/encoder
    strip -o /out/ffmpeg /b/ff/bin/ffmpeg
    for e in h264_nvenc h264_vaapi libvpx; do
      /out/ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " $e " || { echo "$e is missing" >&2; exit 1; }
    done
    ldd /out/encoder | tee /dev/stderr | grep -vE "linux-vdso|ld-linux|lib(c|m|dl|pthread|rt)\.so" && { echo "unexpected shared libraries" >&2; exit 1; }
    true
  '
  pkg=dist/pkg-$plat
  rm -rf "$pkg" && mkdir -p "$pkg"
  cp "$out/encoder" "$pkg/encoder"
  chmod 755 "$pkg/encoder"
  cp LICENSE "$pkg/LICENSE"
  cp licenses/* "$pkg/"
  (cd "$pkg" && tar -czf "$OLDPWD/dist/release/veldr-encoder-$plat.tar.gz" *)
  rm -rf "$pkg"
  echo "    dist/release/veldr-encoder-$plat.tar.gz ($(du -h "dist/release/veldr-encoder-$plat.tar.gz" | cut -f1))"
done

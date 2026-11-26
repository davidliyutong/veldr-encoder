# veldr-encoder

Minimal static video encoder for Linux remote program windows in `veldr` (H.264 via NVENC / VA-API, VP8 via libvpx), built against glibc 2.28 (AlmaLinux 8) inside Docker from SHA-256-pinned FFmpeg, libvpx, libva, libdrm, and nv-codec-headers sources.

## Build

```bash
./build.sh                            # linux/amd64 and linux/arm64
FFMPEG_PLATFORMS=linux/amd64 ./build.sh
```

Release archives are written to `dist/release/veldr-encoder-linux-<arch>.tar.gz` alongside `SHA256SUMS`.
See [licenses/README.md](licenses/README.md) for third-party component versions and licenses.

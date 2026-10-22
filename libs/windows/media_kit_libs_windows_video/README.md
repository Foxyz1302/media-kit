# [package:media_kit_libs_windows_video](https://github.com/media-kit/media-kit)

[![](https://img.shields.io/discord/1079685977523617792?color=33cd57&label=Discord&logo=discord&logoColor=discord)](https://discord.gg/h7qf2R9n57) [![Github Actions](https://github.com/media-kit/media-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/media-kit/media-kit/actions/workflows/ci.yml)

Windows package providing video (& audio) native libraries for [`package:media_kit`](https://github.com/media-kit/media-kit).

## libmpv

`windows/CMakeLists.txt` downloads `libmpv-2.dll` from release [`20261021-1`](https://github.com/freeKC/libmpv-builds/releases/tag/20261021-1) of [freeKC/libmpv-builds](https://github.com/freeKC/libmpv-builds), checks it by SHA-256 and bundles it next to the executable. It is mpv [`0b7ed670`](https://github.com/mpv-player/mpv/commit/0b7ed670f7c353dd3dd4f8ae0fc788a181a15aa6) with FFmpeg [`5b9a3ad7`](https://github.com/FFmpeg/FFmpeg/commit/5b9a3ad71a4b54979e7afc3a1a4269763c4f41fc), built from pinned sources.

| Target | Archive | SHA-256 |
| --- | --- | --- |
| x64 | `mpv-dev-x86_64-20261021-git-0b7ed67.7z` | `b3d1a4b3a8e202c28369a46f5fb776baa0742e38de8c9d0757b0255bcb8223d1` |
| arm64 | `mpv-dev-aarch64-20261021-git-0b7ed67.7z` | `f5f597b2f85804d82907bcd3784f6943c0f55caca120dad75e258352d9fb3dbb` |

The arm64 DLL has no OpenGL, so `package:media_kit_video` draws video in software there.

### TLS

This mpv verifies TLS certificates by default (`tls-verify=yes`), and its OpenSSL looks for CA certificates only in a directory of the machine that built it. HTTPS media therefore fails to open unless the app gives mpv a CA bundle:

```dart
await (player.platform as NativePlayer).setProperty('tls-ca-file', path);
```

`tls-verify=no` restores the behaviour of the earlier builds, which accepted any certificate.

### Licence

`libmpv-2.dll` is under the GNU LGPL, version 3 or later as built: mpv with `-Dgpl=false`, FFmpeg with `--enable-version3` and without GPL or nonfree parts. The libraries linked into it keep their own licences. An application that ships it has to:

- ship the licence texts with it. The build writes them, with the archive's `BUILDINFO.txt`, into `libmpv-licenses.txt` and bundles that file next to `libmpv-2.dll`;
- offer the corresponding source to those it gives the DLL to: [`libmpv-windows-20261021-1-sources.tar.xz`](https://github.com/freeKC/libmpv-builds/releases/download/20261021-1/libmpv-windows-20261021-1-sources.tar.xz), SHA-256 `77e612c8110b1731c9b180cda840bb965939440c743d480f34cab957861e9d11`. An app that only points to it stays responsible for it remaining available, so keeping a copy is safer;
- keep `libmpv-2.dll` a separate file that users can replace with their own build, and not forbid reverse engineering for debugging such changes.

## License

Copyright © 2021 & onwards, Hitesh Kumar Saini <<saini123hitesh@gmail.com>>

This project & the work under this repository is governed by MIT license that can be found in the [LICENSE](./LICENSE) file.

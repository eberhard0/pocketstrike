# Third-party notice: Local Dream

PocketStrike's on-device image generation runs the native engine of
**Local Dream** (https://github.com/xororz/local-dream) by **xororz**,
version 2.8.1, together with the Qualcomm QNN/HTP runtime libraries that
Local Dream ships for Snapdragon NPUs.

- Local Dream is licensed **CC BY-NC 4.0** (Attribution-NonCommercial):
  https://creativecommons.org/licenses/by-nc/4.0/. Because of that,
  PocketStrike builds that include the engine are free and non-commercial.
- The engine and the QNN libraries are not stored in this repository. The
  CI workflow downloads Local Dream's official 2.8.1 release, checks its
  SHA-256, and copies only `libstable_diffusion_core.so` and the HTP V79/V81
  runtime into the build. No Local Dream source code is copied.
- Models are not bundled: PocketStrike uses the ones Local Dream downloaded,
  from Download/LocalDream, under their own licences.

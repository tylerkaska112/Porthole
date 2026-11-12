# Extras

Libraries Porthole puts next to a program that needs them and does not ship in the Windows layer itself (see `Sources/Core/SideBySide.swift`).

* `arm64ec/avicap32.dll` (for x64 programs) and `aarch64/avicap32.dll` (for native Arm programs): Wine's `avicap32` (video capture, LGPL-2.1+), built from the `wine/dlls/avicap32`
  source of the pinned Madeira snapshot (`vendor/Madeira`) in the same build modes as its sibling `avifil32` and `msvfw32`. FFmpeg's `avdevice-*.dll` (Blender) imports it,
  so without it the program stops at start with "AVICAP32.dll not found". It only has to load: nothing here captures video.

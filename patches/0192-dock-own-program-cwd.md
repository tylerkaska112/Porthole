# 0192: the Dock host starts the game's own program from the install folder

`madeira-dock/src/launch.c`, `run_own_program` (Porthole 0075: a program of the game started next to Valve's signed-in client): `CreateProcessW` now gets the verified install folder as the working directory instead of the program's own folder. A program in the install folder itself
(Rust's `RustClient.exe`) sees no change. A program below it (BeamNG.drive's `Bin64/BeamNG.drive.x64.exe`, started by the app because the game's launcher picks the native ARM64 build, which the engine cannot run) starts where its launcher would have started it, the game's folder.
The app gives the program as a path below the game's folder (`Fix.steamProgram = "Bin64/BeamNG.drive.x64.exe"`, `Fix.steamProgramArgs`); the host still refuses anything outside the install folder or that is not an .exe.

Applies to `madeira-dock` after the series in `build/dock-patches/`; rebuild with `build/madeira-dock/build.sh` (output `app/Madeira/arm64ec-windows/dockhost.exe`, copied to the stage's `Resources/arm64ec-windows/`). Does not change any game that has no `steamProgram`, so `tools/engine.sh accept`.

# 0101 Dock: register shell32, windowscodecs, urlmon, wintrust, cryptnet once (COM classes a prefix needs)

`app/Runtime/DockInstallers.swift` (`DockInstallScripts.batch`, replaces the single wintrust line of 0099; applied by `tools/vendor_glue.sh` after 0100). With the service step on, the batch runs, once (marker file `C:\madeira-com-registered.txt`):
`regsvr32.exe /s shell32.dll windowscodecs.dll urlmon.dll wintrust.dll cryptnet.dll` and writes `com-registered <errorlevel>` to the result file.

Why (RDR2, logs of 0.50.176/177, user report 2026-10-09: no `Social Club` folder under `Program Files\Rockstar Games`, only `Launcher`): Social-Club-Setup.exe (with `/silent`, from the Dock batch, and with `/silent /forceinstall`, from the launcher) ends with exit code 0 and installs nothing.
The log of the Dock run shows why: `err:ole:create_server class {56fdf344-fd6d-11d0-958a-006097c9a090} not registered` (CLSID_TaskbarList, registered by shell32.dll's DllRegisterServer) right before `exit_process raw_status=0x0`.
A normal Wine prefix registers those DLLs through wine.inf's RegisterDllsSection when it is created; this prefix never did. The launcher then finds no SDK (`socialclub.dll` of the Social Club folder) and reports "incomplete installation (code 1002)" and offers the installer again.
The five DLLs are the ones wine.inf registers that exist in the ARM64EC farm and are not media filters. A DLL that cannot register fails alone; regsvr32 goes on to the next.

After this build: tap "Run them all again" on the game's page (so Social Club's setup runs once more with the COM classes in place), start the game, and look for `com-registered 0`, a `Social Club` folder and no `not registered` line.
Not verified on a device.

**2026-11-08 change (1.3.84):** `windowscodecs.dll` is no longer in the list and the marker is `C:\madeira-com-registered2.txt`. Two GTA V logs (1.3.82 and 1.3.83) showed Rockstar's launcher failing with "failed to initialize": CLSID_WICImagingFactory2's InprocServer32 held garbage (`\x238\xf9acs`), and after `regsvr32 windowscodecs.dll` had run again ("Successfully registered") it held different garbage (`\0238\f778p`). The prefix template has `C:\windows\system32\windowscodecs.dll`. `app/Sources/Core/PrefixHealth.swift` now also puts that value right in the prefix's system.reg before Wine starts (copy kept as system.reg.porthole-before-repair) and logs any other class registration that names no program. Cause of the garbage not found (suspects: the ANSI registry write in windowscodecs' own DllRegisterServer under the current NLS/code page, or the string conversion in the r29 merge).

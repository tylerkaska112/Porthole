#!/bin/bash
# Copy the Iridium-free runtime glue from the pinned GitHub Madeira clone (vendor/Madeira, same snapshot the libraries are built from) into app/Runtime.
# Re-runnable; wipes the previously vendored files first. NOT copied: any file mentioning Iridium, FEXBridge/hello_x86 (replaced by app/Sources/Core/RuntimeStubs.c), any UI.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${MADEIRA_ROOT:-$HERE/vendor/Madeira}/app/Madeira"
DST="$HERE/app/Runtime"
FILES="JITAllocator.c JITAllocator.h PrefixExtractor.c PrefixExtractor.h wine_stubs.c IOSDisplayShim.m IOSDisplayShim.h WineProcessBridge.m WineProcessBridge.h WineServerBridge.m WineServerBridge.h
Winios/Winios.h Winios/Winios.m Winios/WiniosCursor.c Winios/WiniosCursor.h Winios/WiniosGamepad.c Winios/WiniosGamepad.h Winios/VulkanLayerGeometry.h Winios/WiniosPadEffects.h
StikJITHelper.swift EntitlementChecker.swift LogStore.swift LogPattern.swift LogTail.swift MadeiraConfig.swift
SteamKeyValues.swift SteamInstall.swift MadeiraDock.swift SteamRuntime.swift DockInstallers.swift
ExternalStorage.swift LogSummary.swift JITPoolMeter.swift DockReset.swift DockGameSession.swift DonorPool.m MemoryHostProtocol.h GPUCards.swift GameRecommendations.swift WineMono.swift WineGecko.swift VCRedist.swift CabinetReader.c CabinetReader.h BackgroundRun.swift Winios/BackgroundCPUCap.c Winios/MetalBackgroundGate.m
SwiftEA/EAAPI.swift SwiftEA/EAFormats.swift SwiftEA/EADownloader.swift SwiftEA/EALicense.swift SwiftEA/EAService.swift"
# Madeira's own Steam client (SwiftSteam) is NOT taken: Porthole's Steam sign-in, library and downloads are in app/Sources/Steam, written for this project.
# Only the vendored files are replaced: app/Runtime also holds files of our own (DockLaunchOptions.swift, DockRegistryRepair.swift, Bridging-Header.h), which must stay.
for f in $FILES; do rm -f "${DST:?}/${f:?}"; done
for f in $FILES; do
  if grep -qi iridium "$SRC/$f"; then echo "REFUSING $f: mentions Iridium"; exit 1; fi
  mkdir -p "$DST/$(dirname "$f")"; cp -p "$SRC/$f" "$DST/$f"
done
( cd "$DST" && shasum -a 256 $FILES > SHA256SUMS )
# Our own numbered patches to the vendored files (SHA256SUMS above are the pristine upstream hashes). Applied from the repo root.
# 0003 (pool hole) is upstream since #147, so it is no longer applied; 0016 (give back the executable window) is ported to the newer StikJITHelper.
for patch_file in "$HERE"/patches/0011-*.patch "$HERE"/patches/0016-*.patch "$HERE"/patches/0019-*.patch "$HERE"/patches/0085-*.patch "$HERE"/patches/0099-*.patch "$HERE"/patches/0100-*.patch "$HERE"/patches/0101-*.patch "$HERE"/patches/0107-*.patch "$HERE"/patches/0150-*.patch "$HERE"/patches/0171-*.patch; do
  [ -f "$patch_file" ] && ( cd "$HERE" && patch -p1 -s < "$patch_file" ) && echo "applied $(basename "$patch_file")"
done
# Porthole's Telemetry reads LogStore.shared.logFileURL; upstream made it private (the 0.50.233 re-vendor found out).
sed -i '' 's/    private let logFileURL: URL/    let logFileURL: URL/' "$DST/LogStore.swift"
# The donor-RAM extension (MadeiraMemoryHost): the same source, built as Porthole's F4MemoryHost target (app/project.yml); its header is the vendored one in Runtime.
mkdir -p "$HERE/app/MemoryHost"
sed 's#"../Madeira/MemoryHostProtocol.h"#"../Runtime/MemoryHostProtocol.h"#' "$SRC/../MadeiraMemoryHost/MemoryHost.m" > "$HERE/app/MemoryHost/MemoryHost.m"
cp -p "$SRC/../MadeiraMemoryHost/MemoryHost.entitlements" "$HERE/app/MemoryHost/MemoryHost.entitlements"
# Madeira's EA code names Madeira in the text a player reads and in the client name it sends to EA; Porthole's own words and name instead.
sed -i '' -e 's/for Madeira to download/for Porthole to download/' -e 's/in Settings › EA app/in the Stores tab/' -e 's/"Madeira (EA client)"/"Porthole (EA client)"/' -e 's/madeira\.ea\.tokens/porthole.ea.tokens/' "$DST/SwiftEA/EAAPI.swift"
# Wine Mono (the .NET Framework runtime, downloaded from WineHQ on first use): Madeira's own Settings section is left out; Porthole's rows are in UI/Settings/SettingsPages.swift and the Home notice.
sed -i '' '/^\/\/ MARK: - Settings › .NET Framework/,$d' "$DST/WineMono.swift"
# Wine Gecko (the HTML engine Wine's mshtml loads, downloaded from WineHQ): the same, Madeira's Settings section is left out; Porthole's rows are in UI/WineGeckoPanel.swift and Settings > Advanced > Windows components.
sed -i '' '/^\/\/ MARK: - Settings › Web pages in programs/,$d' "$DST/WineGecko.swift"
# Microsoft's Visual C++ runtime, taken out of Microsoft's installers on the device (VCRedist.swift + CabinetReader.c): only the 32-bit (x86) runtime is used. The 64-bit one is Porthole's own
# VCRuntimeInstaller (Application Support/Porthole/x86_64-vcruntime), which the 64-bit side keeps using; Documents/vcruntime32 is the folder the bridge overlays onto 32-bit programs.
# Madeira's Settings section is left out (Porthole's row is in Settings > Advanced > Windows components), and its session check uses Porthole's own session.
sed -i '' '/^\/\/ MARK: - Settings › Visual C++ runtimes/,$d' "$DST/VCRedist.swift"
# Keeping a game running while you are in another app (BackgroundRun.swift, the CPU cap and the Metal gate): off unless Settings turns it on. Madeira defaults it to 10 minutes; Porthole to 0
# (an experiment, never started by itself), and the GPU gate (which also holds a game's frames during a pull of Control Center) is installed only when it is on.
sed -i '' -e 's/minutes(MadeiraConfig.gameValue("background-run") ?? MadeiraConfig.get("background-run"), default: 10)/minutes(MadeiraConfig.gameValue("background-run") ?? MadeiraConfig.get("background-run"), default: 0)/' \
  -e 's/if MadeiraConfig.get("background-gpu-gate") != "0" {/if MadeiraConfig.get("background-gpu-gate") != "0", Self.gameMinutes > 0 {/' "$DST/BackgroundRun.swift"
sed -i '' -e 's/static let packages = \[x64, x86\]/static let packages = [x86]/' -e 's/LibraryModel.shared.current == nil/!AppModel.shared.session.isActive/' "$DST/VCRedist.swift"
echo "vendored $(echo $FILES | wc -w) files from $SRC @ $(git -C "$HERE/vendor/Madeira" rev-parse --short HEAD)"

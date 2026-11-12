// Runtime C/ObjC surface exposed to Swift (same entry points as the pinned Madeira's own bridging header, minus Steam and FEX).
#import "JITAllocator.h"
#import "WineServerBridge.h"
#import "WineProcessBridge.h"
#import "CabinetReader.h"
#import "PrefixExtractor.h"
// Madeira in the background (audio_null_ios.c in the engine library, BackgroundRun.swift, Winios/BackgroundCPUCap.c, Winios/MetalBackgroundGate.m).
int madeira_audio_background(int keepalive, int mute, int halt);
void madeira_audio_resume_after_interruption(void);
int madeira_audio_check(void);
void madeira_bg_cpu_cap(int percent);
void madeira_bg_cpu_stats(double *cpu_s, double *wall_s, double *held_s);
int madeira_metal_gate_install(void);
#import "IOSDisplayShim.h"
#import "Winios/Winios.h"
#import "Winios/WiniosCursor.h"
#import "Winios/WiniosGamepad.h"
#include "itch_rar.h"      // Sources/Itch: the .rar reader for itch.io downloads (over the system libarchive)
#include "itch_7z.h"      // Sources/Itch: the .7z reader for itch.io downloads (Madeira's)
#include <stdint.h>
// Provided by Sources/Core/RuntimeStubs.c
int64_t fex_get_jit_write_offset(void);

void wine_log_set_file(const char *path);
typedef void (*wine_ui_log_callback_t)(const char *message);
void wine_set_ui_log_callback(wine_ui_log_callback_t cb);
uint64_t madeira_get_present_count(void);
// DXMT presents plus OpenGL presents (Winios/WiniosGL.m, patch 0083): what the launch screen and the FPS readout count
uint64_t madeira_frame_count(void);
void madeira_capture_request(int frames);
// GPU busy time for the performance overlay (winemetal_unix.c): while enabled, each committed command buffer adds its GPU time on completion.
void madeira_gpu_meter_enable(int on);
double madeira_gpu_meter_busy_seconds(void);
uint64_t madeira_gpu_meter_cmdbufs(void);
// Frame generation on or off while a game runs (winemetal_unix.c): `hz` is the screen's top refresh rate, which it needs to decide whether it can show two pictures per game frame.
void madeira_framegen_set(int on, double hz);
int madeira_framegen_get(void);
void madeira_set_eco(int on);
int madeira_get_eco(void);
void madeira_set_fence_mode(int mode);
void madeira_set_vsync_locked(int locked);
int madeira_get_vsync_locked(void);
void madeira_set_display_max_fps(int panel_hz, int intent_hz);
int madeira_dxmt_has_display_pacing(void);
void winios_phase(const char *name);
#import "../Sources/Core/SampleProfiler.h"

#import "JITExtensionLauncher.h"
// idevice C entry points (exported by StikJIT.framework) for the on-device installer.
#import "IdeviceInstall.h"

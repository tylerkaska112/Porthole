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
#import "Winios/GameCapture.h"      // Discord Go Live: the game window's own picture
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
// The same without the pictures of hidden windows (the launcher's hidden Chromium layer presents 10 times a second all game long): what the input-lag meter waits for (Winios/Winios.m)
uint64_t madeira_shown_frame_count(void);
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

// Discord voice end-to-end encryption (libdave, MIT): Sources/Discord/DiscordDave.swift. Built by tools/build_dave.sh into app/DaveStage.
#include <dave/dave.h>
// Go Live over WebRTC (libdatachannel, MPL-2.0): Sources/Discord/DiscordWebRTC.swift. Built by tools/build_datachannel.sh into app/DaveStage.
#define RTC_STATIC 1
#define RTC_ENABLE_WEBSOCKET 0
#define RTC_ENABLE_MEDIA 1
#include <rtc/rtc.h>
#include "DiscordOpus.h"   // Sources/Discord: libopus for Discord voice (built by tools/build_dave.sh)
// Porthole is one audio source (Discord branch, patch 0200, ntdll-unix/audio_null_ios.c): Discord's sound goes into the game engine's single audio unit and the microphone is read on it.
#include <stddef.h>
int porthole_voice_start(int want_mic);
void porthole_voice_stop(void);
unsigned porthole_voice_rate(void);
int porthole_voice_mic_on(void);
size_t porthole_voice_write(const float *src, size_t frames);
size_t porthole_voice_playback_fill(void);
size_t porthole_voice_read(float *dst, size_t max_frames);
/* Game volume at the output in percent (10..200), engine audio_null_ios.c. */
void madeira_audio_set_gain_percent(int percent);
/* The game's own sound for Go Live (patch 0201): interleaved stereo float frames at porthole_voice_rate(), without Discord's voices. */
void porthole_game_audio_start(void);
void porthole_game_audio_stop(void);
size_t porthole_game_audio_read(float *dst, size_t max_frames);
uint64_t porthole_game_audio_drops(void);
void porthole_voice_stats(uint64_t *cap_drops, uint64_t *play_short, uint64_t *render_errs);

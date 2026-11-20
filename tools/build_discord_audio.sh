#!/bin/bash
# Discord branch only. Builds the audio driver with the voice bridge (patches/0200-discord-voice-bridge.patch: Porthole is ONE audio source, the app mixes Discord's sound
# into the game engine's one audio unit and reads the microphone on it) into its own copy of libntdll_unix.a, and stages a runtime that uses it (stage-discord, a
# clone of the normal stage with that one library replaced). The normal staged runtime and the engine clone are not touched: the 1.3.x builds keep using them.
#   tools/build_discord_audio.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
F4_BUILD_ROOT="${F4_BUILD_ROOT:-$HERE/build}"
SRC="$HERE/vendor/Madeira/build/ntdll-unix/audio_null_ios.c"
WORK="$F4_BUILD_ROOT/discord-engine"; mkdir -p "$WORK"
cp "$SRC" "$WORK/audio_null_ios.c"
( cd "$WORK" && patch -s audio_null_ios.c < "$HERE/patches/0200-discord-voice-bridge.patch" )
( cd "$WORK" && patch -s audio_null_ios.c < "$HERE/patches/0201-discord-game-audio-tap.patch" )      # the game's own mix for Go Live
AUDIO_NULL_SRC="$WORK/audio_null_ios.c" OUT="$F4_BUILD_ROOT/ntdll-lib-discord" "$HERE/tools/rebuild_ntdll_object.sh" audio_null
BASESTAGE="${BASESTAGE:-$F4_BUILD_ROOT/stage-r29}"
STAGE="$F4_BUILD_ROOT/stage-discord"
rm -rf "$STAGE"; cp -cR "$BASESTAGE" "$STAGE"
rm -f "$STAGE/lib/libntdll_unix.a"; cp "$F4_BUILD_ROOT/ntdll-lib-discord/libntdll_unix.a" "$STAGE/lib/libntdll_unix.a"
ln -sfn "$STAGE" "$HERE/app/RuntimeStage"
echo "✓ staged $STAGE with the voice bridge in libntdll_unix.a; app/RuntimeStage points at it"

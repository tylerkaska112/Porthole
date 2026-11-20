# Playing on a TV or monitor

**1.4.8 (2026-11-13): restored from `v0.50.216` for a cable only, at the owner's request. Not verified on a device with a display: it needs a USB-C or Lightning to HDMI cable and a TV. AirPlay stays a mirror (see the end of this file).** Patch 0103 is applied by `tools/vendor_glue.sh` and recorded with `tools/engine.sh accept` (nothing changes while no display is connected, so the badges were not reset).

Connect a display (AirPlay, or a cable to a TV or monitor) and the game's picture goes there, aspect-fitted on black. The touch controls, the in-game menu, the keyboard button and
the controller pointer stay on the iPhone or iPad. Settings, Play, Display, "Play on a connected display" turns it off (the display then just mirrors, as before).

## How it works
- `app/Info` declares a scene for the external-display role (`UIApplicationSceneManifest`, no delegate class; ExternalDisplay listens for UIScene.willConnectNotification (SwiftUI answers for every scene, so a delegate class named in Info.plist was never used)). iOS only mirrors a device's screen unless an app
  puts a window of its own on the other screen, so while a display is connected Porthole shows a waiting screen there between games.
- `app/Sources/Core/ExternalDisplay.swift` owns that window and the view the game goes in (`container`).
- `GameSurfaceView.attach` (`app/Sources/UI/SessionView.swift`) puts `MetalHostView.shared` in that container instead of the phone window, fitted to the guest desktop, and keeps the HUD
  on the phone. Touch mapping is unchanged: the phone screen is the touch surface, mapped to the same fitted rectangle (like a trackpad).
- A Steam (desktop) session draws into Wine's compositor; patch 0103 adds `winios_set_compositor_container` so the compositor follows to the other window.
- Unplugging mid-game puts the picture back on the phone (`[display] the game is back on this screen`).

## Not verified on a device with a display
Written and built, run only far enough to check that the app still starts with the scene declared. Things to look at first:
- the picture and its aspect on the display, and whether it is sharp (resolution of the guest desktop versus the display);
- touch mapping on the phone (a drag moves the pointer in proportion);
- AirPlay latency (a cable is best), and the frame rate the display allows (a TV may cap at 60);
- the controller pointer arrow is still drawn on the phone, not on the display;
- plugging in and unplugging during a game, and starting a game with the display already connected;
- with the setting off, the display mirrors again after reconnecting.

## AirPlay is a mirror, not a second screen (found on a device, 2026-10-11)
With AirPlay Screen Mirroring on an iPhone, iOS gives the app one screen and one scene (log: `1 screen(s)`, `1 scene(s) [Application]`, `captured=true`, `audio-out=[AirPlay]`), even with
the external-display role declared the way Amethyst declares it (0.50.215: manifest entry with a delegate class, answered by `PortholeAppDelegate`; the delegate was never called). So the
external-display path above only runs for a cable (USB-C or Lightning to HDMI), which is a real attached display. Not verified with a cable yet.

Tried and removed (0.50.214, taken out in 0.50.216): moving the HUD's layer into the canvas of a secure text field so a mirror leaves the controls out. It fought UIKit over the view
order (the log showed "raised above a view added after it" every half second), hid the controls on the device too, and left them untouchable after mirroring was toggled. A mirror copies
the device's screen, so "game on the TV, only controls on the phone" cannot be done over AirPlay mirroring.

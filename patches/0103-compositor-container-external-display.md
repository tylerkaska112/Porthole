# 0103 The compositor can live in the window of an external display

`app/Runtime/Winios/Winios.m`, `Winios.h`: new `winios_set_compositor_container(void *uiview)`. The compositor view (the desktop of a Steam/Dock session, or the transparent overlay of a game
session) was always added to the app's key window. With a container set it is added to that view instead, and one that already exists is moved there; `NULL` puts it back in the key window.

Why: AirPlay and cable displays. `app/Sources/Core/ExternalDisplay.swift` puts the game's picture in a window on the other screen and keeps the controls on the phone; a Steam game's picture
is in the compositor, so the compositor has to follow.

`tools/vendor_glue.sh` applies it with the other patches. Not verified on a device with a display.

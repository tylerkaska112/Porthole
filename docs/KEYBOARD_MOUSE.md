# Keyboard, mouse and trackpad in games

A Bluetooth or USB keyboard and a mouse or trackpad (iPad) reach Windows programs as real key and mouse events: every key with its own press
and release, the modifiers as keys (left and right), five mouse buttons and the wheel. The code is `app/Sources/Core/HardwareInput.swift`, ported from
Madeira's own `HardwareInput.swift` (see Madeira's `docs/KEYBOARD_MOUSE.md`, which this page follows; the driver side — scan codes, the extended-key bit,
the cursor reports — is Madeira's and unchanged). Added in 1.2.123; nothing here has run on a device yet.

## What a person gets

* **Keyboard:** typing, held keys (W A S D with Shift), arrows, function keys, the keypad. Command is the Windows key; Command-V pastes the iPad's clipboard text
  into the game's text field (one character every 10 ms).
* **Mouse in menus:** the game's own cursor follows the pointer. The iPad's pointer is hidden over the game; what shows is the game's cursor image.
* **Mouse look:** a game that hides its cursor gets the mouse's movement (relative) and the pointer is locked to the game, so the camera keeps turning at the screen
  edges. The lock is let go when the game shows its cursor again.
* **Buttons:** left, right, middle, back and forward; the wheel (also sideways).
* **Two keys Porthole keeps** (not sent to the game): **F10** opens Porthole's in-game menu and **Ctrl+Alt+P** locks or frees the pointer. Both can be changed under Settings > Engine options > Keyboard and mouse > Keys for Porthole (tap, press the key); **Ctrl+Alt+M** and **Ctrl+Alt+P** always work as well. The menu also opens from the touch handle on the right edge, and a controller's chord, as before.
* The on-screen controls step aside while a keyboard or mouse is being used; a touch on the screen brings them back until the next key or mouse movement.

Outside a game the keyboard moves around Porthole's own screens as before (arrows, Return/Space, Esc/Backspace, the brackets for sections); while the in-game menu is
open it does the same, and the game sees nothing.

## Where input goes

Input reaches the game only while it has focus, so typing into Porthole's own text fields never types into the game:

* **Always:** a game is running, the app is active, the game view is on screen, the in-game menu is closed and nothing is presented over it (a sheet, an alert).
* **Keyboard:** no other text field has the keyboard.
* **Mouse:** the pointer is over the game view, or the pointer is locked, or a button that went down on the game view is still held.
* Losing focus releases everything the game was told is held (a key-up for each key, a button-up for each button). A key pressed while the game did not have focus stays
  away from it until it is let go.
* While a hardware keyboard is connected the on-screen keyboard's text bridge ignores typed text (the same presses already arrived).

## Settings (Settings > Engine options > Keyboard and mouse; also `env.` lines in a game's own settings)

| Switch | Default | Effect |
| --- | --- | --- |
| `MADEIRA_HWINPUT` | on | `0`: no keyboard or mouse in games (restart the app). |
| `PORTHOLE_MOUSE_SPEED` | 1 | Multiplier on the mouse's movement while the game reads it relatively. Applies at once. |
| `PORTHOLE_MOUSE_LOOK` | off | `1`: the mouse always moves the camera (relative) and locks the pointer, for a game that never hides its cursor. Applies at once. |
| `MADEIRA_POINTER_LOCK` | on | `0`: never lock the pointer; no chord. |
| `MADEIRA_POINTER_AUTOLOCK` | on | `0`: lock only by hand (Ctrl+Alt+P). |
| `MADEIRA_INPUT_FOCUS` | on | `0`: input reaches the game whatever is in front of it. |
| `MADEIRA_DIRECT_CURSOR` | on | `0`: no cursor drawn on the game, motion stays relative. |
| `MADEIRA_POINTER_ABSOLUTE` | on | `0`: all motion is relative. |
| `MADEIRA_POINTER_HIDDEN_ABSOLUTE` | off | `1`: the cursor follows the pointer even while the game hides it (a game that draws its own cursor). |
| `MADEIRA_MOUSE_ROUTING` | on | `0`: the older desktop cursor routing (restart). |
| `PORTHOLE_HIDE_TOUCH_ON_KEYS` | on | `0`: the on-screen controls stay while a keyboard or mouse is used. |
| `PORTHOLE_INPUT_DIAGNOSTICS` | off | `1`: more `[hwinput]` lines. |

## iPad and iPhone

* **iPad:** a mouse needs nothing special. If a primary click arrives as a finger tap, turn AssistiveTouch off (Settings > Accessibility > Touch > AssistiveTouch) and
  restart Porthole.
* **iPhone:** a pointer only reaches the app through AssistiveTouch (Settings > Accessibility > Touch > AssistiveTouch > Devices). A click then also arrives as a
  touch at AssistiveTouch's cursor; while the mouse is moving such touches are dropped. iPhone has no pointer lock.
* An external keyboard is the same on both.

## Logs

`[hwinput]` lines in the log (Settings > Help and about > export): the switches, the keyboard and mouse found, which path carries the mouse (`gcmouse` or `uikit`),
focus changes, the game showing or hiding its cursor, pointer lock changes (`actual=1` is iPadOS confirming the lock), unmapped keys. With "Log keyboard and mouse
details": every route change, the first raw movements, button samples every 10 s and the rate input arrives at.

## Tests

`app/Tests/HardwareInput/run.sh` compiles the pure part of `HardwareInput.swift` (key map, button edges, held-key diffing, focus gate, wheel, motion carry, pointer route,
automatic lock) on the Mac. Madeira's own `tests/host/check-hardware-input.py` also checks every key's scan code through Wine's layout and the driver; it needs the wine
sources, which this repository does not carry. Device checklist: `docs/DEVICE_CHECKLIST_1.2.0.md`, "Keyboard and mouse".

## Added in 1.2.128

* **Scrolling in the app:** the wheel scrolls Home's shelf of games sideways and a press-and-drag scrolls shelves and lists (`PointerScroll.swift`). Scroll direction: `PORTHOLE_SCROLL_DIRECTION = reversed` (games and the shelf; lists that scroll up and down follow iPadOS's own Natural Scrolling setting).
* **Key repeat** (`PORTHOLE_KEY_REPEAT`: empty = Backspace, Delete, arrows, Home, End, Page Up/Down; `all`; `off`): the key held last repeats after 0.45 s every 33 ms, sent as a key-down without an up, which Windows marks as a repeat.
* **Keyboard layout** (`PORTHOLE_KEY_LAYOUT = letters`): sends the letter a key really types, learned from UIKit's presses; the first press of a key is still the US one.
* **Per game:** Game page > Engine > Keyboard and mouse: Mouse speed, Always use the mouse to look (stored as `PORTHOLE_MOUSE_SPEED` / `PORTHOLE_MOUSE_LOOK` lines in the game's config).
* **Mouse on Home:** right-click a game for Play / Details / ...; a double-click plays, a single click opens (after 0.3 s, only while a mouse is connected).

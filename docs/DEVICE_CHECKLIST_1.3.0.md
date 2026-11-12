# Device checklist for 1.3.0

Built in the 1.3.x private builds (1.3.1 to 1.3.141). Items marked **(device-tested)** were tried on a device and the note says by whom; everything else was written and built but never run on a device
by whoever wrote it. Go through the list on a real device before the public build, with Settings > Advanced > Diagnostics logging on, and keep the log of any step that does not do what it says.
"Log" means a line in the exported Porthole log. Use a fresh install (not an update over a private build) for the first-run items.

## First run and updating
- [ ] Install over public 1.2.1 (688) and open: the app keeps its games and settings; the compatibility badges start at "Not yet tested" (engine changed).
- [ ] Fresh install: the setup guide's Full speed page offers "Use LocalDevVPN" and "Allow Porthole's own private link"; choosing LocalDevVPN finishes the step.
- [ ] A copy signed without the Increased Memory Limit permission shows the "No extra memory" chip on a game's launch screen, and the message after a run that ended on memory warnings.
- [ ] Update check: with the public build, Settings shows no update (porthole-stable is behind); the in-app update from 1.3.0 to a later build downloads and installs (not tested before).

## Upscaling and frame generation (Lossless Scaling needs your own copy on Steam)
- [ ] Stores > Software > Lossless Scaling: with an account that owns it, "Set up" works; with one that does not, it says so and nothing is installed.
- [ ] Upscaling (MetalFX), game setting: 1.5x, 2x, 3x and To the screen in a Direct3D 11 game and a Direct3D 12 game; the picture is bigger and sharp; a game already at the screen's size is not enlarged.
- [ ] In-game menu Upscaling card: Off / To the screen / 1.5x / 2x changes the picture at once, no restart. Launchers and helper windows are never upscaled.
- [ ] LS1 and LS1 performance upscalers with a sharpness setting: Direct3D 11 and 12.
- [ ] Frame generation on and off in the in-game menu for a Direct3D 11 game and a Direct3D 12 game; the game does not stall for long when it is switched on (first shaders take seconds). Games with an sRGB back buffer (Unity) do not flicker.
- [ ] Upscaling together with frame generation.

## Steam
- [ ] Steam Cloud card on a Steam-installed game: the list of files to upload / download / changed on both sides is right; Upload and Download move only what they say; a save changed on both sides is untouched. (Factorio upload and layout were confirmed in 1.3.2-1.3.3; the round trip to the phone was being retested.)
- [ ] Offline play row on a Steam game: Ready after an offline sign-in; a start with no network works.
- [ ] A Steam download with a blocked depot (error 40) installs the rest and logs which depot was left out. PAYDAY 3 (numbered launch entries) starts.
- [ ] Download to an external drive: Download asks "this device or the SSD"; exFAT works, FAT32 is explained; the speed test shows numbers; a slow thumb drive keeps up without freezing the app.
- [ ] A game on the SSD starts (no "drive mapping already in use", no "cannot find the program").

## Games and the engine
- [ ] A game that needs AVX: after a bad run Home ASKS (Apply / x) and the game is unchanged until Apply; after Apply Home shows the change with Undo, and the next good run says the fix worked. The x leaves the game alone and the same fix does not come back; Settings > Compatibility reports > What was changed lists both and can still Apply a declined one.
- [ ] Settings > Compatibility reports > "Ask me before changing a game" off: the next found fix is made at once and shown with Undo (as in earlier 1.3 builds).
- [ ] Mouse wheel in a game: one click is one notch, slow clicks count, a fast turn counts every click, the direction follows the system's natural scrolling. Scrolling outside a game does not crash.
- [ ] Enable JIT with StikDebug 2.x (App Store) and 3.x.
- [ ] Supermarket Simulator on a 6 GB iPad: loading a save no longer closes the app.
- [ ] Grand Theft Auto V (Legacy and Enhanced) and Black Ops Cold War: record how far they get. Not expected to work; only the log is wanted.
- [ ] BeamNG.drive: starts its x64 build.
- [ ] A .NET single-file program (the Memoria patcher run against a real FF9 folder with `FF9_Launcher.exe` in it): runs to the end, FF9's folder gets Memoria.ini and the patched files. (The patcher ran to the end against a stand-in folder on 2026-11-10; the real run and FF9 itself are untested.)

## Controller and on-screen controls
- [ ] On-screen controller: switch it on, play with each of the six layouts and four controller types; it stays clear of the menu's swipe and the screen's edge; a second start in the same session still reaches the game.
- [ ] In-game menu > Controls > Hide when not touched (try 5 seconds): the built-in controls, a custom layout and the game controller all hide five seconds after the last touch anywhere and come back with a touch; they stay while a finger rests on a stick; opening the menu or the controls editor shows them and the clock restarts when it closes; Never switches it off.
- [ ] In-game menu > Controls > Sticks > Floating sticks on: the built-in movement stick (mouse and keys, and first person), a custom layout's stick and the game controller's two sticks each put their base under the thumb where it lands (near their place, not on a neighbouring button), keep it inside the screen's safe area, and go back to their own place when the thumb lifts; W A S D and the pad's axes follow the thumb from where it landed; off again restores the fixed sticks; while editing a custom layout the sticks do not float.
- [ ] Offer to switch to touch controls: turn the game controller on in a game that has no controller support (Terraria, Factorio) with no real controller connected: after about 20 seconds without a controller read a card asks to switch; Switch turns the game controller off and shows the touch controls; Not now (or waiting 25 seconds) leaves everything; neither shows the card again for that game; a game that does read the controller (a controller game) never gets the card; turning the controller on late in a run does not show the card at once.
- [ ] Mixed layouts: in a game's controls editor choose Presets > Gamepad layout: all 13 controls appear; the sticks, D-pad, A B X Y, bumpers and triggers each move the game's controller (test in a game with controller support, e.g. a platformer: stick = walk, A = jump); a quick tap on A is seen by the game; Latch on a button makes it a toggle; add a key (E) and a mouse button next to them and use both together; delete the pad controls again and the game no longer sees a controller; the game controller (Controls > Game controller) and the layout's pad controls can be on together; a stick or the D-pad can be changed to another one in its "Stick or D-pad" picker.
- [ ] Touch pointer > Trackpad (in a point-and-click or strategy game, and in a desktop-style program): sliding a finger moves the game's cursor by the finger's travel and the cursor is visible; a tap clicks at the cursor; tap then touch-and-slide drags (selection box, moving a window); a double tap makes a double click; a two-finger tap is a right click; two fingers sliding scroll (content follows the fingers); the cursor stops at the picture's edge; Slow, Normal and Fast change the speed; Direct goes back to the finger being the cursor; first-person look and the on-screen controls still work in Trackpad; Right mode swaps the buttons.
- [ ] Full keyboard (in-game menu > Controls > Full keyboard, and a Keys button added in the controls editor): the keyboard opens over the lower part of the screen without covering the whole picture; letters, numbers, F1-F12, arrows, Tab, Esc, Enter, Space and Backspace reach the game (try typing in a console or a launcher's text box, and hotkeys in a strategy game); Shift, Ctrl and Alt: one tap holds for the next key only (yellow), two quick taps lock (green), a tap on a locked one lets go; Ctrl+C-style combinations work; Fewer keys hides the function row and remembers it; two keys can be held at once (W and Space); closing the keyboard, the menu or ending the game lets go of every key; the keyboard does not take touches meant for the game outside it.
- [ ] Controls editor > Options: Controls opacity (100/80/60/40 percent) makes the controls fainter when playing and the editor still shows them fully; Tap feedback off stops the light tap on keys, mouse buttons and the gamepad buttons; with a key control selected, Bring to front / Send to back change which of two overlapping controls is on top; Combo: also hold Shift (or Ctrl, Alt) on a Space or C button makes the game see Shift+Space / Ctrl+C (try it as a tap, a hold and a latch); closing and reopening the game keeps all of it; a layout without these options looks and behaves as before.
- [ ] Epic prerequisites: on an installed Unreal Engine Epic game, the game's page shows "Install the game's prerequisites"; tapping it runs UE4PrereqSetup_x64.exe on the desktop, it finishes (or you end it), the page then says "Run the game's prerequisites again", and the game still starts afterwards; a game without a prerequisite installer shows no such row; nothing runs by itself when a game launches.
- [ ] Vulkan (opt-in): a Direct3D 11 game with the engine line d3d11 = dxvk starts and draws (the log has [vulkan] lines, DXVK is loaded instead of DXMT); a Direct3D 12 game with d3d12 = vkd3d does the same; turning the lines off again returns to the normal route; a game with neither line set runs as before and finds no vulkan-1.dll; the app installs and starts as before (the IPA is about 7 MB bigger).
- [ ] Vulkan with KosmicKrisp: the same game with vulkan = kosmickrisp and d3d11 = dxvk (or d3d12 = vkd3d) starts and draws, or the log says why not; compare with vulkan = moltenvk; with neither Vulkan line set nothing changes.
- [ ] Benchmark line: end any run; the log has one [benchmark] line with the game, build, engine, seconds, fps average and lows, peak app and GPU memory, heat and the graphics choices; a run that drew nothing writes none.
- [ ] Graphics route picker: a game's page > Engine > Graphics route shows three rows on Default; choosing DXVK for a Direct3D 11 game (or vkd3d-proton for Direct3D 12, or KosmicKrisp as the library) is logged as [engine] graphics route for this game and shows in the [benchmark] line; Default again returns to the normal route.
- [ ] Controls editor Options: Lock positions and sizes stops moving, resizing and deleting (selecting and changing a control's settings still work) and unlocking restores it; a selected key or mouse button takes a Shape and a Colour and keeps them after closing and reopening the game; sticks and gamepad buttons show no Shape or Colour entries.
- [ ] Last time card: after a heavy game's run it says how much memory it used; after a run iOS ended it adds what helps (close other apps, keep swap on, lower the game's quality); a light game says nothing about memory.
- [ ] A hardware controller stops answering after Control Center or the app switcher: it answers again.

## Stores, Software and Blender
- [ ] Stores > Software lists Blender; download, start, update, remove; its page offers a GPU kernel pack only for a device with that GPU and iOS version; Blender starts and its 3D view has touch controls (two fingers pan, pinch zooms, three orbit).
- [ ] Settings > Sound > Keep other apps' sound playing: music in another app keeps playing next to a game.
- [ ] In-game menu (held sideways, a small phone and a big one): the tabs line up with one-line labels; the chosen choice is tinted; the Processor card opens its explanation when tapped and its tile is not mistaken for a choice button; with the launch screen's "Back to launch screen" button showing (looking at Steam's window), opening the menu moves the button left of the panel and it still works; closing the menu puts it back in the middle.
- [ ] Hide stores: long-press a store card > Hide (the card goes, the store switcher and All games lose it, a "N hidden" line with Show appears); Settings > Stores > Show on the Stores tab shows it again; hiding every store says so instead of showing an empty page; a running download of a hidden store still shows in Downloads.
- [ ] Stores page: the store icons have their own row; the All / Installed / Controller choice is remembered per store; held upright the buttons wrap.
- [ ] Home: shelf, grid and list; a game without a picture has a stable colour and letter.

## Help, reports and the website
- [ ] "What does this mean?" under an error opens portholehq.site/docs at the right entry (the documentation must be rebuilt for 1.3.0 first); "Read more online" in a setting's (i) pop-up.
- [ ] A game's "Last time" card, and "Share this game's log" (the share sheet gets the game's own log with the install facts on top).
- [ ] A compatibility report and a problem report from a game's page carry the game's own logs and go to the public Hub address; send one from the public-style (tester) build.

## Decisions (settled 2026-11-10)
- Name: **Full Sail**.
- The Settings > Steam "File picker test" and the in-game "Always generate" / "Measure only" switches were removed in 1.3.142.
- `UISupportsDocumentBrowser` stays in Info.plist.
- Lossless Scaling ships as it is.

## Added after the code review (1.3.146)
- [ ] Steam Cloud: change a save on the phone AND on another device (different content), then start the game through Steam: the phone's file stays as it is, the log says "changed here and in the cloud since the last sync; left alone", and the Cloud page lists it as changed on both sides.
- [ ] Settings after the declutter: Game settings > Sound shows only Keep other apps' sound playing and Game volume until Advanced > Show technical options is on (then Sound fixes appears); JIT and connection has one VPN and cellular options row that opens the three old groups (the settings in them still work); Updates has an Older versions row whose list opens a build's notes and installs/downgrades as before; Help and about > Licences and credits lists the six credits; Settings search for "cellular" and "audio buffer" lands on the right page.
- [ ] Settings reorganised (1.3.170): every one of the 17 pages opens from the list and from search (Display, Performance, Sound, Controls, Stores, Saves, Storage, JIT and connection, Appearance, Updates, Signing, Advanced, Compatibility reports, Fixing problems, Setup guide and tips, About and credits, Report a problem); Back works on the phone layout and inside VPN and cellular options, Older versions and a store's page; the Controls page shows Controller, Keyboard and mouse and Touch screen, with Controller fixes and Keyboard and mouse fixes only after Show technical options is on; a changed row there (mouse speed, rumble) shows the same value in Advanced > Engine options; Test controller rumble buzzes; the Home update notice, the setup guide cards and Stores > Show hidden open the right pages.

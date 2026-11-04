# Device checklist for 1.2.0

Everything below was written and built in the 1.2.x private builds but never run on a device by whoever wrote it. Go through it on a real device before the public build, with
Settings > Advanced > Diagnostics logging on, and keep the log of any step that does not do what it says. "Log" means a line in the exported Porthole log.

## First run and look
- [ ] Setup guide: the three step cards, the circles with a check on finished steps, "Add your games" as one list of stores. Windows components page lists Visual C++ (64-bit), 32-bit Visual C++, .NET and Wine Gecko.
- [ ] Home: the shelf, the lit game, "1 of N", tiles ease in, the picture behind slowly zooms (off with Reduce Motion). Tap a tile: the game page opens.
- [ ] Top bar: the line under the chosen section slides when you change section; the content fades in; with a controller, the glow starts where it should (Home first game, Stores Steam, Reports first report, Settings Play).
- [ ] Game page (library game): picture card, chips, Play, three tiles. Sideways: two panes, back button in the left pane.
- [ ] Launch screen: porthole ring fills, "Step n of m", elapsed time, Show all steps. Make a launch fail (airplane mode before a Steam game): the card stays until Close, Copy the message works.
- [ ] Stores page: cards per store with account, counts, a download bar; All games; Downloads. Store grids: round status icons, a ring with percent while downloading.
- [ ] Steam and Epic game pages: picture card, number tiles, progress bar, two panes sideways. GOG, itch.io, Amazon and EA open the new sheet (Done, Install gradient button).
- [ ] Settings: every page has the icon header; nested pages (Advanced > Engine options > a group) show ONE Back button; search finds "Game volume", "Gecko", "32-bit".
- [ ] In-game performance overlay: big FPS, graph, grid of numbers; all numbers you turned on stay (none vanish); Tiny size; one-line mode.

## Downloads and runtimes (each needs the network)
- [ ] 32-bit Visual C++ (about 14 MB): download from Settings > Advanced > Windows components. Log: `[vcredist] ...`. Start a 32-bit game: log `[WineProc] Symlinked N MS VC++ x86 runtime DLLs`.
- [ ] Wine Gecko (about 110 MB): download. Log: `[wine-gecko] ...` and, at the next start, `[wine-gecko] Wine's download cache has wine-gecko-2.47.4-x86.msi`. Start a program that shows a web page: no "Wine Gecko Installer" window.
- [ ] .NET (Wine Mono): a .NET Framework game (Celeste) offers the download first and then starts.

## Games
- [ ] Final Fantasy Resonance (demo and full): reaches the game; log shows `[exe-window] ... widened`.
- [ ] Any game started from a batch file or from the top of drive C: log shows `[exe-window] not measured`.
- [ ] Red Dead Redemption 2: reaches the Rockstar launcher and the game (known: activation error on later starts).
- [ ] Black Ops III: record whether it starts (unconfirmed).
- [ ] Steam demos/betas show in the Steam library with a label.
- [ ] Madeira's tested setup button on a game that has one; Undo works. Share a game's setup as text and apply it.
- [ ] Gyro aim / turbo on a game with a controller or the device's gyro.
- [ ] Donor memory 4 GB on a memory-hungry game: log `donor` lines; the game gets past the old limit.
- [ ] Audio: Game volume 150% is audibly louder at the next start; take a call or ask Siri during a game with "Bring sound back after a call" on: the sound returns (log `[audio] interruption began / ended`).

## Stores
- [ ] EA app: sign in, install, Play, pause/resume, update, repair, uninstall (nothing here has run).
- [ ] GOG: a game installed from GOG's own builds that uses the Galaxy SDK: log `[galaxy] ...` lines (request names only) and its achievements update. An older install: `[galaxy] Galaxy client read for id=...` at the first start, working at the second. Settings > Stores > GOG > GOG Galaxy services off: `[galaxy] off for this play`.
- [ ] itch.io: a game that ships as .7z installs.
- [ ] Steam: sign-in does not drop; a download shows the two sizes and the smooth bar; speed near the connection's.

## Connection
- [ ] VPN paused for JIT comes back after the game starts (needs the shortcut); a failed launch keeps its message on screen.
- [ ] Cellular data: after a launch with the shortcuts, Home no longer says "Cellular data is off" once it is on again (also on Wi-Fi). If it sticks, export the log: the `[cellular]` lines print the network the device reports.

## Reports (needs the updated Hub)
- [ ] Send a report from a game: the sheet says the log is private and shows its size. In the Launcher's Reviews > Reports it waits, the log can be read, approve shows it in Reports; reject hides it. My reports shows "waiting".
- [ ] A report is not listed or counted before approval.

## Keyboard and mouse (iPad, wireless keyboard and wired mouse)
- [ ] Connect both before starting a game: the log has `[hwinput] keyboard connected` and `[hwinput] mouse connected`, and `mouse path: gcmouse`.
- [ ] Typing in a game's text field (the Rockstar launcher's sign-in, a Steam page): letters, capitals with Shift, digits, symbols, Backspace, Tab, arrows, Return. Nothing typed twice.
- [ ] A game with WASD and a mouse look (a first-person game): keys held, Shift and Ctrl work, the camera turns with the mouse, does not stop at the screen edge, the pointer locks (`system pointer lock ... actual=1`).
- [ ] A game menu: the game's own cursor follows the mouse, clicks land where the cursor is, right and middle buttons, the wheel scrolls.
- [ ] Ctrl+Alt+P frees and locks the pointer; Ctrl+Alt+M opens Porthole's menu and the arrows/Return move around it; Esc or Back closes it and the game gets keys again.
- [ ] Click Porthole's own buttons with the mouse (the menu handle): the game gets no click. Type in a Porthole text field (the report sheet) with the game running behind: the game gets no keys.
- [ ] Hold a key, then swipe away to another app: the key is released (the game does not keep running forward).
- [ ] The on-screen controls step aside once a key or the mouse is used and come back on a touch.
- [ ] Mouse speed in Settings > Engine options > Keyboard and mouse changes the camera speed at once.
- [ ] Outside a game: arrows, Return and Esc still move around Porthole's screens.
- [ ] Home: the mouse wheel scrolls the shelf of games sideways; press-and-drag scrolls it; a library longer than the screen can be reached to the last game. Reversed scroll direction flips both and the wheel in a game.
- [ ] F10 opens Porthole's menu in a game (and is not seen by the game); change it under Keys for Porthole to another key and a combination; Ctrl+Alt+M still works; the hint shows in the first games.
- [ ] Hold Backspace in a Windows text box: it repeats after half a second. Hold an arrow in a game: no side effect.
- [ ] Double-click a game tile plays it, a single click opens its page, right-click shows Play / Details.
- [ ] Not full screen (Split View): the notice says the pointer cannot be locked.
- [ ] A game page's Engine > Keyboard and mouse: its own Mouse speed changes the camera at once.

## Not for the public
- Steam Big Picture (hidden: seven taps on the version in Settings > Help and about): its web helper has crashed on the first click. Leave it off.

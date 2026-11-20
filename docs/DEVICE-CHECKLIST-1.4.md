# Device checklist for 1.4.x (what has only been checked in the harness)

None of this has run in the real app: it cannot start in the simulator (StikJIT is device-only). The logic is covered by the scripts in `app/Tests` (all pass), and the screens by the UIPreview harness. Test on the iPad and the iPhone. When something is wrong, send **Settings > Advanced > the log** and say which step.

Tick as you go. "Expect" is what should happen.

## 1. First-run setup (needs a fresh install, or Settings > Setup, tutorials and tips > Run setup again)
- [ ] Welcome > Controls > Look > Power > Helpers > Speed > ... > Done all open, and Back works on each.
- [ ] A choice on Look or Power is already applied in Settings (open the same row there: same value).
- [ ] "Just the essentials" on Welcome jumps to Speed. "Your choices" on the last page jumps back.
- [ ] Quit mid-setup and reopen: it resumes on the page you left (a build before 1.4.81 restarts at Welcome, once).

## 2. Tutorials (Settings > Setup, tutorials and tips)
For each: start it, tap the highlighted thing, and watch it move on.
- [ ] The ring sits on the real button (iPad portrait, iPad landscape, iPhone landscape). If it is off, send a screenshot and the `[coach] ... at x y w h` line.
- [ ] Tapping the highlighted button works and advances. Tapping elsewhere does nothing.
- [ ] A step that needs another tab switches to it by itself.
- [ ] "I can't find this" never shows. If it does, send the `[coach] <tutorial> step <id>` line: that id is wrong.
- [ ] When a tutorial ends you land on the tutorials page.
- [ ] Add a game, store sign-in, swap, controls, saves, JIT: each walks through to the end.
- [ ] Start any game for the first time: it offers the in-game menu tour once. The tour points at the real menu tabs and the swipe step works over the game's picture.
- [ ] The tutorial overlay never takes the game's picture away (no black screen, no lost sound).

## 3. In-game menu on iPad
- [ ] Opens as a floating card. Big Close button closes it. Tapping outside closes it.
- [ ] Pill tabs switch pages, rows are easy to hit.
- [ ] Drag the handle to resize; dragging well past the smallest size closes it; the width is remembered next time.
- [ ] iPad portrait too: the card never goes off screen.
- [ ] iPhone menu looks the same as before.

## 4. Discord: reading
- [ ] Channels you cannot see are hidden; ones you can see are all there. **A server must never show zero channels.** If one does, send the log.
- [ ] Servers are in the same order as in Discord's app, folders respected.
- [ ] Forum channel: posts list, open one, read replies.
- [ ] Threads show under their channel.
- [ ] Direct messages list with unread counts. Tap a name or picture: profile card; Message and Call buttons work.
- [ ] Scroll to the top: "Load earlier" fetches older messages without jumping.
- [ ] Embeds, link previews, stickers show; tapping a picture opens the viewer (pinch to zoom, close). Day lines show between days. Tapping a reply jumps to the message it answers.

## 5. Discord: writing
- [ ] Send a message, reply, edit your own, delete your own (not someone else's).
- [ ] React and un-react: the count changes once, not twice (echo from Discord must not double it).
- [ ] Someone typing shows a "typing" line that disappears.

## 6. Discord: notices
- [ ] On the Games page (no game running) a message in a DM shows a banner at the top; tapping it opens that chat.
- [ ] The Social tab shows a count that goes down as you read. A muted channel does not count.
- [ ] While you are looking at that chat, no banner for it.
- [ ] In a game the old overlay notice still works.

## 7. Discord: activity (off by default; Settings > Discord > Activity)
- [ ] Turning it on asks once.
- [ ] Browsing the library, stores, reports, settings, a download: the matching line shows in Discord.
- [ ] In a game: "<Game> on Porthole". It goes when the game ends or you turn the setting off.

## 8. Discord: voice
- [ ] Push to talk: with it on, you are silent until you hold the talk button (HUD and in-game menu); with it off, normal.
- [ ] Mute and deafen still work with push to talk on.
- [ ] Reduce echo (experimental): with speakers on, others do not hear themselves back as much; you can still be heard. The log says how many frames were held back.
- [ ] A person using Go Live shows a red LIVE mark on their tile and in the channel list.

## 9. Everything else once
- [ ] Controller still navigates the app (tutorials do not handle a controller yet: use touch).
- [ ] A game still starts, plays, and the menu opens during it.
- [ ] No crash when switching tabs fast, rotating the iPad, or opening Social while a banner is showing.

## Log lines worth sending
- `[coach] started <id>` / `[coach] <id> step <step>: <anchor> at x y w h, screen WxH`
- `[discord] connected: N friend(s)`, `[discord] server order: ...`, `[discord] the forum search was refused ...`
- `[discord] disconnected (code N)`

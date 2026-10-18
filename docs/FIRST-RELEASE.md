# First public release: preparation (nothing here is published)

Written 2026-10-10. This is the list of what has to be true before the first release goes on the PortHole GitHub repository. Nothing has
been published: the repository holds only the README and the licence files, the website redesign sits on an unpushed branch, and no
public IPA exists.

## Proposed version
- **1.0.0**, build **480** (decided 2026-10-15; the Hub's last build before it was 479). The version policy so far was "0.50.x until the first public release", and the first
  public release is what 1.0.0 is for. Decide this number before building; once a tag is public it should not move.
- File names: `Porthole-1.0.0-480.ipa` and `Porthole-1.0.0-480.ipa.sha256`.

## Release notes (draft)
**Porthole 1.0.0: first public release**

Windows PC games on your iPhone and iPad. Early and unfinished: plenty of games don't run yet.

- **A shelf that feels like a console.** Home shows your games on one row; with a controller the chosen game grows and the rest step back.
- **Built for a controller.** The whole app can be used with one. Games Steam lists with controller support show a FULL or PARTIAL badge,
  and a tap on it explains what it means.
- **Your games.** Copy a game folder in from Files, run a Windows installer, or sign in to Steam and download the games you own.
  Installed Steam games can be added back to the library at any time.
- **Know before you try.** Compatibility badges from reports by other people, and a short report of your own in under a minute.
- **Simple setup.** Three steps: full speed (JIT and a private link), Microsoft's Windows components, your games.
- **Your VPN.** Porthole asks before pausing a VPN you have on, and can turn it back on with a shortcut you make.
- **Updates.** Update from inside the app with your own certificate, or download any version as a file.
- **Look.** A new dark look in the Steam spirit with Porthole's own colours, and an icon that goes from sunset to night in dark mode.

Needs iOS 18 or later and a way to sign the app yourself (see INSTALL). Not affiliated with Valve, Microsoft, Apple or any publisher.

## Update channel (decided 2026-10-15)
The public IPA does **not** update from the maintainer's own build channel. Both talk to the same Hub address, but under different names:

| | Maintainer's builds | Public build |
|---|---|---|
| Name on the Hub (`PORTHOLE_HUB_APP_ID`) | `porthole` (Local.xcconfig) | `porthole-stable` (`PUBLIC_HUB_APP_ID` in `tools/local.env`) |
| Published by | `tools/release.sh` (every build, straight away) | `tools/promote_public.sh` (only a release you chose) |
| Signed for | `porthole` | `porthole-stable` (the signature covers the name) |

- `tools/release_public.sh` builds the IPA with the channel and the release public key compiled in, and `tools/audit_ipa.sh` fails if either is missing.
- `tools/promote_public.sh dist/public/Porthole-<v>-<b>.ipa` signs that exact file for the public channel and puts it on the Hub, then reads `latest.json` back.
  The same file is the one uploaded to GitHub Releases, so the checksum on the Hub and on GitHub is the same.
- Compatibility reports, shared key binds, problem reports and the badge list use the Hub **address** only, not the channel name: they are the same for both.
- Until a build is promoted the public channel answers 404 and the app says no update has been published. Nothing breaks.
- The Launcher's app list is unaffected: a registry entry whose bundle id matches an app it already has is not added again.

## Before publishing: checklist
- [ ] Decide the version and build number above.
- [ ] Build the public IPA from the scrubbed export (`tools/export_public.sh`, `tools/release_public.sh`) so no personal server, id or path is in
      it. Do NOT upload the Hub build (`tools/release.sh`): it carries the private Hub address.
- [ ] Read the audit output `tools/release_public.sh` prints (bundle id, Hub address, update channel `porthole-stable`, release key, no maintainer names).
- [ ] Set `PUBLIC_SOURCE_URL` in `tools/local.env` to the public repository so the IPA's Settings > About > Licences links to the source (it was empty in the 0.50.383 build).
- [ ] `tools/promote_public.sh` the same IPA that is uploaded to GitHub, then check `<hub>/updates/porthole-stable/latest.json`.
- [ ] Licence review still open (see `docs/COMPLIANCE.md`): a lawyer's check, the name of Iridium's creator for `CREDITS.md`, and a clean-machine
      LGPL relink test.
- [ ] Source: the repository must carry the source for what ships (app, patches, the pinned Madeira commit and the build recipes). Publish the
      scrubbed export, not this working repository.
- [ ] Regenerate the website's compatibility snapshot, fill in the Get it page, then merge the `redesign` branch of the site and push.
- [ ] Take screenshots of the real app for the README and the website (the site uses a drawn illustration at the moment).
- [ ] Update the in-app releases link if the repository address changes (`releasesURL` in `SettingsExtras.swift`).
- [ ] Test on a clean device: install, setup guide, a Steam download, a game, an update.

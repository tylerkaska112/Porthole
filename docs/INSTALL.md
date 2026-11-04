# Installing Porthole

Porthole is distributed as an **unsigned IPA** (it cannot be on the App Store). You sign it with your own certificate and install it.
Read [what you need](../README.md#what-you-need) first. Allow about 20 minutes the first time.

## 1. Get the IPA
Download `Porthole-<version>-<build>.ipa` and its `.sha256` from the project's Releases page, and check the fingerprint:

```bash
shasum -a 256 -c Porthole-*.ipa.sha256
```

## 2. Sign and install it
The IPA contains the app and four extensions (the last one is optional, see below). All five need to be signed with a **development** certificate and a provisioning profile that
lists your device and includes these capabilities:

| Part | Bundle id in the IPA | Needs |
|---|---|---|
| Porthole | `site.portholehq.app` | get-task-allow, Increased Memory Limit, Extended Virtual Addressing, Network Extension (packet tunnel), Personal VPN |
| JIT helper (extension) | `site.portholehq.app.jithelper` | a profile for its own App ID |
| Tunnel (extension) | `site.portholehq.app.tunnel` | a profile for its own App ID, Network Extension (packet tunnel) |
| Download card (extension) | `site.portholehq.app.activity` | a profile for its own App ID |
| Donor memory (extension, optional) | `site.portholehq.app.MemoryHost` | a profile for its own App ID |

- Change the bundle ids to ones registered to your own team, **keeping the prefix the same**: if the app becomes `com.example.porthole`, the
  extensions must be `com.example.porthole.jithelper`, `com.example.porthole.tunnel` and `com.example.porthole.activity`. Most signing tools do this for you.
- App IDs must be explicit (not wildcards), and the profile is tied to your devices.
- Use whatever signing tool or service you trust that accepts your own certificate and profiles. Porthole can sign its own later updates
  on the device if you give it the certificate (.p12) and profiles; the files stay in the device's Keychain.
- A paid Apple Developer account or a third-party certificate service can provide every capability Porthole asks for (recommended). A free Apple ID works too but is limited (see "Fewer App IDs" below).
- Development profiles expire (about a year with a paid account). When one does, sign and install again; your games and settings are kept
  as long as the bundle id stays the same.

### Fewer App IDs (optional)

A free Apple account only allows a few App IDs, and the full install uses five. You can leave the extensions out **when you sign**
(delete them from `Payload/Porthole.app/PlugIns/`, or use your signing tool's "remove app extensions" option). It is the same IPA either way:

| Install | App IDs | What you give up |
|---|---|---|
| Complete | 5 | nothing |
| Without `F4MemoryHost.appex` | 4 | Donor memory (Settings, Engine options): extra memory for a game that needs more than the app's own limit. |
| Without `F4Activity.appex` | 4 | The download card with Pause and Cancel buttons on the lock screen and in the Dynamic Island. Downloads show iOS's own progress card instead. |
| Without `F4Tunnel.appex` too | 3 | Porthole's own private link: run **LocalDevVPN** before you press Play. Your own VPN is then never paused. |
| Without `F4Tunnel.appex`, `F4JITHelper.appex`, `F4Activity.appex` and `F4MemoryHost.appex` | 1 | "Porthole turns JIT on by itself": use **StikDebug** (or another tool) to switch JIT on instead. |

You can mix them: each extension is independent, so leave out only the ones you do not want.

Porthole looks at what is inside the install and which permissions the signature really carries, and says so in **Settings, Stores and JIT,
Your install**: if a permission is missing (for example a free account cannot have Increased Memory Limit) it tells you what that costs and
how to fix it. Updating through Porthole or the Launcher keeps the lighter install lighter.

## 3. First start: the setup guide
Open Porthole; the setup guide has three steps, and you can stop at any time:

1. **Full speed.** Games need JIT, and Porthole needs a small private link to switch it on.
   - **JIT.** The automatic method is chosen for you. It needs a *pairing file*: on iOS 27 or later tap *Create it on this device*; on iOS 18 to 26
     make the file once on a computer with a pairing tool such as iloader or Jitterbug (plug the device in, tap Trust, save the pairing file),
     move it to the device and choose it in the guide. *Use a different method* offers StikDebug (Porthole opens it when you press Play) or
     another tool of your own (Porthole waits for it).
   - **The private link.** Porthole makes a small connection inside the device to reach the debug service. iOS calls it a VPN and asks once; it is
     not a real VPN and none of your traffic goes through it. iOS runs one VPN at a time, so if you have your own VPN on, Porthole asks before
     pausing it and can run a shortcut you make (Settings ▸ Stores and JIT ▸ Your own VPN) to turn it back on afterwards.
2. **Windows components.** Download Microsoft's Visual C++ runtime (about 25 MB, from Microsoft).
3. **Games.** Sign in to Steam, Epic Games, GOG or itch.io (Stores tab), and/or import a game folder or installer from the Files app.

You can finish later in Settings ▸ App ▸ Setup guide.

## 4. Updating Porthole
- **By hand:** install the newer IPA the same way you installed this one. Your games and settings are kept as long as the bundle id stays the same.
- **From inside the app:** in Settings ▸ Updates, add your certificate (.p12) and profile and Porthole signs and installs new versions itself.
  Without a certificate the same page lists every version, newest first (five at a time), and *Download* saves the file for you to sign.
  A build that carries its maintainer's release key installs only updates that carry the matching signature, so a tampered update server cannot push code to your device.

## 5. Using a controller
Connect a game controller (Bluetooth) and move around the whole app with it: the left stick or D-pad moves, A selects, B goes back, and the
shoulder buttons switch sections. Steam lists which games support a controller; Porthole shows **FULL** or **PARTIAL** on those games, and
pressing the badge on a game's page explains what it means.

## If something does not work
- Settings ▸ Advanced ▸ Log shows what Porthole is doing. Include it when you ask for help.
- "Waiting for JIT" never ends: JIT is not on. Check the setup guide's Full speed step.
- The connection step fails right after an update: restart the device (iOS can keep stale VPN state after an app update).
- A game closes or never starts: it may need more memory than the device has, or not be supported yet. Compare with the compatibility list at portholehq.site.

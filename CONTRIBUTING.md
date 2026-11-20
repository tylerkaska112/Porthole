# Contributing to Porthole

Thank you for wanting to help. This page explains how a change gets from your idea into a Porthole release, what GitHub does for you along the way, and the few
rules every contribution follows.

**You do not need a Mac.** GitHub checks every pull request and builds an IPA from it that you can install on your own iPhone or iPad.

## Contents
- [Ways to help without writing code](#ways-to-help-without-writing-code)
- [How a contribution goes, start to finish](#how-a-contribution-goes-start-to-finish)
- [Without a Mac](#without-a-mac)
- [What GitHub runs on your pull request](#what-github-runs-on-your-pull-request)
- [With a Mac](#with-a-mac)
- [Where things are](#where-things-are)
- [Writing a test](#writing-a-test)
- [The engine](#the-engine)
- [Pull request checklist](#pull-request-checklist)
- [Rules](#rules)
- [Security problems](#security-problems)
- [Releases](#releases)

## Ways to help without writing code

- **Report how a game runs.** In the app, open the game and send a compatibility report. Approved reports appear on the
  [community list](https://portholehq.site/compat.html) and help everyone pick the right settings.
- **Report a problem from the app.** The "Report a problem" page sends the log with it (cleaned of account names, e-mail addresses and public IP addresses, and you
  can read it first). That is usually more useful than an issue, because the log shows what the engine did.
- **Open an issue** for a bug you can describe: use the *Bug report* form. Say which Porthole version (Settings > About), which device and which iOS version.
- **Try other people's pull requests** on your device and say in the pull request what worked and what did not. Many changes can only be judged on real hardware.
- **Improve the docs.** Everything in `docs/` and the in-app wording can be edited on github.com.

## How a contribution goes, start to finish

1. **For anything bigger than a small fix, talk first.** Open an issue that says what you want to change and why. That avoids work on something that cannot be merged
   (see [Rules](#rules)).
2. **Fork** the repository and make a branch for your change.
3. **Change the files**, on github.com or on your own computer.
4. **Open a pull request** against `main`. Fill in the template: what it changes, and how you tried it.
5. **GitHub runs two workflows**: *Checks* (the tests) and *Build* (an unsigned IPA). See [below](#what-github-runs-on-your-pull-request).
6. **Try the IPA** on a device if your change does something you can see or feel.
7. **Review.** The maintainer reads the change, may ask for changes, and tries it on their own devices.
8. **Merge.** Your change is in `main` and goes out with the next release (see [Releases](#releases)).

## Without a Mac

### Making the change
- **Small edits:** open the file on github.com and press the pencil. GitHub forks the repository and opens a pull request for you.
- **Bigger edits:** press <kbd>.</kbd> on your fork's page to open it in the browser editor (github.dev), or clone your fork on any computer.

### Getting the IPA from your pull request
1. In your pull request, open the **Checks** tab (or the repository's **Actions** tab) and select the **Build** run.
2. When it has finished, scroll to **Artifacts** and download `Porthole-<version>-unsigned`. It is a zip with the IPA inside.
3. Sign and install it like any Porthole IPA: [docs/INSTALL.md](docs/INSTALL.md) explains how, step by step.

The IPA has the same app id as the released Porthole, so installing it replaces your copy. Your games and settings stay. To go back, install the release IPA from
the Releases page again. Artifacts are kept for 14 days; push a new commit, or ask the maintainer to run the workflow again, if yours has expired.

### Your first pull request waits
GitHub holds the workflows of a first-time contributor until the maintainer approves the run. That is a GitHub safety setting, not a judgement of you; after your
first merged pull request your runs start on their own.

## What GitHub runs on your pull request

Both workflows run on GitHub's Mac machines with Xcode. They get **no secrets**: they never sign anything and never publish anything.

| Workflow | What it does | How long |
|---|---|---|
| **Checks** (`.github/workflows/checks.yml`) | Runs `tools/run_tests.sh`: every host test in `app/Tests/` plus the `Packages/LauncherCore` tests. No device, no engine, no network. | a few minutes |
| **Build** (`.github/workflows/build.yml`) | Downloads the prebuilt engine (the *engine pack*), builds the app around it in Release, packages the IPA, audits it, and attaches it to the run. | about 20 minutes |

**If Checks fails**, open the run: the failing test prints the lines that start with `FAIL:`. A test that needs something GitHub's machines do not have reports itself
as *skipped*, not failed.

**If Build stops with "a new engine needs a new pack"**, your change touched the engine id (`app/Config/Engine.xcconfig`). The engine is not built on GitHub; see
[The engine](#the-engine).

## With a Mac

You need a Mac with Apple silicon, Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone --recurse-submodules https://github.com/<you>/PortHole.git
cd PortHole
tools/run_tests.sh                 # every host test (about 2 minutes)
tools/run_tests.sh Nav Steam       # only these app/Tests folders
```

### Building the app yourself
Building the engine from source takes hours ([docs/SOURCE.md](docs/SOURCE.md), [docs/REBUILD.md](docs/REBUILD.md)). For work on the app you can use the same
prebuilt engine pack GitHub uses instead: follow the steps in `.github/workflows/build.yml` by hand.

```bash
id="$(sed -n 's/^PORTHOLE_ENGINE_ID *= *//p' app/Config/Engine.xcconfig | tr -d '[:space:]')"
gh release download "engine-$id" --repo tylerkaska112/PortHole --pattern "engine-pack-$id.tar.gz" --dir engine-pack
(cd engine-pack && shasum -a 256 -c ../docs/ENGINE_PACK.sha256)    # must say OK
tar -xzf "engine-pack/engine-pack-$id.tar.gz" -C app RuntimeStage DaveStage
tmp="$(mktemp -d)"; tar -xzf "engine-pack/engine-pack-$id.tar.gz" -C "$tmp" engine-headers && cp -R "$tmp/engine-headers/." vendor/Madeira/
python3 tools/prepare_stikjit.py
cd app && xcodegen generate && open Porthole.xcodeproj
```

To run it on your own device from Xcode, copy `app/Config/Local.xcconfig.example` to `app/Config/Local.xcconfig` and set your own bundle id (it is optional: without
it the build uses Porthole's own). `app/Config/Local.xcconfig` and `tools/local.env` hold your own identity and machine paths. They are in `.gitignore`; keep them
out of your commits.

## Where things are

| Path | What is there |
|---|---|
| `app/Sources/UI/` | the screens: home, library, game page, settings (`Settings/`), the in-game menu (`InGame/`), the controls editor, Discord (`Discord/`), the setup guide and tutorials |
| `app/Sources/Core/` | logic without screens: controls, auto-fix rules, game fixes, launch options, engine settings, reports, downloads. Most of it has a host test. |
| `app/Sources/Steam/`, `Epic/`, `Gog/`, `Itch/`, `Amazon/`, `EA/` | the store clients: sign-in, library, downloads, launching |
| `app/Sources/Discord/` | the Discord client: gateway, messages, voice, streams |
| `app/Sources/Compat/` | compatibility reports and badges |
| `app/Sources/Pairing/`, `app/Tunnel/`, `app/Helper/` | JIT, the pairing file, the VPN tunnel and the JIT helper extension |
| `app/Tests/<Name>/run.sh` | the host tests, one folder each |
| `Packages/LauncherCore/` | the update client, signer and catalog, with its own `swift test` |
| `patches/` | the engine patches on top of the pinned upstream source ([docs/SOURCE.md](docs/SOURCE.md)) |
| `vendor/Madeira` | the engine source (a submodule) |
| `docs/` | guides, the install guide, engine and settings references |
| `tools/` | build, test, packaging and audit scripts |

## Writing a test

Host tests compile one or a few source files with `swiftc` together with a small `main.swift` and run the result on the Mac. Copy a folder such as
`app/Tests/StickDeadzone/` and change it:

- `run.sh` writes `main.swift`, compiles it with the files under test, and runs it.
- Each check prints `ok:   <what it checks>` or `FAIL: <what it checks>`; the program exits 1 if anything failed.
- A test that cannot run on a machine (it needs something only some Macs have) prints `SKIP: <why>` and exits 77.
- Name each check as a sentence about behaviour ("a full push is still a full push"), so a failure explains itself.

If your change is logic that can run without a device, put it in a type with no UIKit dependency so it can be tested this way.

## The engine

Wine, FEX, DXMT and Madeira are **not built on GitHub**. The Build workflow downloads one prebuilt file, the engine pack, pinned by its SHA-256 in
`docs/ENGINE_PACK.sha256` ([docs/ENGINE_PACK.md](docs/ENGINE_PACK.md)).

- A pull request that does not touch the engine (almost all of them) builds on its own.
- Engine changes need a Mac, the full build ([docs/SOURCE.md](docs/SOURCE.md)) and testing on a device with many games, because one engine change can break
  games that have nothing to do with it. **Open an issue first.** If the change is accepted, it goes in as a patch in `patches/`, and the maintainer builds and
  publishes a new engine pack.
- Never commit built engine files (`app/RuntimeStage`, `app/DaveStage`): they come from the pack.

## Pull request checklist

- [ ] One change per pull request. A fix and a clean-up are two pull requests.
- [ ] `tools/run_tests.sh` passes (the Checks run says the same).
- [ ] A test for new logic when it can run on a Mac.
- [ ] Say what you tried on a device (which device, which iOS version) and what you could not try.
- [ ] Wording in the app is plain and short, the way the rest of the app says things.
- [ ] Nothing personal in the diff, the logs or the screenshots you attach.

## Rules

- **Licence.** Porthole is GPL-3.0-or-later with the exception in `LICENSE-EXCEPTION.md`. By opening a pull request you agree that your contribution is under the
  same terms. Code taken from elsewhere must have a compatible licence, named in `CREDITS.md` (and its notice in `docs/notices/` when the licence asks for one).
- **No games and no Microsoft files.** Do not add game files, Windows system files or Microsoft redistributables; the app downloads those that may be downloaded.
- **No secrets and nothing that identifies anyone.** No keys, tokens, pairing files, passwords, account names, e-mail addresses, server names or your machine's
  paths in code, tests, logs or screenshots.
- **No bypassing licence checks or copy protection** of a game or a store, and no cheats for online games.
- **Settings keep their meaning.** People's saved settings and layouts must keep working after an update. A change to what an existing setting does needs a
  conversation first.
- **Privacy stays as it is.** Porthole has no analytics and no account. A change that sends anything new off the device needs an issue first, and the privacy page
  is updated with it.
- **AI-written code is fine** (much of Porthole is), but you are responsible for it: read it, understand it, test it, and say what you tried.

## Security problems

Do **not** open a public issue for a security problem. Use the repository's **Security** tab > **Report a vulnerability**, which only the maintainer can read.

## Releases

Only the maintainer makes releases. A release is built from `main`, published on the Releases page with its checksum, and offered to installed copies through
the in-app update. Your merged change ships with the next release and appears in its changelog. If you would like to be credited under a name other than your
GitHub account, say so in your pull request.

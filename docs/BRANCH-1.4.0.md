# The 1.4.0 branch

`1.4.0` is the next public version. It began as the `discord` branch (cut from `1.3.0` at 1.3.138 on 2026-11-09) and on 2026-11-12 it took in everything `1.3.0` had since (1.3.139 to the public 1.3.0), after the maintainer decided the Discord features go into the next version. All new work happens here, Discord or not.

* **Fixes to the released 1.3.0** go on `release-1.3.0` (worktree `F4-130-hotfix`, frozen engine, see `docs/HOTFIX.md` on that branch) and are cherry-picked here afterwards.
* **Not released yet.** `release_public.sh`, `promote_public.sh` and `finish_release.sh` refuse to run on this branch; `ALLOW_DISCORD_RELEASE=1` overrides that, and is only to be used when the maintainer says so.
* **Test builds** are numbered like 1.3.N, 1.2.N and 1.1.N were: 1.4.1, 1.4.2 ... on the way to the public 1.4.0, with the build number the public 1.3.0's (870) plus N (1.4.1 is build 871). They go to the debug channel of the private Hub (the Hub app `porthole`, git tags `v<version>`), exactly as the 1.3.N builds did; `tools/release.sh` refuses only the public channel `porthole-stable`. Each build needs its CHANGELOG.json entry first. The old Discord test channel (`porthole-discord`, builds 9001-9044) is no longer used. Build with `F4_DERIVED=<build root>/DD-discord`.
* **The engine** is the 1.3.0 engine plus the two Discord patches (0200 voice bridge, 0201 game audio tap, both in `build/ntdll-unix/audio_null_ios.c`), committed on the engine branch `porthole-1.4.0`
  (engine-r29/vendor-engine, from `porthole-r29`; the engine that shipped in 1.3.0 is the tag `porthole-1.3.0`). The 1.4.0 runtime is `build-root/stage-140`: stage-r29 with its own `libntdll_unix.a`
  (`build-root/ntdll-lib-140/`). Rebuild it with `build/ntdll-unix/build.sh` in the engine tree, copy `app/Madeira/libntdll_unix.a` to `ntdll-lib-140/` and put the engine tree's file back from
  `build-root/backups-1.4.0-engine/` (stage-r29 links to that file; it is what 1.3.0 was built with). The engine is recorded as `2c133ca-r2` (`tools/engine.sh bump`: badges start again).

Where Discord code lives: `app/Sources/Discord/` (and `tools/discord*`). The Discord features stay behind a Settings switch ("Discord features"), off by default.

Warnings that must ship with any Discord feature: it is not an official Discord client; Discord's terms do not allow third-party clients; an account used with it can be limited or banned. Nothing may hide what Porthole is from Discord.

# The engine pack

Porthole's engine (Wine, FEX, DXMT, the Discord libraries and the Windows DLL farms) takes hours to build and is not in git. GitHub's **Build** workflow does not
build it: it downloads one prebuilt file, the **engine pack**, and compiles only the app around it. That is why a build takes minutes.

## What it holds

`engine-pack-<engine id>.tar.gz` (about 200 MB), made by `tools/make_engine_pack.sh` from the maintainer's staged runtime:

| Folder | Content |
|---|---|
| `RuntimeStage/` | Madeira's DLL farms and libraries plus our rebuilt ones (`docs/REBUILD.md` lists them) |
| `DaveStage/` | the Discord libraries (`tools/build_dave.sh`) |
| `engine-headers/` | `app/Madeira/*.h` and `build/*.h` of the shipped engine (the commit `vendor/Madeira` is pinned to), which the C glue includes |

Not in it: Microsoft's Visual C++ DLLs (the app downloads them), StikJIT (the workflow fetches it with `tools/prepare_stikjit.py`, which checks its digest) and anything
that identifies the builder: the maker scrubs the build machine's paths and refuses to finish if any are left. The pack has the same binaries the released IPA carries.

## How a build finds it

* The engine id is in `app/Config/Engine.xcconfig`. The pack for it is a release asset named `engine-pack-<id>.tar.gz` on the release tagged `engine-<id>` of the upstream repository.
* `docs/ENGINE_PACK.sha256` pins its SHA-256. The workflow checks the download against it, so a changed file is refused. The download is cached by that hash.
* A pull request that does not touch the engine (almost all of them) just works. One that changes the engine id needs a new pack: the workflow stops and says so.

## Making a new pack (maintainer)

```bash
tools/stage_runtime.sh ...                         # as for any release; app/RuntimeStage must be this checkout's
F4_BUILD_ROOT=<build folder> tools/make_engine_pack.sh        # writes dist/engine-pack/engine-pack-<id>.tar.gz and its .sha256
```

Then publish it on a release tagged `engine-<id>` (upload the `.tar.gz`) and put the line from its `.sha256` file into `docs/ENGINE_PACK.sha256`. Check the result with a
clean checkout: run the Build workflow, or unpack the pack into one and run the steps in `.github/workflows/build.yml`.

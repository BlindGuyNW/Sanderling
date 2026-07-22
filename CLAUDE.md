# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Sanderling reads the UI tree out of the memory of a running 64-bit EVE Online client process (read-only — it never injects into or writes to the game client). Two independently built components live here:

- `implement/read-memory-64-bit/` — C# / .NET 9 (Windows-only). Library + CLI (`read-memory-64-bit.exe`) that walks the game client's CPython objects and emits the UI tree as JSON.
- `implement/alternate-ui/` — Elm application (backend web service + browser frontend) that consumes that JSON, parses it into game-domain types, and renders it as HTML. Built and run with the [Pine](https://github.com/pine-vm/pine) tool, not with `elm make`.

The two are **not** linked by a project reference. The alternate UI loads a *published release* of the C# assemblies at runtime (see "Version pinning" below).

## Build, test, run

C# component (from repo root):

```powershell
dotnet build   ./implement/read-memory-64-bit/read-memory-64-bit.csproj
dotnet test    ./implement/read-memory-64-bit/read-memory-64-bit.csproj --logger trx
dotnet publish ./implement/read-memory-64-bit/read-memory-64-bit.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:IncludeAllContentForSelfExtract=true -p:PublishReadyToRun=true --output ./publish
```

`implement/read-memory-64-bit/build.bat` is a shorthand for `dotnet publish -p:Platform=x64`. CI (`.github/workflows/test-and-publish.yml`) additionally publishes a separate-assemblies variant — that is the artifact the alternate UI consumes.

Alternate UI (requires the `pine` executable on PATH — download from the pine-vm releases page; needs the .NET 9 runtime):

```powershell
# preferred: stops any instance on the port, deploys, and waits until the server actually answers
./start-alternate-ui.ps1                  # port 80
./start-alternate-ui.ps1 -Port 8080       # a second instance, to try a change without disturbing the first
./start-alternate-ui.ps1 -Stop            # stop it again

# upstream's original one-liner (no readiness check, must be run from that directory)
cd implement/alternate-ui ; ./run-alternate-ui.ps1
# frontend at http://localhost:80/ ; http://localhost:80/with-inspector enables the Elm debugger

# compile just the frontend to a standalone HTML file (what CI checks)
cd implement/alternate-ui/source ; pine make src/Frontend/Main.elm --output=./alternate-ui.html
```

Elm unit tests live in `implement/alternate-ui/source/tests/ParseMemoryReadingTest.elm` (elm-explorations/test). No CI workflow runs them and the repo pins no test-runner config; run them with an Elm test runner from `implement/alternate-ui/source`. The only automated check on the Elm code is that `pine make` on the frontend succeeds.

CLI usage of the built tool:

```cmd
read-memory-64-bit.exe save-process-sample --pid=12345
read-memory-64-bit.exe read-memory-eve-online --pid=12345 --output-file=reading.json
read-memory-64-bit.exe read-memory-eve-online --source-file=process-sample-XXXX.zip
```

A *process sample* (`.zip` of all committed memory regions + window screenshots) is the unit of collaboration for debugging: users post one, and it can be replayed offline via `--source-file` with no game client running. See `guide/how-to-collect-samples-for-64-bit-memory-reading-development.md`.

## Architecture / data flow

```
EVE client process memory
  → EveOnline64.EnumeratePossibleAddressesForUIRootObjects*   (scan for UIRoot candidates)
  → EveOnline64.ReadUITreeFromAddress(root, IMemoryReader, maxDepth: 99)
  → UITreeNode record  →  SerializeMemoryReadingNodeToJson
  → [JSON]
  → EveOnline/MemoryReading.elm     (decode into the raw UITreeNode tree, verbatim)
  → EveOnline/ParseUserInterface.elm (raw tree → named, typed game structures)
  → Frontend/Main.elm + Frontend/InspectParsedUserInterface.elm (HTML render, mouse/keyboard effects back to the client)
```

C# side (`implement/read-memory-64-bit/`):
- `EveOnline64.cs` is the core, and the only large file. It reads CPython 2.7 object layouts directly: `PyObject` header offsets, per-type readers registered in `specializedReadingFromPythonType` (`str`, `unicode`, `int`, `bool`, `float`, `PyColor`, `Bunch`, `Link`), and `DictEntriesOfInterestKeys` — the allowlist of Python dict keys copied into each node. **Adding a new game-client property to the reading usually means adding its key to `DictEntriesOfInterestKeys`.** A `MemoryReadingCache` keyed by address prevents re-reading shared objects.
- `IMemoryReader` has two implementations: `MemoryReaderFromLiveProcess` (ReadProcessMemory) and `MemoryReaderFromProcessSample` (replay from a saved sample). Everything above the interface works identically for both.
- `Program.cs` is CLI wiring only, plus the `UITreeNode` record and screenshot helpers. `WinApi.cs`, `ProcessSample.cs`, `ZipArchive.cs` are support.

Elm side (`implement/alternate-ui/source/src/`):
- `Backend/Main.elm` — Pine web service. Spawns a *volatile process* from `EveOnline/VolatileProcess.csx` and proxies `/api/` requests from the frontend into it.
- `EveOnline/VolatileProcess.csx` — C# script executed inside the Pine runtime on the machine with the game client. It calls into the published `read_memory_64_bit` assemblies (`EveOnline64.ReadUITreeFromAddress`, `MemoryReaderFromLiveProcess`) and handles UI-root search, reading, and mouse/keyboard effects. It has **two input paths**, selected by the `bringWindowToForeground` flag on the request — see "Input to the game client" below.
- `EveOnline/VolatileProcessInterface.elm` — the hand-written request/response contract with the `.csx` script; the JSON encoders/decoders on both sides must be edited together.
- `InterfaceToFrontendClient.elm` — the frontend↔backend contract; its JSON converters are *generated* by the Pine compiler (`CompilationInterface/GenerateJsonConverters.elm` contains placeholder bodies that the compiler replaces — do not implement them by hand).
- `CompilationInterface/*.elm` — Pine compiler hooks generally: `SourceFiles.elm` embeds `VolatileProcess.csx` as a string, `ElmMake.elm` embeds the compiled frontend HTML into the backend. The `"The compiler replaces this declaration."` bodies are intentional.
- `EveOnline/ParseUserInterface.elm` (~3.7k lines) is where nearly all game-domain knowledge lives: `ParsedUserInterface` with `ShipUI`, `OverviewWindow`, `InventoryWindow`, `DronesWindow`, `Neocom`, etc., built by locating nodes by `pythonObjectTypeName` / dict entries and computing display regions for mouse targeting.

## Conventions that matter here

**Version pinning across components.** When a new `read-memory-64-bit` release is cut, the alternate UI is moved to it by editing the URL comment and the following `#r "sha256:..."` line at the top of `EveOnline/VolatileProcess.csx` (see commit `5790e12`). Keep these in sync when bumping:
- `Program.cs` → `AppVersionId`
- `Common/App.elm` → `versionId`
- `VolatileProcess.csx` → release URL + assembly hash
- `implement/alternate-ui/README.md` and `.github/workflows/build-alternate-ui-frontend-html.yml` → the pinned commit hash / pine version used in the documented `--deploy=` command (see commit `b9fbc74`)

**Parsing fixes are driven by user-reported samples.** The recurring change shape (e.g. commit `d2ffa5b`) is: a player reports the client showing a form the parser doesn't handle → adjust the parse function in `ParseUserInterface.elm` → add the exact observed string as a case in `tests/ParseMemoryReadingTest.elm`, with a comment giving the date and the forum/session-recording source. Follow that comment convention; the existing cases document real client variations (thousands separators `. , space ’ '`, localized modifier keys `STRG`/`UMSCH`, both `<url=…>` and `<a href=…>` markup) and must not be regressed.

**Input to the game client.** `VolatileProcess.csx` has two ways to deliver an effect, chosen by the request's `bringWindowToForeground` flag:

- `true` — the legacy path: `Sanderling.Motor.WindowMotor` + `InputSimulator`, which calls `SetForegroundWindow` and moves the real cursor. This steals keyboard focus, which makes the alternate UI unusable alongside a screen reader.
- `false` — `InputViaWindowMessages`, which posts `WM_MOUSE*` / `WM_KEY*` straight to the window. No focus change and no cursor motion. This is what the frontend uses.

Three non-obvious constraints on the message path, all established by measuring against a live client — do not "simplify" them away:

1. Mouse messages are processed **only while the real cursor is physically inside the window's client area**. Focus is irrelevant, cursor geometry is not; parked on the title bar or window border, every click is silently dropped. `EnsureCursorInsideClientArea` handles this and is a no-op in the common case. Keyboard is *not* subject to this.
2. A button-down posted immediately after a move is discarded — the client hit-tests against the pointer position from its previous frame. 0 ms fails; ≥60 ms works. The wait lives in the `.csx`, not in the caller, because `effectSequenceSpacingMilliseconds` in `Frontend/Main.elm` is only 30 ms.
3. The client derives the typed character from `WM_KEYDOWN` itself, so **do not also post `WM_CHAR`** — every character is entered twice.

A minimized client cannot be driven at all, and `ShowWindow(SW_SHOWNOACTIVATE)` restores it but still pulls the foreground; that path is unsolved.

**Debugging effects without the browser.** `POST http://localhost/api` on the running backend is a full control loop — the same endpoint the frontend uses. Pine's generated converters encode a tag as `{"Tag":[arg, ...]}` (arguments always array-wrapped), and `returnValueToString.Just[0]` is itself a JSON string needing a second parse. Sequence: `ListGameClientProcessesRequest` → `SearchUIRootAddress` (poll until completed) → `ReadFromWindow`. Useful oracle for "did that effect land": the count and rects of `WindowUnderlay` nodes, or `l_menu`'s descendants for context menus. To test a `.csx` change without disturbing a running instance, deploy a second one: `pine run-server --process-store=<tmp> --admin-urls="http://*:4100" --public-urls="http://*:8080" --delete-previous-process --deploy=./source/`.

**Line endings.** `.editorconfig` sets `end_of_line = lf` for all files, and CI sets `core.autocrlf false` before checkout. On Windows, avoid tooling that rewrites files to CRLF.

## Out of scope for this repo

There are no bots here — bots are separate projects that consume this parsing library. Player-facing documentation lives at <https://to.botlab.org/guide/parsed-user-interface-of-the-eve-online-game-client>. `explore/` holds historical one-off investigations and is not part of any build.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Sanderling reads the UI tree out of the memory of a running 64-bit EVE Online client process (read-only — it never injects into or writes to the game client). Two independently built components live here:

- `implement/read-memory-64-bit/` — C# / .NET 9 (Windows-only). Library + CLI (`read-memory-64-bit.exe`) that walks the game client's CPython objects and emits the UI tree as JSON.
- `implement/alternate-ui/` — the Elm frontend (browser page) that consumes that JSON, parses it into game-domain types, and renders it as HTML. Compiled to a standalone HTML file with the [Pine](https://github.com/pine-vm/pine) tool's `pine make` (the stock `elm` binary is not installed here); Pine is a **build tool only** in this fork.
- `implement/alternate-ui-host/` — the ASP.NET backend serving that frontend and `/api`: UI-root search, memory reads, and input effects. It references the reader as an ordinary **project reference**, so a reader change reaches the UI by rebuilding and restarting — no pinning, no ceremony. It replaced the Pine web service in 2026-07 (`implement/alternate-ui/PLAN-dotnet-host.md` records why and what remains); the old backend files (`Backend/Main.elm`, `EveOnline/VolatileProcess.csx`) are still in the tree as the rollback path until plan phase 3 deletes them, but nothing runs them.

## Build, test, run

C# component (from repo root):

```powershell
dotnet build   ./implement/read-memory-64-bit/read-memory-64-bit.csproj
dotnet test    ./implement/read-memory-64-bit/read-memory-64-bit.csproj --logger trx
dotnet publish ./implement/read-memory-64-bit/read-memory-64-bit.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:IncludeAllContentForSelfExtract=true -p:PublishReadyToRun=true --output ./publish
```

`implement/read-memory-64-bit/build.bat` is a shorthand for `dotnet publish -p:Platform=x64`. CI (`.github/workflows/test-and-publish.yml`) additionally publishes a separate-assemblies variant for upstream's release flow; nothing in this fork consumes it.

Alternate UI (requires `pine` on PATH for the frontend compile — download from the pine-vm releases page; needs the .NET 9 SDK):

```powershell
# builds the frontend (pine make) and the host (dotnet build), then serves both
./start-alternate-ui.ps1                     # port 80
./start-alternate-ui.ps1 -SkipFrontendBuild  # host-only change: skips the ~1 min pine make
./start-alternate-ui.ps1 -Port 8080          # a second instance, to try a change without disturbing the first
./start-alternate-ui.ps1 -Stop               # stop it again
# frontend at http://localhost:80/ ; http://localhost:80/with-inspector enables the Elm debugger

# compile just the frontend to a standalone HTML file (what CI checks)
cd implement/alternate-ui/source ; pine make src/Frontend/Main.elm --output=./alternate-ui.html
```

A whole-tree reading through the host takes ~0.3 s (the retired Pine backend took ~2-5 s), the
browser spends ~115 ms rendering it, and the host restarts in about a second — so the deploy
loop for a backend change is seconds, and for a view change it is the `pine make` minute.

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
- `EveOnline64.cs` is the core, and the only large file. It reads CPython 2.7 object layouts directly: `PyObject` header offsets, per-type readers registered in `specializedReadingFromPythonType` (`str`, `unicode`, `int`, `bool`, `float`, `PyColor`, `Bunch`, `Link`, `set`/`frozenset`, `InteractionState`), and `DictEntriesOfInterestKeys` — the allowlist of Python dict keys copied into each node. **Adding a new game-client property to the reading usually means adding its key to `DictEntriesOfInterestKeys`** — and then rebuilding the pinned assembly, or the Elm side never sees it (see "Changing the C# reader"). A key whose value is a Python type with no entry in `specializedReadingFromPythonType` serializes as a bare `{address, pythonObjectTypeName}` and needs a reader too. A `MemoryReadingCache` keyed by address prevents re-reading shared objects.
- `IMemoryReader` has two implementations: `MemoryReaderFromLiveProcess` (ReadProcessMemory) and `MemoryReaderFromProcessSample` (replay from a saved sample). Everything above the interface works identically for both.
- `Program.cs` is CLI wiring only, plus the `UITreeNode` record and screenshot helpers. `WinApi.cs`, `ProcessSample.cs`, `ZipArchive.cs` are support.

Backend (`implement/alternate-ui-host/`, ASP.NET minimal API):
- `VolatileHost.cs` — the request handlers ported from the retired `VolatileProcess.csx`: `ListGameClientProcesses`, `SearchUIRootAddress` (background task; the frontend polls until completed), `ReadFromWindow`, and effect sequences. Calls `read_memory_64_bit` through the project reference.
- `InputViaWindowMessages.cs` — posts `WM_MOUSE*` / `WM_KEY*` to the game window; see "Input to the game client" below. The focus-stealing foreground path was deliberately not ported.
- `Program.cs` — routes, plus `EnvelopeAdapter`: until plan phase 3, the frontend still posts the Pine-*generated* encoding of the request (tags array-wrapped, `{"VirtualKeyCodeFromInt":[n]}`), which the adapter translates to the DTOs; responses are wrapped back in `RunInVolatileProcessCompleteResponse`.

Elm side (`implement/alternate-ui/source/src/`):
- `EveOnline/VolatileProcessInterface.elm` — the hand-written inner request/response contract; its decoders parse what `VolatileHost.cs` serializes, so the two must be edited together.
- `InterfaceToFrontendClient.elm` + `CompilationInterface/*.elm` — the envelope types and Pine compiler hooks (`GenerateJsonConverters` placeholder bodies are intentional — the compiler replaces them; the frontend build still uses them until plan phase 3 collapses the envelope).
- `Backend/Main.elm` + `EveOnline/VolatileProcess.csx` — the retired Pine backend and its volatile-process script; kept only as the rollback path, do not extend them.
- `EveOnline/ParseUserInterface.elm` (~3.7k lines) is where nearly all game-domain knowledge lives: `ParsedUserInterface` with `ShipUI`, `OverviewWindow`, `InventoryWindow`, `DronesWindow`, `Neocom`, etc., built by locating nodes by `pythonObjectTypeName` / dict entries and computing display regions for mouse targeting.

## Conventions that matter here

**Alternate UI views.** `implement/alternate-ui/CONVENTIONS.md` sets the ground rules for the
screen-reader-oriented views: order and precedence come from the game client's own layer stack,
every window renders through the generic shell whether or not it has a specialized view, labels
come from the client rather than hand-written tables, and heading levels express nesting. Read it
before adding or changing a view.

**Changing the C# reader is rebuild-and-restart.** The host references the reader project directly, so a reader change — for example adding a key to `DictEntriesOfInterestKeys` so a new client property reaches the Elm side — ships with `./start-alternate-ui.ps1 -SkipFrontendBuild` (which rebuilds both projects). The hash-pinning / prebuilt-DLL ritual this section used to describe died with the Pine backend; if you are reading old commits or the retired `VolatileProcess.csx`, that is what its `#r "sha256:..."` lines were about.

The CLI (`read-memory-64-bit.exe`) is the right tool for measuring a new key before wiring anything: it keeps `otherDictEntriesKeys`, which the alternate UI's path strips via `WithOtherDictEntriesRemoved()`.

Keep these in sync when bumping versions:
- `Program.cs` → `AppVersionId`
- `Common/App.elm` → `versionId`
- `implement/alternate-ui/README.md` and `.github/workflows/build-alternate-ui-frontend-html.yml` → the pinned commit hash / pine version used in the documented commands (see commit `b9fbc74`)

**Parsing fixes are driven by user-reported samples.** The recurring change shape (e.g. commit `d2ffa5b`) is: a player reports the client showing a form the parser doesn't handle → adjust the parse function in `ParseUserInterface.elm` → add the exact observed string as a case in `tests/ParseMemoryReadingTest.elm`, with a comment giving the date and the forum/session-recording source. Follow that comment convention; the existing cases document real client variations (thousands separators `. , space ’ '`, localized modifier keys `STRG`/`UMSCH`, both `<url=…>` and `<a href=…>` markup) and must not be regressed.

**Hidden means alpha, not absence.** The client often hides UI by making it transparent while leaving the nodes in the tree: `SelectionIndicatorLine` by color alpha, the notification badge and its settings button by `_opacity` ≈ 0. A region-only visibility check therefore announces invisible controls, and clicking one hits whatever is underneath. Gate on `_opacity` / color alpha too — see `subtreeShowsSelectionIndicator` and `parseNotificationsWidget`.

**Input to the game client.** The host delivers every effect through `InputViaWindowMessages` (`implement/alternate-ui-host/InputViaWindowMessages.cs`), which posts `WM_MOUSE*` / `WM_KEY*` straight to the window: no focus change and no cursor motion, which is what keeps the alternate UI usable alongside a screen reader. (The old focus-stealing foreground path — `WindowMotor` + `InputSimulator`, selected by `bringWindowToForeground = true` — was dropped in the port; the host answers `FailedToBringWindowToFront` if asked for it.)

Five non-obvious constraints on the message path, all established by measuring against a live client — do not "simplify" them away:

1. Mouse messages are processed **only while the real cursor is physically inside the window's client area**. Focus is irrelevant, cursor geometry is not; parked on the title bar or window border, every click is silently dropped. `EnsureCursorInsideClientArea` handles this and is a no-op in the common case. Keyboard is *not* subject to this.
2. A button-down posted immediately after a move is discarded — the client hit-tests against the pointer position from its previous frame. 0 ms fails; ≥60 ms works. The wait lives in the host, not in the caller, because `effectSequenceSpacingMilliseconds` in `Frontend/Main.elm` is only 30 ms.
3. The client derives the typed character from `WM_KEYDOWN` itself, so **do not also post `WM_CHAR`** — every character is entered twice.
4. Drags (sliders, item moves) are press → midpoint move → release with ~150 ms between steps; a plain posted click on a slider handle is eaten by the client's double-click filtering.
5. A posted Escape does not close a context menu — a click elsewhere does.

A minimized client cannot be driven at all, and `ShowWindow(SW_SHOWNOACTIVATE)` restores it but still pulls the foreground; that path is unsolved. A few controls never respond to posted input at all (measured 2026-07-23: the notification entry's ✕ ignores every click variant while the buttons beside it work) — when a control ignores clicks that demonstrably land elsewhere, look for a right-click-menu route to the same action instead.

**Debugging effects without the browser.** `tools/AlternateUiApi.ps1` and `tools/GameWindowProbe.ps1` package this up — dot-source the first to read the live tree and send input, and run the second when input mysteriously stops working (it checks for a minimized window and a cursor outside the client area, the two conditions that silently drop input while the tree keeps reading fine). `tools/GameWindowScreenshot.ps1` captures the client window to PNG via PrintWindow — works while occluded, and pixel coordinates match tree regions, so it settles "is this actually drawn?" questions the reading alone cannot:

```powershell
. ./tools/AlternateUiApi.ps1
$ctx = Connect-GameClient
$before = Get-WindowSignature -Tree (Read-UITree -Context $ctx)
Send-MouseClick -Context $ctx -X 24 -Y 72
Compare-WindowSignature -Before $before -After (Get-WindowSignature -Tree (Read-UITree -Context $ctx))
```

The underlying protocol, if you need it directly: `POST http://localhost/api` on the running backend is a full control loop — the same endpoint the frontend uses. Pine's generated converters encode a tag as `{"Tag":[arg, ...]}` (arguments always array-wrapped), and `returnValueToString.Just[0]` is itself a JSON string needing a second parse. Sequence: `ListGameClientProcessesRequest` → `SearchUIRootAddress` (poll until completed) → `ReadFromWindow`. Useful oracle for "did that effect land": the count and rects of `WindowUnderlay` nodes, or `l_menu`'s descendants for context menus.

`ReadFromWindow`'s `uiRootAddress` is not required to be the UI root — pass any node's `pythonObjectAddress` from a previous reading and it reads back that subtree alone. A whole reading is still the expensive shape: measured 2026-07-26 against a live client through the host, the whole tree (~1.4 MB) takes **~0.3 s** end-to-end while the `l_menu` layer alone takes **~9 ms** — so anything that has to answer a keypress should still read a subtree rather than the tree. The alternate UI's tooltip inspection is built on this (`tooltipLayerAddressFromReading` in `Frontend/Main.elm`). Unlike the old volatile process, the host serves requests concurrently, so your probe requests do not queue behind the page's poll; page freshness is now bounded by the frontend's **one-second poll tick** (~1.3 s worst case), not by the backend. To test a host change without disturbing a running instance, start a second one: `./start-alternate-ui.ps1 -Port 8080 -SkipFrontendBuild`.

**Line endings.** `.editorconfig` sets `end_of_line = lf` for all files, and CI sets `core.autocrlf false` before checkout. On Windows, avoid tooling that rewrites files to CRLF.

## Out of scope for this repo

There are no bots here — bots are separate projects that consume this parsing library. Player-facing documentation lives at <https://to.botlab.org/guide/parsed-user-interface-of-the-eve-online-game-client>. `explore/` holds historical one-off investigations and is not part of any build.

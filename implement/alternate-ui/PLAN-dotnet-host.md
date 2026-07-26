# Plan: replace the Pine backend with a .NET host

Status: **phases 1 and 2 done, 2026-07-26** — the host lives in `implement/alternate-ui-host/`,
started with `./start-alternate-ui-host.ps1` on port 8080. Both were verified against the live
client the same day: whole-tree read **305-339 ms** end-to-end through the harness (was ~1.9-5 s),
`l_menu` subtree read **9 ms** (was ~250 ms), a posted click toggled a window open and closed, and
a hover produced a `TooltipPanel`. Phase 2 shipped with phase 1 because the message path is a
verbatim copy with no external dependencies, and without it the unchanged frontend on 8080 would
fail every click; the foreground branch was dropped, not ported (the host answers
`FailedToBringWindowToFront` if asked for it). Remaining: phases 3 and 4.

Browser cost, measured in an active tab against the running page later the same day: transfer of
the 1.38 MB response **234-249 ms**, then **one ~115 ms long task** per reading (JSON decode +
Elm processing + view; Elm defers it off the XHR load event, and the visible page usually diffs
to zero DOM mutations). So a poll cycle is now roughly 1 s tick + ~240 ms transfer + ~115 ms
browser work: **the 1-second poll tick in `Frontend/Main.elm` is the largest term**, not the
backend and not the browser. Tightening the tick (or switching to request-on-response) is worth
considering during phase 3. Note the host served two pages polling concurrently during this
measurement without the transfer time moving.

Written 2026-07-26 from measurements taken the same day. This file is the handoff: it should be
enough to resume with no other context.

## Why

Measured against the live client, 2026-07-26, one whole-tree reading through `POST /api/`:

| stage | cost |
|---|---|
| C# work: read 2437 nodes, type hierarchy, serialize | **~200 ms** |
| Pine fixed cost per request | ~230 ms |
| Pine cost proportional to payload (~1.8 us/byte over 826 KB) | **~1.5 s** |
| total | ~1.9 s |

So `T ~= 230 ms + 1.8us x bytes`, and ~90% of it is `Backend/Main.elm` making three or four passes
over a megabyte of characters in an interpreted VM. The memory reader is not slow; the transport
is. Consequences today: the page is only ever ~5 s fresh (the volatile process serves one request
at a time and the 1 s poll tick against a ~2-5 s reading keeps it permanently busy), and a change
takes 122 s to deploy.

How to re-verify the split without trusting this file:

```powershell
# the C# work alone, calling exactly what VolatileProcess.csx calls
$reader = [read_memory_64_bit.MemoryReaderFromLiveProcess]::new($pid)
[read_memory_64_bit.EveOnline64]::ReadUITreeFromAddress($uiRootAddress, $reader, 99)   # ~150-200 ms
# the same reading through the running backend
. ./tools/AlternateUiApi.ps1 ; Read-UITree -Context (Connect-GameClient)               # ~1.9 s
```

Upgrading Pine is not a way out: **pine 0.5.1 cannot build this app** (tried 2026-07-26, installed
at `C:\Users\Shadow\pine\v0.5.1`). After ~15 minutes and 1.6 GB it died with *"Failed interpreting
function to lower Elm app: Case expression did not match any arm"*, inside Pine's own
`CompileElmApp` while walking type annotations toward `Common/EffectOnWindow.elm`. The feature that
crashed is `GenerateJsonConverters` — the one Pine-specific thing this project uses. Stay on 0.4.21
until this plan lands, after which the question is moot.

Elm is **not** the problem and is not being replaced. `elm.json` is 100% stock packages, and
`ParseUserInterface.elm` plus every view is portable Elm. Only the *host* changes.

## What Pine does for us, and what replaces it

| Pine feature | Used for | Replacement |
|---|---|---|
| `Platform.WebService` | `Backend/Main.elm`: 3 routes, forward JSON, a log | ASP.NET minimal API, ~150 lines |
| `CreateVolatileProcess` | run `VolatileProcess.csx` where the client is | it is already C#; becomes a class in the host |
| `GenerateJsonConverters` | converters for 2 envelope types | deleted — see "envelope collapse" |
| `SourceFiles` / `ElmMake` | embed the `.csx` and the compiled frontend | serve two HTML files from disk |

## Envelope collapse (do this, it is most of the simplification)

Today the same contract is crossed twice:

```
frontend  --(generated converters: RequestFromClient)-->  Backend/Main.elm
          --(hand-written buildRequestStringToGetResponseFromVolatileHost)-->  .csx
          <--(JSON)--  .csx
          <--(generated converters, inner JSON wrapped as the STRING returnValueToString)--
```

That last wrap is why `returnValueToString.Just[0]` needs a second parse (noted in CLAUDE.md), and
it means a megabyte of JSON gets escaped into a JSON string and re-parsed.

`InterfaceToFrontendClient.elm` is **20 lines**, and the inner contract in
`VolatileProcessInterface.elm` already has hand-written codecs on both sides. So: have the frontend
post the inner request directly and parse the inner response directly. The `.csx` entry point is
already `string InterfaceToHost_Request(string request)` → `serialRequest(request)`, so the
endpoint becomes literally:

```
POST /api/  :  body string --> serialRequest(body) --> body string
```

No generated converters, one fewer encode/decode round trip, no string-in-string escaping.

## File-level map (verified 2026-07-26)

Delete: `src/Backend/Main.elm` (395), `src/CompilationInterface/*.elm` (49),
`src/InterfaceToFrontendClient.elm` (20).

Port: `src/EveOnline/VolatileProcess.csx` (1016) → a `.cs` class in the host. Mechanical; it is
already C#. Entry point at line 1013.

Change: `src/Frontend/Main.elm` — `apiRequestCmd` (around line 316, `url = "/api/"`) and the
response decoding, ~40 lines, using functions that already exist in `VolatileProcessInterface.elm`.

Do not touch: `EveOnline/ParseUserInterface.elm` (~3.7k), `Frontend/View/*`, `tests/`, `elm.json`.

### Dependencies collapse from 8 hash-pinned blobs to 2 normal references

The `.csx` pins 8 assemblies by sha256. Which are live:

- `System.Drawing.Common` / `System.Drawing.Primitives` — **dead**, named only in comments
  (lines 30-35); the only screenshot mention is inside an `if (false)` block at line 343.
- `BotEngine.Motor`, `Sanderling.Motor.WindowMotor`, `Bib3.Geometrik`, `WindowsInput.InputSimulator`
  — reachable **only** when `bringWindowToForeground = true`. `ExecuteEffectOnWindow` returns at
  line 471 before reaching any of it, and the frontend passes `False` at `Frontend/Main.elm:625`
  and nowhere else. There is a second legacy block around lines 931-944 needing the same treatment.
- `read_memory_64_bit` — becomes a **project reference** to `implement/read-memory-64-bit`.
- `Newtonsoft.Json` — NuGet (or port to `System.Text.Json`; not required for phase 1).

Dropping the foreground path also deletes the `#r "sha256:..."` pinning and with it the
silent-failure footgun CLAUDE.md warns about at length, plus the `prebuilt/*.dll` copy dance in
`start-alternate-ui.ps1`.

## Phases

Each phase ends with the app still working. The new host runs on **8080** while pine keeps **80**,
until phase 4.

### Phase 1 — host + read path (approved; the measurable win)

1. New project, e.g. `implement/alternate-ui-host/` (.NET 9, `Microsoft.NET.Sdk.Web`), project
   reference to `read-memory-64-bit`, NuGet `Newtonsoft.Json`.
2. Port from the `.csx`: the `Request`/`Response` DTOs, `serialRequest`, `ListGameClientProcesses`,
   `SearchUIRootAddress` (keep the background-task behaviour — the frontend polls until completed),
   and `ReadFromWindow`. Keep `ReadPythonTypeHierarchy` and `WithOtherDictEntriesRemoved`.
3. Endpoints: `POST /api` and `POST /api/` → `serialRequest(body)`; `GET /` → frontend HTML;
   `GET /with-inspector` → debug HTML.
4. Build the frontend with `pine make src/Frontend/Main.elm --output=...` (pine stays a *build
   tool*; the `elm` binary is not installed on this machine, and does not need to be). Serve the
   file. Check whether pine make has a `--debug` flag for the inspector variant; if not, serve the
   same file for both until phase 3.
5. Leave the frontend's envelope alone for now: the host can wrap `serialRequest`'s output in the
   `{"RunInVolatileProcessCompleteResponse":[{...}]}` shape the current frontend expects, so phase 1
   needs **no frontend change at all** and can be measured against the unmodified page.

**Acceptance:** with pine stopped, `. ./tools/AlternateUiApi.ps1 ; Set-AlternateUiEndpoint -Port 8080`
then `Connect-GameClient` and `Read-UITree` succeed, and a whole-tree read measures **well under
500 ms** (target ~250 ms). Compare with the numbers at the top of this file.

**Also measure here:** load the page and time how long the browser takes to parse and render one
reading. Once the backend stops costing seconds this may become the limit; it is currently
unmeasured. Beware: a backgrounded Chrome tab is throttled to ~1 Hz and every timing taken in it is
worthless — see the `chrome-automation-clicks-unreliable` note.

### Phase 2 — effect path (riskiest)

Port `ExecuteEffectOnWindowViaMessages` and the `EffectSequenceOnWindow` handling; delete the
foreground branch and its dependencies. **The five constraints in CLAUDE.md under "Input to the
game client" were each established by measuring against a live client and must survive verbatim** —
cursor physically inside the client area, the >=60 ms wait between move and button-down, no
`WM_CHAR`, drag timing, Escape does not close menus.

**Acceptance:** verify with the harness, not by asking anyone what happened on screen:

```powershell
. ./tools/AlternateUiApi.ps1 ; Set-AlternateUiEndpoint -Port 8080
$ctx = Connect-GameClient
$before = Get-WindowSignature -Tree (Read-UITree -Context $ctx)
Send-MouseClick -Context $ctx -X 24 -Y 72
Compare-WindowSignature -Before $before -After (Get-WindowSignature -Tree (Read-UITree -Context $ctx))
```

Plus a hover: send a bare `MouseMoveTo` at a Neocom button, wait ~400 ms, read the `l_menu` layer,
expect a `TooltipPanel`. And run `tools/GameWindowProbe.ps1` first if input seems dead.

### Phase 3 — envelope collapse

Frontend posts the inner request and parses the inner response; delete
`InterfaceToFrontendClient.elm`, the `CompilationInterface` modules, and the host's wrapper from
phase 1. After this the frontend compiles with plain `elm make` too.

### Phase 4 — switch over

Host becomes the default on port 80. Rewrite `start-alternate-ui.ps1` (drop the prebuilt-DLL copy
and hash steps entirely). Update CLAUDE.md: the "Changing the C# reader" section becomes "rebuild
and restart", and the `#r` hash bullet in the version-sync list goes away. Delete
`implement/read-memory-64-bit/prebuilt/`. Keep `VolatileProcess.csx` in git history only.

## Rollback

Nothing is destructive until phase 4. `./start-alternate-ui.ps1` restores the pine instance on
port 80 at any point; pine 0.4.21 stays installed at `C:\Users\Shadow\pine\v0.4.21`.

## Constraints that apply throughout

- `.editorconfig` sets `end_of_line = lf`. Avoid tooling that rewrites files to CRLF.
- The reader is read-only against the game client. Never inject or write to it.
- Verify with `tools/*.ps1` rather than asking the user what they saw.
- Deploy to port 80 only for routine rounds; use 8080 for the parallel host until phase 4.

## Open questions

- ~~Does `pine make` expose a `--debug` build for `/with-inspector`?~~ **Yes** — the start script
  builds both variants and the host serves the debug one at `/with-inspector`.
- ~~Confirm the port keeps the same poll-until-completed contract for `SearchUIRootAddress`.~~
  Kept: same background `Task`, same in-flight dictionary (now a `ConcurrentDictionary` because
  Kestrel handles requests concurrently), same `InProgress`/`Completed` stages.
- Whether to keep Newtonsoft or move to `System.Text.Json` (the reader already uses the latter).
  Kept Newtonsoft for phases 1-2: the response shape (nulls omitted, public fields serialized)
  matches the .csx byte-for-byte that way. Revisit in phase 3 at the earliest.

## Note found while porting (phase 1)

The plan said phase 1 "needs no frontend change at all" because the host wraps responses in the
envelope shape. True, but the incoming direction also needed work the plan did not spell out: the
unchanged frontend posts the Pine-GENERATED encoding of `RequestFromClient` (tags array-wrapped,
`{"VirtualKeyCodeFromInt":[n]}` instead of `{"virtualKeyCode":n}`, `{"Effect":[...]}` instead of
`{"effect":...}`), which differs from the hand-written inner codec the `.csx` consumed. The
translation lives in `EnvelopeAdapter` in `Program.cs` and dies in phase 3 with the rest of the
envelope.

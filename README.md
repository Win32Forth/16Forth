# 16Forth

**Version 0.5** — macOS SwiftUI console host for a small ARM64 Forth engine.

**This is the last release that supports inlining** (`FL_INLINE`, `N:`, `D:`, `INLINE-ON` / `INLINE-OFF`, CODE paste / colon expand / native-convert). Tag `v0.5` freezes that model; **0.6** drops it to simplify the compiler. Source-only release — build the app from this tree yourself (no binary attached).

16Forth is a Forth that starts from a compact set of CODE primitives and grows through `kernel.fth` / `ansfile.fth`. This repository is the **only active 16Forth line**: the GUI app (`16Forth.app`) with an embedded kernel and an optional headless **agent** channel. The former CLI twin **[16ForthCLI](https://github.com/Win32Forth/16ForthCLI) is archived and inactive** — do not expect further engine sync or releases there.

Public domain / PickleForth lineage (same family as [64Forth](https://github.com/Win32Forth/64Forth)).

## What you get

- Double-clickable **macOS** app with a monospaced console (64Forth-style protected transcript).
- ARM64 **ITC** kernel in `16Forth/kernel.s`, with high-level Forth in `kernel.fth` and ANS file words in `ansfile.fth` (both `.incbin`’d at cold start).
- Host bridge: `EMIT` → Swift transcript; `kernel_cold_start` / `kernel_eval` for embed use (no TTY `QUIT` loop inside the app).
- **Auto-inline + native convert** under `INLINE-ON` (see below); `INLINE-OFF` keeps threaded/`SEE`-friendly definitions.
- **INCLUDE / FLOAD / FROMLIB** with FileHost open-panel and Library folder support; **vocabularies** / ANS Search-Order.
- **Agent channel** (`--agent` / `FORTH16_AGENT=1`): headless eval/load with EMIT on stdout — see `16Forth/Docs/Agent-channel.md` and `./tools/16forth-agent`.

## Version 0.5 highlights

### Inlining model (replaces user-facing `I:`)

Bodies always compile **threaded**. At `;`:

| Mechanism | Behavior |
|-----------|----------|
| **Auto `FL_INLINE`** | Set on the new word if the body is expand-safe (trailing `EXIT` only; no mid-definition `EXIT`, no `RECURSE`/self, no `S"`) and the definition was not started with `N:`. |
| **`N:`** | Like `:`, but never sets `FL_INLINE` (opt out of expand-into-callers). |
| **`INLINE-ON`** | When compiling a caller: **macro-expand** `FL_INLINE` colon callees; **paste** `FL_INLINE` CODE leaves listed in `inline_len_tab`; **whole-word native-convert** eligible non-inlineable colons at `;`. |
| **`INLINE-OFF`** | No macro-expand, no native convert — ordinary threaded calls (default boot / debugging). |
| **`D:`** | One threaded/debuggable definition; saves/restores `INLINE?`. |
| **`WARNINGS` ON/OFF** | When ON, compiling a user `EXIT` prints `"WORDNAME uses EXIT - Not inlinable"`. Warning depends on `EXIT` + `WARNINGS` only, not on `INLINE?`. `;`’s own trailing `EXIT` does not warn. |

Removed as user-facing defining words / immediates: **`I:`**, **`[INLINE]`**, **`[THREAD]`**, **`(INLINE)`**. `SEE` may still show a leading **`I`** when `FL_INLINE` is set.

`inline_len_tab` remains the allow-list for **CODE paste** (`DUP`, `+`, `@`, `I`/`J`/…, etc.). Control-flow cells (`BRANCH` / `0BRANCH` / DO-family) are **not** paste-inlined; the expander relocates them (native `B`/`CBZ` or threaded relative holes).

Nested colon expand is **safe**: `_macro_expand_colon` saves/restores the full mex map and fixup tables (not only counts), so expanding `FILL` → `1+`/`1-` inside a caller no longer leaves `BRANCH 0`.

### Other 0.5 engine / host notes

- **`RECURSE`** is CODE and goes through `_compile_word` (native-aware under `INLINE-ON`).
- **`FILE-ECHO`**: line-oriented echo (64Forth-style) via block `_sys_write`; fixed mid-line truncation caused by `emit_hook` clobbering the echo end register; `ELAPSED` timings now follow the echoed `ELAPSED …` line instead of splicing into source.
- Agent channel + `tools/16forth-agent` for automated loads (e.g. `~/Documents/Benchmarks`).
- **`.(`** (interpret-time print to `)`), **`C"`** / **`(C")`** (counted string, 64Forth-style) ported for completeness before the inline cut.

### Benchmarks / what we found (Documents/Benchmarks, median of 3)

Against **64Forth** (`/Applications/64Forth.app`) on the same suite, **16Forth INLINE-ON** helps ~7–18% over a true `INLINE-OFF`, but does **not** by itself close the gap to 64Forth on most programs (Bubble and PLDI especially still favor 64Forth).

Notable findings:

- Earlier “default/threaded” numbers were partly warmer because **`I:` expanded at use even when `INLINE?` was off**. `INLINE-OFF` is now a colder, honest baseline.
- Early aggressive `INLINE-ON` timings next to known codegen bugs are not comparable to correct ON today.
- Colon inlining is real but modest on these O(n²)/O(n³) benches; denser tiny-helper call chains benefit more than large DO-loop kernels.
- A first-order architectural difference vs 64Forth: **64Forth keeps TOS in `x20`**; **16Forth keeps the data stack entirely in memory** (`x22` points at TOS). That shows up on hot primitives (`+`, `DUP`, …) more than further colon expand typically does.
- `BRANCH` / `0BRANCH` stay off `inline_len_tab` on purpose (ITC IP / relative cell semantics); the expander’s reloc path is the right “inline” for them.

### Prior releases

- **0.4** — Vocabularies / Search-Order; INCLUDE/FileHost; agent channel; banner was `16Forth 0.4 ready`.
- **0.3** — `SEE` / `HELP`, native/`I:` DO-family, `MS@` / `ELAPSED`.

See `plan.md` for the original app-hosting plan and status notes.

## Layout

```
16Forth/
  16Forth/           engine + SwiftUI console
    kernel.s         ARM64 ITC + CODE + embed API + mex / native
    kernel.fth       high-level Core (auto-inline helpers)
    ansfile.fth      ANS File-Access wrappers
    host_*.c / .h    I/O, files, JIT buffer
    FileHost.swift   open panel / Library path
    KernelBridge.swift / AgentChannel.swift
    ConsoleView.swift / ConsoleTextView.swift
    Docs/Agent-channel.md
    Library/         FROMLIB resources
  tools/16forth-agent
  16Forth.xcodeproj
  plan.md
  README.md
```

## Build

Requires Xcode (Apple Silicon). From the repo root:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # or Xcode-beta
xcodebuild -scheme 16Forth -configuration Debug \
  -derivedDataPath build/DerivedData build
```

The app lands at:

`build/DerivedData/Build/Products/Debug/16Forth.app`

Open the shared scheme **16Forth** in Xcode for day-to-day work. Hardened Runtime needs the usual JIT entitlements (already configured in the project).

### Agent / headless

After a Debug (or Release) build:

```bash
./tools/16forth-agent -e '2 2 + .'
./tools/16forth-agent -c ~/Documents/Benchmarks -f sieve.fth -o /tmp/sieve.txt
./tools/16forth-agent --help
```

Or invoke the bundle binary directly with `--agent`. Details: `16Forth/Docs/Agent-channel.md`.

## Quick Forth notes

```forth
1 2 + . CR              \ basics
: 2*  DUP + ;           \ auto FL_INLINE if safe (SEE may show I:)
N: BIG  ... ;           \ never expand this into callers
INLINE-ON               \ expand inlineable; native-convert the rest
: SUM  0 SWAP 0 DO I + LOOP ;
5 SUM . CR
SEE SUM
WARNINGS ON             \ EXIT in a definition → console warning
INLINE-OFF              \ threaded : for debugging / SEE
D: SLOW  ... ;          \ one threaded def; INLINE? restored after ;
FILE-ECHO ON  FLOAD foo.fth
```

House preference: prefer structured `IF` / loops over mid-definition `EXIT` so words stay inlinable. `S"` inside expand/native convert remains deferred; use threaded definitions when you need it. `SEE` walks ITC bodies only (native JIT CFAs are treated like primitives).

## Related

| Repo | Role |
|------|------|
| [16ForthCLI](https://github.com/Win32Forth/16ForthCLI) | **Archived / inactive** — former CLI sibling; this app repo is the active 16Forth |
| [64Forth](https://github.com/Win32Forth/64Forth) | Larger macOS Forth + editor reference (TOS-in-register kernel) |

## License

Treat as public domain unless a file says otherwise (same spirit as the Win32Forth / PickleForth line).

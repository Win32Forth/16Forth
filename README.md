# 16Forth

**Version 0.6** — macOS SwiftUI console host for a small ARM64 Forth engine.

16Forth is a Forth that starts from a compact set of CODE primitives and grows through `kernel.fth` / `ansfile.fth`. This repository is the **only active 16Forth line**: the GUI app (`16Forth.app`) with an embedded kernel and an optional headless **agent** channel. The former CLI twin **[16ForthCLI](https://github.com/Win32Forth/16ForthCLI) is archived and inactive** — do not expect further engine sync or releases there.

Public domain / PickleForth lineage (same family as [64Forth](https://github.com/Win32Forth/64Forth)).

## What you get

- Double-clickable **macOS** app with a monospaced console (64Forth-style protected transcript).
- ARM64 **ITC** kernel in `16Forth/kernel.s`, with high-level Forth in `kernel.fth` and ANS file words in `ansfile.fth` (both `.incbin`’d at cold start).
- Host bridge: `EMIT` → Swift transcript; `kernel_cold_start` / `kernel_eval` for embed use (no TTY `QUIT` loop inside the app).
- **Always-threaded** colon definitions — simple compile path, `SEE`-friendly bodies.
- **INCLUDE / FLOAD / FROMLIB** with FileHost open-panel and `Library/` (copied into the app bundle Resources for FROMLIB).
- **Vocabularies** / ANS Search-Order.
- **Agent channel** (`--agent` / `FORTH16_AGENT=1`): headless eval/load with EMIT on stdout — see `16Forth/Docs/Agent-channel.md` and `./tools/16forth-agent`.

## Version 0.6 highlights

### Compiler simplification

**Inlining is gone.** Removed from 0.5: `FL_INLINE`, `N:`, `D:`, `INLINE-ON` / `INLINE-OFF`, CODE paste (`inline_len_tab`), colon macro-expand (mex), whole-word native-convert-at-`;`, EXIT-inlinability `WARNINGS`, and the JIT code buffer used only for that path.

Every colon body compiles as ordinary **threaded ITC**. `SEE` shows `:` / `CODE` with no leading `I`. Control-flow immediates (`IF`…`THEN`, `DO`…`LOOP`, …) always plant threaded cells.

Tag **[v0.5](https://github.com/Win32Forth/16Forth/releases/tag/v0.5)** remains the last snapshot that supported the inline model (source-only release).

### Still in 0.6

- **`RECURSE`**, `LIT` / `S"` / `C"` / `.(`, pictured numeric output, `MS@` / `ELAPSED`
- **`FILE-ECHO`**, INCLUDE / FLOAD / FROMLIB, vocabularies
- Agent channel + `tools/16forth-agent`
- App `Library/` (including ANSValidate when present) → `Contents/Resources/Library` for FROMLIB

### Performance note

0.5’s INLINE-ON gains were modest (~7–18% vs true OFF) and did not close the gap to 64Forth. A larger architectural difference remains: **64Forth keeps TOS in `x20`**; **16Forth keeps the data stack in memory** (`x22` at TOS). That is the next serious lever after dropping inline complexity.

### Prior releases

- **0.5** — Auto-inline + native convert; nested mex; FILE-ECHO; agent; `.(` / `C"`. **Last release with inlining** ([tag `v0.5`](https://github.com/Win32Forth/16Forth/releases/tag/v0.5)).
- **0.4** — Vocabularies / Search-Order; INCLUDE/FileHost; agent channel.
- **0.3** — `SEE` / `HELP`, DO-family, `MS@` / `ELAPSED`.

See `plan.md` for status notes.

## Layout

```
16Forth/
  16Forth/           engine + SwiftUI console
    kernel.s         ARM64 ITC + CODE + embed API
    kernel.fth       high-level Core
    ansfile.fth      ANS File-Access wrappers
    host_*.c / .h    I/O and files
    FileHost.swift   open panel / Library path
    KernelBridge.swift / AgentChannel.swift
    ConsoleView.swift / ConsoleTextView.swift
    Docs/Agent-channel.md
    Library/         FROMLIB resources (synced into app Resources)
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

Open the shared scheme **16Forth** in Xcode for day-to-day work. The `Library/` folder under `16Forth/` is an Xcode synchronized folder reference and is copied into `Contents/Resources/Library` (FROMLIB).

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
1 2 + . CR
: 2*  DUP + ;
: SUM  0 SWAP 0 DO I + LOOP ;
5 SUM . CR
SEE SUM
.( hello) CR
C" world" COUNT TYPE CR
FILE-ECHO ON  FLOAD foo.fth
FROMLIB FLOAD ANSValidate/hello.fth   \ Library/ → app Resources
```

## Related

| Repo | Role |
|------|------|
| [16ForthCLI](https://github.com/Win32Forth/16ForthCLI) | **Archived / inactive** — former CLI sibling; this app repo is the active 16Forth |
| [64Forth](https://github.com/Win32Forth/64Forth) | Larger macOS Forth + editor reference (TOS-in-register kernel) |

## License

Treat as public domain unless a file says otherwise (same spirit as the Win32Forth / PickleForth line).

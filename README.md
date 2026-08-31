# 16Forth

**Version 0.4** — macOS SwiftUI console host for a small ARM64 Forth engine.

16Forth is a Forth that starts from a compact set of CODE primitives and grows through `kernel.fth` / `ansfile.fth`. This repository is the **GUI app** (`16Forth.app`): a protected single-pane console that evaluates lines through the embedded kernel. The related command-line twin lives in [16ForthCLI](https://github.com/Win32Forth/16ForthCLI).

Public domain / PickleForth lineage (same family as [64Forth](https://github.com/Win32Forth/64Forth)).

## What you get

- Double-clickable **macOS** app with a monospaced console (64Forth-style protected transcript).
- ARM64 **ITC** kernel in `16Forth/kernel.s`, with high-level Forth in `kernel.fth` and ANS file words in `ansfile.fth` (both `.incbin`’d at cold start).
- Host bridge: `EMIT` → Swift transcript; `kernel_cold_start` / `kernel_eval` for embed use (no TTY `QUIT` loop inside the app).
- Optional **native codegen**: `INLINE-ON` makes new `:` words whole-word native JIT; `I:` marks macro-expandable definitions; `D:` forces a threaded/debuggable definition and restores inlining afterward.
- **INCLUDE / FLOAD / FROMLIB** with FileHost open-panel and Library folder support; **vocabularies** / ANS Search-Order.

## Version 0.4 highlights

- **Vocabularies / Search-Order** (64Forth lineage): `WORDLIST`, `VOCABULARY`, `ONLY` / `ALSO` / `PREVIOUS` / `FORTH` / `ORDER` / `DEFINITIONS`, `GET/SET-ORDER`, `FIND`, `SEARCH-WORDLIST`, `TRAVERSE-WORDLIST`, `.VOCABULARIES` / `.WORDLISTS` / `.THREADS`; starters `EDITOR`, `ASSEMBLER`, `FP`, `BIG-INTEGER`.
- **File load path**: `INCLUDED` / `INCLUDE` / `FLOAD` / `FROMLIB`, `FILE-ECHO`, `\S`, `SOURCE` / `EVALUATE` / `REFILL`, `CHDIR` / `PWD` / `DIR`; Swift `FileHost` + KernelBridge hooks; app `Library/` for `FROMLIB`.
- Prior **0.3** engine: `SEE` / `HELP`, native/`I:` DO-family, `MS@` / `ELAPSED`, banner **16Forth 0.4 ready**.

See `plan.md` for the original app-hosting plan and status notes.

## Layout

```
16Forth/
  16Forth/           engine + SwiftUI console
    kernel.s         ARM64 ITC + CODE + embed API
    kernel.fth       high-level Core
    ansfile.fth      ANS File-Access wrappers
    host_*.c / .h    I/O, files, JIT buffer
    FileHost.swift   open panel / Library path
    KernelBridge.swift
    ConsoleView.swift / ConsoleTextView.swift
    Library/         FROMLIB resources
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

### Headless smoke (optional)

Link the kernel with the host C files and drive `kernel_cold_start` / `kernel_eval` from a small C harness (same pattern used during development). Ensure `forth_io_init()` runs before cold start so the JIT code buffer exists.

## Quick Forth notes

```forth
1 2 + . CR          \ basics
I: 2*  DUP + ;      \ macro: expands into callers
INLINE-ON           \ later : words compile as native
: SUM  0 SWAP 0 DO I + LOOP ;
5 SUM . CR
SEE SUM             \ decompile threaded body
SEE DUP             \ CODE → header + (primitive)
D: SLOW  ... ;      \ one threaded def; INLINE? restored after ;
INLINE-OFF          \ back to threaded : for debugging
```

`S"` inside `I:` / native expand is still deferred; prefer threaded definitions when you need it. `SEE` walks ITC bodies only (native JIT CFAs are treated like primitives).

## Related

| Repo | Role |
|------|------|
| [16ForthCLI](https://github.com/Win32Forth/16ForthCLI) | CLI / REPL engine sibling |
| [64Forth](https://github.com/Win32Forth/64Forth) | Larger macOS Forth + editor reference |

## License

Treat as public domain unless a file says otherwise (same spirit as the Win32Forth / PickleForth line).

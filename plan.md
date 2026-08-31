# 16Forth.app — console window host for 16ForthCLI engine

## Answer up front (kernel files)

**Naming:** 16ForthCLI does **not** use `kernel1.fth` / `kernel2.fth` (those are 64Forth). Its high-level sources are:

| File | Role |
|------|------|
| `kernel.s` | ARM64 ITC engine + CODE words + `kernel_cold_start` / `kernel_eval` / CLI `_main` |
| `kernel.fth` | High-level Core (`TYPE`, `.`, `WORDS`, …) — `.incbin`’d at cold start |
| `ansfile.fth` | ANS File-Access wrappers — also `.incbin`’d |

| File | Changes needed for a console `.app`? |
|------|--------------------------------------|
| **`kernel.s`** | **Yes — required.** Today `EMIT` / `_sys_write` hardwire Darwin `write(1,…)`. That goes to nowhere useful in a GUI app. Must route through a host callback (64Forth-style `emit_hook`). Do **not** run CLI `_main` / `_quit_loop` inside the app; host calls `kernel_cold_start` + `kernel_eval`. Optionally add `kernel_set_emit` / `kernel_set_emit_buf` to `kernel_api.h` and a BSS hook pointer. |
| **`kernel.fth`** | **No for a first console REPL.** `TYPE` / `CR` / `."` already go through `EMIT`. Once `EMIT` hits the Swift transcript, high-level I/O follows. |
| **`ansfile.fth`** | **No for console display.** File words already call `host_file_op` (stdio). Keep as-is unless you later sandbox file access differently. |
| **64Forth `kernel1.fth` / `kernel2.fth`** | **Do not copy.** Wrong dialect / dictionary size / feature set for 16Forth. |

So: **engine high-level Forth stays; assembly I/O host coupling must change.**

---

## Goal

Ship a double-clickable **`16Forth.app`** that:

- Shows a monospaced console window (like 64Forth’s transcript, not Terminal.app).
- Runs the **working 16ForthCLI** engine (≤16 CODE primitives + `kernel.fth` / `ansfile.fth`).
- Line input → `kernel_eval`; engine output → transcript via emit hook.

Out of scope for v1 (unless you expand later): SZ-EDITOR, facility terminal, DEBUG stepper, Hyper/VIEW menus, iOS/multiplatform.

---

## Current state

| Project | Path | Status |
|---------|------|--------|
| **16ForthCLI** | `XCodeProjects/16ForthCLI/` | Working CLI: full `kernel.s` (~2.1k), host C (io/file/jit), schemes, `build/16ForthCLI` |
| **16Forth** | `XCodeProjects/16Forth/` | Unusable: Hello World SwiftUI + stale early `kernel.s` (~625) / incomplete `kernel.fth`; no bridge, no console, no host C |
| **64Forth** | `XCodeProjects/64Forth/` | Reference for console UI + `KernelBridge` emit/eval pattern |

---

## Architecture (v1)

```
┌─────────────────────────────────────────┐
│ 16Forth.app (SwiftUI WindowGroup)       │
│  ConsoleView + ConsoleTextView          │
│    Return → KernelBridge.evaluate       │
│    onEmit → append protected transcript │
└─────────────────┬───────────────────────┘
                  │ C ABI
┌─────────────────▼───────────────────────┐
│ kernel_cold_start / kernel_eval         │
│ EMIT → emit_hook → Swift                │
│ host_file.c / host_jit.c (as CLI)       │
│ kernel.fth + ansfile.fth (.incbin)      │
└─────────────────────────────────────────┘
```

**Do not** use `_main` / `_quit_loop` / `forth_readline` in the app. Those are the CLI TTY REPL. The GUI owns the prompt and line buffer (same split as 64Forth: CLI has QUIT loop; app uses embed eval).

---

## Implementation plan

### 1. Replace 16Forth app engine sources (copy from CLI) — DONE

Into `XCodeProjects/16Forth/16Forth/` (overwrite stale stubs):

- `kernel.s`, `kernel.fth`, `ansfile.fth`, `kernel_api.h`
- `host_io.c`, `host_file.c`, `host_jit.c` (+ `host_jit.h` if present)

`.incbin` paths retargeted to `"16Forth/kernel.fth"` / `"16Forth/ansfile.fth"`. CLI project left independent (copy, not shared).

### 2. Minimal `kernel.s` / API changes (the only kernel work) — DONE

1. BSS `emit_hook` / `emit_buf_hook`.
2. `kernel_set_emit` / `kernel_set_emit_buf` in `kernel_api.h`.
3. `XEMIT` / `_sys_write` route through hooks when set; fallback `write(1)`.
4. `_cli_main` (not `_main`); app uses `kernel_cold_start` + `kernel_eval`.
5. `SAVE_C_CALLEE` / `RESTORE_C_CALLEE` + `vm_dsp`/`vm_rsp` across C calls (SwiftUI ABI).

**No edits to `kernel.fth` / `ansfile.fth`.**

### 3. Slim host bridge (adapt from 64Forth, don’t paste whole 64Forth) — DONE

| Piece | Status |
|-------|--------|
| App shell `@main` + `WindowGroup` | Done |
| Slim `KernelBridge` (emit / cold_start / eval / depth) | Done |
| Simple transcript + TextField console | Done (interim; replaced) |
| `ConsoleView` / `ConsoleTextView` protected single pane (strip facility/SZ/DEBUG) | Done |

Skip for v1: `FacilityTerminal`, `ForthApplication` principal class, FileAccess/Float/BigInt hosts, agent channel, editor Library.

### 4. Xcode project hygiene — DONE

- macOS-only application target.
- Product / module → `16Forth` / `SixteenForth`.
- `OTHER_AFLAGS` for `.incbin`; Hardened Runtime JIT exceptions.
- Shared scheme `16Forth.xcscheme`. Sandbox off for v1.

### 5. Verification — DONE (basic)

1. Build `16Forth.app` — green after protected console.
2. Headless `1 2 + .` → 3; app process launches.
3. Interactive check: type in the single pane (history protected, Up/Down history).
4. CLI project untouched (sources copied).

**Possible follow-ons (not in original 5):** menus (Clear), font size, File → INCLUDE panel, share engine sources with CLI, app icon.

---

## Risks / decisions

- **Copy vs share sources:** Plan assumes **copy** into the app. Sharing one engine tree is better long-term but needs a small Xcode restructure; do after the first green `.app`.
- **Prompt ownership:** CLI prints `" ok\n"` in `forth_readline`. App should print `ok(n)>` in Swift (64Forth style) and not call readline.
- **Sandbox:** App sandbox may block arbitrary `fopen` paths that CLI allows; v1 can leave sandbox off or match 64Forth’s file entitlements.
- **Stale GUI `kernel.s`:** Must be fully replaced by CLI’s — do not try to “merge” the 625-line scaffold.

---

## Definition of done

- Double-clickable `16Forth.app` with its own console window.
- Same language surface as 16ForthCLI for interactive Core + file words that do not need a TTY.
- `kernel.fth` / `ansfile.fth` unchanged; `kernel.s` only changed for emit-hook + embed API surface.
- No dependency on Terminal.app for REPL I/O.

---

## Status — v0.4 (shipped beyond original v1 plan)

The console `.app` goal above is met. Engine work after the first green app includes:

| Area | Notes |
|------|--------|
| Embed `QUIT` / `ABORT` | Return to host under `embed_mode` (no readline hang). |
| `[INLINE]` / `[THREAD]` / `INLINE-ON` / `D:` | Whole-word native JIT; `D:` saves/restores `INLINE?`. |
| `I:` macros | Nested expand; LIT + relative `BRANCH`/`0BRANCH` reloc. |
| Control immediates | Asm native-aware `IF`…`THEN`, `BEGIN`…, `DO`/`?DO`/`LOOP`/`+LOOP`. |
| Loop indices | `I` / `J` / `K`; inlinable so native loops are correct. |
| Startup | Banner **16Forth 0.4 ready**; app marketing version **0.4**. |
| `SEE` / `HELP` | 64Forth-style ITC decompiler: colon walk until `EXIT`; `LIT`, `(S")`, `BRANCH`/`0BRANCH`, `(?DO)`/`(LOOP)`/`(+LOOP)` offsets; `(DO)` name-only; CODE/native → `(primitive)`; `I:` tag when FFA inline. |
| Timing | `MS@` / `MS`; pictured `<# # #S #>` / `BASE`/`DECIMAL`/`HEX`; `ELAPSED` / `.ELAPSED`. |
| INCLUDE / host files | `INCLUDED`/`INCLUDE`/`FLOAD`/`FROMLIB`, `FILE-ECHO`, `\S`, `SOURCE`/`EVALUATE`/`REFILL`, `CHDIR`/`PWD`/`DIR`; Swift FileHost + KernelBridge; app `Library/`. |
| Vocabularies | ANS Search-Order + 64Forth extras: `VOCABULARY`, `ORDER`, `WORDLIST`, `TRAVERSE-WORDLIST`, `.VOCABULARIES`; starters `EDITOR`/`ASSEMBLER`/`FP`/`BIG-INTEGER`. |

Still deferred vs a full 64Forth-class IDE: `S"` inside `I:`/native expand, ARM disassembly of native JIT bodies, shared engine tree with 16ForthCLI, Hyper/VIEW/sealed vocabs, `DICT_THREADS` hashing, menus / icon.

Original note that `kernel.fth` would stay unchanged is historical — high-level words now use `I:` where useful, and DO-family immediates live in asm.

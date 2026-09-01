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

## Current state (updated for v0.6)

| Project | Path | Status |
|---------|------|--------|
| **16Forth** | `XCodeProjects/16Forth/` | **Active** — macOS `.app` + agent channel; marketing **0.6** (always-threaded; no inlining) |
| **16ForthCLI** | `XCodeProjects/16ForthCLI/` / GitHub | **Archived / inactive** — no further sync expected |
| **64Forth** | `XCodeProjects/64Forth/` | Reference for console UI + TOS-in-register kernel |

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
- Same language surface historically shared with 16ForthCLI (now archived) for interactive Core + file words that do not need a TTY.
- `kernel.fth` / `ansfile.fth` unchanged; `kernel.s` only changed for emit-hook + embed API surface.
- No dependency on Terminal.app for REPL I/O.

---

## Status — v0.6 (current)

The console `.app` goal above is met. **16ForthCLI is archived and inactive**; this repo is the sole active 16Forth line.

| Area | Notes |
|------|--------|
| Embed `QUIT` / `ABORT` | Return to host under `embed_mode` (no readline hang). |
| Compiler | **Always-threaded ITC only.** Removed: `FL_INLINE`, `N:`, `D:`, `INLINE-ON`/`OFF`, mex, CODE paste, native-convert, EXIT inlinability warnings, JIT code buffer (`host_jit`). |
| Control immediates | Asm `IF`…`THEN`, `BEGIN`…, `DO`/`?DO`/`LOOP`/`+LOOP` — threaded cells only. |
| Loop indices | `I` / `J` / `K` as ordinary CODE. |
| Startup | Banner **16Forth 0.6 ready**; app marketing version **0.6**. |
| `SEE` / `HELP` | ITC decompiler; no leading `I`. |
| Timing | `MS@` / `MS`; pictured `<# # #S #>` / `BASE`/`DECIMAL`/`HEX`; `ELAPSED` / `.ELAPSED`. |
| INCLUDE / host files | `INCLUDED`/`INCLUDE`/`FLOAD`/`FROMLIB`, line-oriented `FILE-ECHO`, `\S`, `SOURCE`/`EVALUATE`/`REFILL`, `CHDIR`/`PWD`/`DIR`; Swift FileHost + KernelBridge; app `Library/` → Resources. |
| Vocabularies | ANS Search-Order + 64Forth extras (as in 0.4). |
| Agent | `--agent` / `tools/16forth-agent`. |

**Perf note:** Next serious lever vs 64Forth is TOS-in-register (`x20`), not more compiler expand.

Still deferred vs a full 64Forth-class IDE: Hyper/VIEW/sealed vocabs, `DICT_THREADS` hashing, menus / icon, TOS-in-register.

## Status — v0.5 (historical)

**Last release with inlining** — tag `v0.5`, source-only GitHub release. Auto-inline / `N:` / `D:` / `INLINE-ON`/`OFF` / mex / CODE paste / native-convert; nested mex; FILE-ECHO; agent; `.(` / `C"`. Banner **16Forth 0.5 ready**.

## Status — v0.4 (historical)

Vocabularies / Search-Order; INCLUDE/FileHost; agent channel; user-facing `I:` / `[INLINE]`/`[THREAD]`; banner **16Forth 0.4 ready**.

# 16Forth agent channel

**Public domain.** Headless control so tools (Grok, CI, scripts) can load Forth files and capture console output without driving the GUI.

**Status:** shipped with 16Forth 0.4; current app is **0.5** (rebuild in Xcode if your installed binary is older).

## Why

The GUI app does not treat stdin as a REPL. The agent channel runs the same kernel (`kernel_eval`) with EMIT captured to **stdout** and an optional transcript file.

## Activation

Either:

```text
16Forth --agent …
```

or:

```text
FORTH16_AGENT=1  16Forth …
```

Invoke the **binary inside the bundle**, not `open -a` (open does not give a clean stdout pipe):

```bash
…/16Forth.app/Contents/MacOS/16Forth --agent -e '2 2 + .'
```

Helper:

```bash
./tools/16forth-agent --help
./tools/16forth-agent -e '2 2 + .'
```

Optional: `FORTH16_APP=/path/to/16Forth.app ./tools/16forth-agent -e '2 2 + .'`

## Options

| Flag | Meaning |
|------|---------|
| `-e` / `--eval <line>` | Evaluate one line |
| `-f` / `--file <path>` | `INCLUDE` a file (`--fload` / `--include` aliases) |
| `-c` / `--cwd <path>` | `chdir` before work |
| `-o` / `--out <path>` | Write full transcript to path (stdout always has it) |
| `--repl` | After `-e`/`-f`, read more lines from stdin until EOF or `BYE` |
| `-h` / `--help` | Help |

`-e` and `-f` may repeat; order is preserved.

## Exit status

- `0` — every eval/load returned status 0  
- `1` — usage error, kernel init failure, any non-zero status, or transcript write failure  

Each step is tagged in the transcript:

```text
[16Forth agent] eval: 2 2 + .
4
[16Forth agent] status=0 depth=0
```

## Relation to GUI

Agent mode is a **separate process**. Your interactive 16Forth window is untouched.

## Implementation notes

| File | Role |
|------|------|
| `AppMain.swift` | `@main` — agent branch or `SixteenForthApp.main()` |
| `AgentChannel.swift` | Args, cwd, eval/load, transcript, exit codes |
| `KernelBridge.swift` | `setAgentSyncEmit`, `forceFlushEmitSync`, `loadFile` |
| `tools/16forth-agent` | Find binary + pass `--agent` |

## Build

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -scheme 16Forth -configuration Debug \
  -derivedDataPath build/DerivedData build
```

Smoke:

```bash
./tools/16forth-agent -e '2 2 + .'
```

Expect `4` and `DONE (ok)`.

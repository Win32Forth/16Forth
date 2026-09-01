//
//  AgentChannel.swift
//  16Forth
//
//  Public domain.
//
//  Headless / agent control channel for automation (Grok, CI, scripts).
//  Loads Forth sources, evaluates lines, captures all console EMIT to stdout
//  and an optional transcript file — no GUI required.
//
//  Activation (either):
//    • argv contains `--agent`  (or `-agent`)
//    • environment FORTH16_AGENT=1  (alias: 16FORTH_AGENT=1)
//
//  Usage examples:
//    16Forth --agent -e '2 2 + .'
//    16Forth --agent -f /path/to/script.fth -o /tmp/out.txt
//    16Forth --agent --cwd ~/Documents/Benchmarks -f sieve.fth
//    16Forth --agent --repl < commands.txt
//    FORTH16_AGENT=1 16Forth -e 'WORDS'
//
//  Options (order of -e / -f is preserved):
//    --agent | -agent     enable agent mode (required unless env set)
//    -e <text>            evaluate one Forth line
//    -f <path>            INCLUDE / FLOAD a file (absolute or relative)
//    -c | --cwd <path>    chdir before work (also sets logical FileHost cwd)
//    -o | --out <path>    write full transcript to file (also always stdout)
//    --repl               after scripts, read lines from stdin until EOF
//    -h | --help          print this help and exit 0
//
//  Exit status:
//    0  all evaluations returned 0 (ok)
//    1  usage / kernel init / any eval non-zero / I/O error
//

import Foundation
#if os(macOS)
import AppKit
#endif

enum AgentChannel {

    /// True when process should run headless agent instead of the GUI.
    static var isRequested: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["FORTH16_AGENT"] == "1" || env["16FORTH_AGENT"] == "1" {
            return true
        }
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--agent") || args.contains("-agent")
    }

    /// Parse argv and run; does not return (calls Foundation.exit).
    static func runAndExit() -> Never {
        let code = run()
        Foundation.exit(code)
    }

    /// Parse argv, run agent session, return process exit code.
    @discardableResult
    static func run() -> Int32 {
        let parsed = parseArgs(ProcessInfo.processInfo.arguments)
        if parsed.help {
            printHelp()
            return 0
        }

        #if os(macOS)
        // Minimal AppKit so any host code that touches NSApp does not crash.
        // No windows; we never run the SwiftUI scene.
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        #endif

        var transcript = ""
        let transcriptLock = NSLock()
        let appendOut: (String) -> Void = { s in
            guard !s.isEmpty else { return }
            transcriptLock.lock()
            transcript += s
            transcriptLock.unlock()
            if let data = s.data(using: .utf8) {
                FileHandle.standardOutput.write(data)
            }
        }

        let kernel = KernelBridge.shared
        kernel.setAgentSyncEmit(true)
        kernel.onEmit = { chunk in
            appendOut(chunk)
        }
        // Flush anything buffered during KernelBridge.init before onEmit was set.
        kernel.forceFlushEmitSync()

        appendOut("[16Forth agent] start\n")
        kernel.startIfNeeded()
        kernel.forceFlushEmitSync()
        if !kernel.isKernelLive {
            appendOut("[16Forth agent] FATAL: kernel cold start failed\n")
            writeTranscriptIfNeeded(parsed.outPath, transcript)
            return 1
        }

        if let cwd = parsed.cwd {
            let fm = FileManager.default
            if fm.changeCurrentDirectoryPath(cwd) {
                FileHost.shared.logicalCurrentDirectory = cwd
                appendOut("[16Forth agent] cwd \(cwd)\n")
            } else {
                appendOut("[16Forth agent] ERROR: cannot chdir \(cwd)\n")
                writeTranscriptIfNeeded(parsed.outPath, transcript)
                return 1
            }
        }

        var failed = false
        for step in parsed.steps {
            switch step {
            case .eval(let line):
                appendOut("[16Forth agent] eval: \(line)\n")
                let st = kernel.evaluate(line)
                kernel.forceFlushEmitSync()
                appendOut("[16Forth agent] status=\(st) depth=\(kernel.dataStackDepth)\n")
                if st != 0 { failed = true }
            case .file(let path):
                appendOut("[16Forth agent] load: \(path)\n")
                let st = kernel.loadFile(named: path)
                kernel.forceFlushEmitSync()
                appendOut("[16Forth agent] status=\(st) depth=\(kernel.dataStackDepth)\n")
                if st != 0 { failed = true }
            }
        }

        if parsed.repl {
            appendOut("[16Forth agent] repl (stdin) — EOF to finish\n")
            while let line = readLine(strippingNewline: true) {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                if t.uppercased() == "BYE" {
                    appendOut("[16Forth agent] BYE\n")
                    break
                }
                let st = kernel.evaluate(t)
                kernel.forceFlushEmitSync()
                appendOut("ok(\(kernel.dataStackDepth))> ")
                if st != 0 { failed = true }
            }
            appendOut("\n")
        }

        if parsed.steps.isEmpty && !parsed.repl {
            appendOut("[16Forth agent] nothing to do (use -e, -f, or --repl)\n")
            appendOut("Try: 16Forth --agent --help\n")
            failed = true
        }

        appendOut(failed
            ? "[16Forth agent] DONE (failed)\n"
            : "[16Forth agent] DONE (ok)\n")

        if !writeTranscriptIfNeeded(parsed.outPath, transcript) {
            failed = true
        }

        kernel.setAgentSyncEmit(false)
        return failed ? 1 : 0
    }

    // MARK: - Args

    private enum Step {
        case eval(String)
        case file(String)
    }

    private struct Parsed {
        var help = false
        var repl = false
        var cwd: String?
        var outPath: String?
        var steps: [Step] = []
    }

    private static func parseArgs(_ argv: [String]) -> Parsed {
        var p = Parsed()
        var i = 1 // skip argv[0]
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--agent", "-agent":
                i += 1
            case "-h", "--help", "-help":
                p.help = true
                i += 1
            case "--repl":
                p.repl = true
                i += 1
            case "-e", "--eval":
                i += 1
                guard i < argv.count else {
                    p.help = true
                    break
                }
                p.steps.append(.eval(argv[i]))
                i += 1
            case "-f", "--file", "--fload", "--include":
                i += 1
                guard i < argv.count else {
                    p.help = true
                    break
                }
                p.steps.append(.file(argv[i]))
                i += 1
            case "-c", "--cwd":
                i += 1
                guard i < argv.count else {
                    p.help = true
                    break
                }
                p.cwd = (argv[i] as NSString).expandingTildeInPath
                i += 1
            case "-o", "--out", "--transcript":
                i += 1
                guard i < argv.count else {
                    p.help = true
                    break
                }
                p.outPath = (argv[i] as NSString).expandingTildeInPath
                i += 1
            default:
                if a.hasPrefix("-") {
                    FileHandle.standardError.write(Data("[16Forth agent] unknown option: \(a)\n".utf8))
                }
                i += 1
            }
        }
        return p
    }

    private static func writeTranscriptIfNeeded(_ path: String?, _ text: String) -> Bool {
        guard let path, !path.isEmpty else { return true }
        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            let note = "[16Forth agent] transcript → \(path)\n"
            FileHandle.standardOutput.write(Data(note.utf8))
            return true
        } catch {
            let msg = "[16Forth agent] ERROR writing transcript \(path): \(error)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            return false
        }
    }

    private static func printHelp() {
        let help = """
        16Forth agent channel — headless load / eval / capture

        16Forth --agent [options]

        Options:
          -e, --eval <line>       Evaluate a Forth line
          -f, --file <path>       INCLUDE file (also --fload / --include)
          -c, --cwd <path>        Change directory before work
          -o, --out <path>        Write full transcript to path (stdout always)
          --repl                  Read further lines from stdin until EOF or BYE
          -h, --help              This help

        Environment:
          FORTH16_AGENT=1         Same as --agent (shell-safe name)

        Examples:
          16Forth --agent -e '2 2 + .'
          16Forth --agent -c ~/proj -f smoke.fth -o /tmp/out.txt
          16Forth --agent --repl < session.txt

        Notes:
          • Prefer invoking the binary inside the app bundle, not `open -a`.
          • GUI instance (if already open) is separate; agent is a new process.
          • Exit 0 = all steps status 0; exit 1 = any failure.

        """
        print(help, terminator: "")
    }
}

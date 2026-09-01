//
//  KernelBridge.swift
//  16Forth
//
//  Public domain.
//
//  Slim host bridge: emit hooks, file/INCLUDE hooks, cold start, line eval.
//

import Foundation
import AppKit

@_silgen_name("kernel_cold_start")
func kernel_cold_start()

@_silgen_name("kernel_eval")
func kernel_eval(_ line: UnsafePointer<CChar>?, _ n: Int) -> Int32

@_silgen_name("kernel_data_depth")
func kernel_data_depth() -> Int32

@_silgen_name("kernel_set_emit")
func kernel_set_emit(_ fn: (@convention(c) (Int32) -> Void)?)

@_silgen_name("kernel_set_emit_buf")
func kernel_set_emit_buf(_ fn: (@convention(c) (UnsafePointer<CChar>?, Int) -> Void)?)

@_silgen_name("kernel_set_fromlib")
private func kernel_set_fromlib(_ fn: (@convention(c) () -> Void)?)

@_silgen_name("kernel_set_fromlib_clear")
private func kernel_set_fromlib_clear(_ fn: (@convention(c) () -> Void)?)

@_silgen_name("kernel_set_end_include")
private func kernel_set_end_include(_ fn: (@convention(c) () -> Void)?)

@_silgen_name("kernel_set_load_file")
private func kernel_set_load_file(
    _ fn: (@convention(c) (
        UnsafePointer<CChar>?,
        Int,
        UnsafeMutablePointer<UnsafePointer<CChar>?>?,
        UnsafeMutablePointer<Int>?
    ) -> Int32)?
)

@_silgen_name("kernel_set_resolve_key")
private func kernel_set_resolve_key(
    _ fn: (@convention(c) (
        UnsafePointer<CChar>?,
        Int,
        UnsafeMutablePointer<CChar>?,
        Int,
        UnsafeMutablePointer<Int>?
    ) -> Int32)?
)

@_silgen_name("kernel_set_last_load_key")
private func kernel_set_last_load_key(
    _ fn: (@convention(c) (
        UnsafeMutablePointer<CChar>?,
        Int,
        UnsafeMutablePointer<Int>?
    ) -> Int32)?
)

@_silgen_name("kernel_set_chdir")
private func kernel_set_chdir(
    _ fn: (@convention(c) (UnsafePointer<CChar>?, Int) -> Void)?
)

@_silgen_name("kernel_set_pwd")
private func kernel_set_pwd(_ fn: (@convention(c) () -> Void)?)

@_silgen_name("kernel_set_dir")
private func kernel_set_dir(
    _ fn: (@convention(c) (UnsafePointer<CChar>?, Int) -> Void)?
)

@_silgen_name("kernel_take_repl_batch_stop")
private func kernel_take_repl_batch_stop() -> Int32

@_silgen_name("forth_io_init")
func forth_io_init()

private weak var kernelHookTarget: KernelBridge?

private let kernelEmitTrampoline: @convention(c) (Int32) -> Void = { c in
    kernelHookTarget?.handleEmit(c)
}

private let kernelEmitBufTrampoline: @convention(c) (UnsafePointer<CChar>?, Int) -> Void = { buf, n in
    guard let buf, n > 0 else { return }
    kernelHookTarget?.handleEmitBytes(buf, count: n)
}

private let kernelFromlibTrampoline: @convention(c) () -> Void = {
    FileHost.shared.armFromLibrary()
}

private let kernelFromlibClearTrampoline: @convention(c) () -> Void = {
    FileHost.shared.clearFromLibrary()
}

private let kernelEndIncludeTrampoline: @convention(c) () -> Void = {
    FileHost.shared.endLoadCwdIfNeeded()
}

private let kernelLoadFileTrampoline: @convention(c) (
    UnsafePointer<CChar>?,
    Int,
    UnsafeMutablePointer<UnsafePointer<CChar>?>?,
    UnsafeMutablePointer<Int>?
) -> Int32 = { path, pathLen, outPtr, outLen in
    FileHost.shared.loadFileForKernel(
        path: path,
        pathLen: pathLen,
        outPtr: outPtr,
        outLen: outLen
    )
}

private let kernelResolveKeyTrampoline: @convention(c) (
    UnsafePointer<CChar>?,
    Int,
    UnsafeMutablePointer<CChar>?,
    Int,
    UnsafeMutablePointer<Int>?
) -> Int32 = { path, pathLen, out, outMax, outLen in
    guard let key = FileHost.shared.resolveRegistryKey(path: path, pathLen: pathLen),
          let out, outMax > 0 else { return -1 }
    let bytes = Array(key.utf8)
    let n = min(bytes.count, outMax)
    for i in 0..<n { out[i] = CChar(bitPattern: bytes[i]) }
    outLen?.pointee = n
    return 0
}

private let kernelLastLoadKeyTrampoline: @convention(c) (
    UnsafeMutablePointer<CChar>?,
    Int,
    UnsafeMutablePointer<Int>?
) -> Int32 = { out, outMax, outLen in
    guard let key = FileHost.shared.lastLoadRegistryKey, !key.isEmpty,
          let out, outMax > 0 else { return -1 }
    let bytes = Array(key.utf8)
    let n = min(bytes.count, outMax)
    for i in 0..<n { out[i] = CChar(bitPattern: bytes[i]) }
    outLen?.pointee = n
    return 0
}

private let kernelChdirTrampoline: @convention(c) (UnsafePointer<CChar>?, Int) -> Void = { path, pathLen in
    if path == nil || pathLen == 0 {
        FileHost.shared.presentDirectoryPicker()
    } else {
        FileHost.shared.changeDirectory(spec: String(cString: path!))
    }
}

private let kernelPwdTrampoline: @convention(c) () -> Void = {
    FileHost.shared.printPwd()
}

private let kernelDirTrampoline: @convention(c) (UnsafePointer<CChar>?, Int) -> Void = { path, pathLen in
    if path == nil || pathLen == 0 {
        FileHost.shared.listDirectory(spec: "")
    } else {
        FileHost.shared.listDirectory(spec: String(cString: path!))
    }
}

final class KernelBridge {
    static let shared = KernelBridge()

    /// Called on the main queue with decoded engine output.
    var onEmit: ((String) -> Void)?

    /// Set when `\S` runs on console SOURCE; host may stop remaining paste lines.
    private(set) var replBatchStopRequested = false

    private let forthQueue = DispatchQueue(label: "16Forth.kernel")
    private let evalLock = NSLock()
    private let emitLock = NSLock()
    private var evaluating = false
    private var started = false

    private var pendingBytes = Data()
    private var emitFlushScheduled = false

    /// Agent / headless mode: deliver EMIT synchronously (no main-queue defer).
    private var agentSyncEmit = false

    private init() {
        kernelHookTarget = self
        kernel_set_emit(kernelEmitTrampoline)
        kernel_set_emit_buf(kernelEmitBufTrampoline)
        installFileHooks()
        FileHost.shared.onMessage = { [weak self] s in
            self?.handleEmitString(s)
        }
    }

    /// Enable synchronous emit delivery (agent CLI). Call before evaluate.
    func setAgentSyncEmit(_ on: Bool) {
        agentSyncEmit = on
        if on {
            forceFlushEmitSync()
        }
    }

    /// Drain pending emit buffer to `onEmit` immediately on this thread.
    func forceFlushEmitSync() {
        drainEmitBuffer()
    }

    private func installFileHooks() {
        kernel_set_fromlib(kernelFromlibTrampoline)
        kernel_set_fromlib_clear(kernelFromlibClearTrampoline)
        kernel_set_end_include(kernelEndIncludeTrampoline)
        kernel_set_load_file(kernelLoadFileTrampoline)
        kernel_set_resolve_key(kernelResolveKeyTrampoline)
        kernel_set_last_load_key(kernelLastLoadKeyTrampoline)
        kernel_set_chdir(kernelChdirTrampoline)
        kernel_set_pwd(kernelPwdTrampoline)
        kernel_set_dir(kernelDirTrampoline)
    }

    /// Start the engine once (JIT buffer + cold start). Safe to call repeatedly.
    func startIfNeeded() {
        evalLock.lock()
        if started {
            evalLock.unlock()
            return
        }
        started = true
        evalLock.unlock()

        forth_io_init()
        kernel_cold_start()
        FileHost.shared.releaseIncludeBuffers()
        FileHost.shared.endAllLoadCwds()
        FileHost.shared.endAllFromLibraryLoads()
        drainEmitBuffer()
    }

    /// Data-stack depth after the last eval / cold start.
    var dataDepth: Int {
        Int(kernel_data_depth())
    }

    /// Alias used by the agent channel (matches 64Forth naming).
    var dataStackDepth: Int { dataDepth }

    /// True after a successful cold start.
    var isKernelLive: Bool { started }

    /// INCLUDE / FLOAD a file by path (absolute or relative to logical cwd).
    @discardableResult
    func loadFile(named name: String) -> Int32 {
        let spec = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else {
            return evaluate("FLOAD")
        }
        // Quote so paths with spaces round-trip through INCLUDE's parser.
        let escaped = spec.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return evaluate("INCLUDE \"\(escaped)\"")
    }

    /// Flush any bytes buffered before the UI sink was attached.
    func attachEmitSink(_ sink: @escaping (String) -> Void) {
        onEmit = sink
        if agentSyncEmit {
            drainEmitBuffer()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.drainEmitBuffer()
            }
        }
    }

    /// Clear the `\S` paste-stop flag (call before a new multi-line paste).
    func clearReplBatchStop() {
        replBatchStopRequested = false
        _ = kernel_take_repl_batch_stop()
    }

    /// Evaluate one line of Forth. Returns when the line finishes.
    @discardableResult
    func evaluate(_ line: String) -> Int32 {
        startIfNeeded()

        evalLock.lock()
        if evaluating {
            evalLock.unlock()
            return -3
        }
        evaluating = true
        evalLock.unlock()

        var result: Int32 = 0
        let sem = DispatchSemaphore(value: 0)
        forthQueue.async {
            defer {
                FileHost.shared.releaseIncludeBuffers()
                FileHost.shared.endAllLoadCwds()
                FileHost.shared.endAllFromLibraryLoads()
                if FileHost.shared.fromLibraryArmed {
                    FileHost.shared.clearFromLibrary()
                }
                if self.agentSyncEmit || Thread.isMainThread {
                    self.drainEmitBuffer()
                } else {
                    DispatchQueue.main.sync { self.drainEmitBuffer() }
                }
                self.evalLock.lock()
                self.evaluating = false
                self.evalLock.unlock()
                sem.signal()
            }
            let bytes = Array(line.utf8)
            result = bytes.withUnsafeBufferPointer { buf in
                kernel_eval(UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: CChar.self),
                            line.utf8.count)
            }
            if kernel_take_repl_batch_stop() != 0 {
                self.replBatchStopRequested = true
            }
        }

        if Thread.isMainThread {
            while sem.wait(timeout: .now() + 0.01) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
            }
        } else {
            sem.wait()
        }
        return result
    }

    fileprivate func handleEmit(_ c: Int32) {
        if c < 0 { return }
        emitLock.lock()
        pendingBytes.append(UInt8(truncatingIfNeeded: c))
        emitLock.unlock()
        scheduleEmitFlush()
    }

    fileprivate func handleEmitBytes(_ buf: UnsafePointer<CChar>, count: Int) {
        emitLock.lock()
        pendingBytes.append(Data(bytes: buf, count: count))
        emitLock.unlock()
        scheduleEmitFlush()
    }

    fileprivate func handleEmitString(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        emitLock.lock()
        pendingBytes.append(data)
        emitLock.unlock()
        scheduleEmitFlush()
    }

    private func scheduleEmitFlush() {
        if agentSyncEmit {
            drainEmitBuffer()
            return
        }
        emitLock.lock()
        if emitFlushScheduled {
            emitLock.unlock()
            return
        }
        emitFlushScheduled = true
        emitLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.drainEmitBuffer()
        }
    }

    private func drainEmitBuffer() {
        emitLock.lock()
        emitFlushScheduled = false
        guard !pendingBytes.isEmpty else {
            emitLock.unlock()
            return
        }
        let data = pendingBytes
        pendingBytes.removeAll(keepingCapacity: true)
        emitLock.unlock()
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        onEmit?(text)
    }
}

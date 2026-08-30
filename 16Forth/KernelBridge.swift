//
//  KernelBridge.swift
//  16Forth
//
//  Public domain.
//
//  Slim host bridge: emit hooks, cold start, line eval on a serial queue.
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

final class KernelBridge {
    static let shared = KernelBridge()

    /// Called on the main queue with decoded engine output.
    var onEmit: ((String) -> Void)?

    private let forthQueue = DispatchQueue(label: "16Forth.kernel")
    private let evalLock = NSLock()
    private let emitLock = NSLock()
    private var evaluating = false
    private var started = false

    private var pendingBytes = Data()
    private var emitFlushScheduled = false

    private init() {
        kernelHookTarget = self
        kernel_set_emit(kernelEmitTrampoline)
        kernel_set_emit_buf(kernelEmitBufTrampoline)
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
        drainEmitBuffer()
    }

    /// Data-stack depth after the last eval / cold start.
    var dataDepth: Int {
        Int(kernel_data_depth())
    }

    /// Flush any bytes buffered before the UI sink was attached.
    func attachEmitSink(_ sink: @escaping (String) -> Void) {
        onEmit = sink
        DispatchQueue.main.async { [weak self] in
            self?.drainEmitBuffer()
        }
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
                if Thread.isMainThread {
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

    private func scheduleEmitFlush() {
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

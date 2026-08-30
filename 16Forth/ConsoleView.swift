//
//  ConsoleView.swift
//  16Forth
//
//  Public domain.
//
//  Full-window protected console (64Forth-style, without facility/SZ-EDITOR).
//  One NSTextView fills the window: scrollable transcript + type at the end.
//  Engine output is protected; only text after the last prompt is editable.
//  Return commits → KernelBridge.evaluate; Up/Down recall history.
//

import SwiftUI
import AppKit

extension Notification.Name {
    static let clearConsole = Notification.Name("SixteenForthClearConsole")
}

private let banner = "=== 16Forth 0.3 ===\n"

struct ConsoleView: View {
    @State private var consoleText = banner
    @State private var commandHistory: [String] = []
    @State private var historyIndex = -1
    @State private var isRecallingHistory = false

    /// UTF-16 length of consoleText after last engine/host output; only text after this is input.
    @State private var protectedUTF16Length = 0
    @State private var protectedSnapshot = ""
    @State private var isRevertingProtectedEdit = false
    @State private var isProgrammaticConsoleAppend = false
    @State private var isHandlingReturn = false
    @State private var pinCaretRequest = 0
    @State private var consoleTextView: NSTextView?
    @State private var didStart = false

    @FocusState private var isFocused: Bool

    private let kernel = KernelBridge.shared

    var body: some View {
        ConsoleTextView(
            text: $consoleText,
            isFocused: $isFocused,
            pinCaretRequest: $pinCaretRequest,
            editableStartUTF16: protectedUTF16Length,
            onReturnPressed: { handleReturnKey() },
            onHistoryUp: { recallHistory(up: true) },
            onHistoryDown: { recallHistory(up: false) },
            onTextViewReady: { textView in
                DispatchQueue.main.async {
                    consoleTextView = textView
                }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focused($isFocused)
        .onChange(of: consoleText) { oldValue, newValue in
            handleConsoleTextChange(oldValue: oldValue, newValue: newValue)
        }
        .onAppear(perform: handleConsoleAppear)
        .onReceive(NotificationCenter.default.publisher(for: .clearConsole)) { _ in
            clearConsole()
        }
    }

    // MARK: - Startup

    private func handleConsoleAppear() {
        guard !didStart else {
            isFocused = true
            return
        }
        didStart = true
        isFocused = true

        kernel.attachEmitSink { chunk in
            appendEngineOutput(chunk)
        }
        isProgrammaticConsoleAppend = true
        kernel.startIfNeeded()
        markProtectedThroughEndOfText()
        appendPrompt()
        isProgrammaticConsoleAppend = false
        keepCursorVisible(followPrompt: true)
    }

    // MARK: - Protected region

    private func markProtectedThroughEndOfText() {
        protectedSnapshot = consoleText
        protectedUTF16Length = (consoleText as NSString).length
    }

    private func markProtected(throughUTF16 length: Int) {
        let ns = consoleText as NSString
        let clamped = min(max(0, length), ns.length)
        protectedUTF16Length = clamped
        protectedSnapshot = ns.substring(to: clamped)
    }

    private func appendEngineOutput(_ s: String) {
        guard !s.isEmpty else { return }
        let wasProg = isProgrammaticConsoleAppend
        isProgrammaticConsoleAppend = true
        consoleText += s
        markProtectedThroughEndOfText()
        isProgrammaticConsoleAppend = wasProg
    }

    private func appendPrompt() {
        let n = kernel.dataDepth
        appendEngineOutput("ok(\(n))> ")
    }

    private func userPortion(of fullText: String) -> String {
        let ns = fullText as NSString
        let start = min(protectedUTF16Length, ns.length)
        return ns.substring(from: start)
    }

    private func handleConsoleTextChange(oldValue: String, newValue: String) {
        if isRevertingProtectedEdit {
            isRevertingProtectedEdit = false
            return
        }
        if isProgrammaticConsoleAppend {
            return
        }
        let newLen = (newValue as NSString).length
        if newLen < protectedUTF16Length
            || (!protectedSnapshot.isEmpty && !newValue.hasPrefix(protectedSnapshot)) {
            isRevertingProtectedEdit = true
            consoleText = oldValue
            return
        }
        checkForCommandExecution(newValue)
        // Scroll to the caret only — do not pin to end (user may be editing mid-line).
        scrollToCaret(pinToEnd: false)
    }

    // MARK: - Return / commit

    @discardableResult
    private func handleReturnKey() -> Bool {
        guard !isHandlingReturn else { return true }
        isHandlingReturn = true
        defer {
            DispatchQueue.main.async {
                isHandlingReturn = false
            }
        }
        commitUserInput()
        return true
    }

    private func commitUserInput() {
        guard !isRecallingHistory else { return }

        let portion = userPortion(of: consoleText)

        if portion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            commitEmptyLine()
            return
        }

        let candidateLines = filteredCommandLines(from: portion, dropTrailingEmpty: false)
        if candidateLines.isEmpty {
            commitEmptyLine()
            return
        }

        finalizeCommittedInputLine()
        dispatchCandidateLines(candidateLines)
    }

    private func filteredCommandLines(from userPortion: String, dropTrailingEmpty: Bool) -> [String] {
        var lines = userPortion.components(separatedBy: .newlines)
        if dropTrailingEmpty,
           let last = lines.last,
           last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { raw in
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty && !t.hasPrefix("===") else { return false }
                if t == "ok>" || t.hasPrefix("ok>") || t.hasPrefix("ok(") { return false }
                if t == "ok" || t.hasSuffix(" ok") { return false }
                return true
            }
    }

    private func finalizeCommittedInputLine() {
        pinCaretRequest += 1
        isProgrammaticConsoleAppend = true
        if !consoleText.hasSuffix("\n") {
            consoleText += "\n"
        }
        markProtectedThroughEndOfText()
        isProgrammaticConsoleAppend = false
    }

    private func commitEmptyLine() {
        isProgrammaticConsoleAppend = true
        if !consoleText.hasSuffix("\n") {
            consoleText += "\n"
        }
        markProtectedThroughEndOfText()
        appendPrompt()
        isProgrammaticConsoleAppend = false
        keepCursorVisible(followPrompt: true)
    }

    private func dispatchCandidateLines(_ candidateLines: [String]) {
        for line in candidateLines {
            if commandHistory.last != line {
                commandHistory.append(line)
            }
            if commandHistory.count > 50 {
                commandHistory.removeFirst()
            }
        }
        historyIndex = -1

        isProgrammaticConsoleAppend = true
        for line in candidateLines {
            _ = kernel.evaluate(line)
            markProtectedThroughEndOfText()
        }
        if !consoleText.hasSuffix("\n") {
            consoleText += "\n"
            markProtectedThroughEndOfText()
        }
        appendPrompt()
        isProgrammaticConsoleAppend = false
        keepCursorVisible(followPrompt: true)
    }

    /// Multi-line paste ending with newline: commit without an extra Return.
    private func checkForCommandExecution(_ fullText: String) {
        guard !isRecallingHistory else { return }
        guard (fullText as NSString).length > protectedUTF16Length else { return }
        let portion = userPortion(of: fullText)

        let lines = portion.components(separatedBy: .newlines)
        guard let lastLine = lines.last else { return }
        let trimmedLast = lastLine.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedLast.isEmpty && lines.count >= 2 {
            let candidateLines = filteredCommandLines(from: portion, dropTrailingEmpty: true)
            if candidateLines.isEmpty {
                markProtected(throughUTF16: (fullText as NSString).length)
                return
            }
            finalizeCommittedInputLine()
            dispatchCandidateLines(candidateLines)
        }
    }

    // MARK: - History

    private func recallHistory(up: Bool) {
        guard !commandHistory.isEmpty else { return }

        if up {
            historyIndex = min(historyIndex + 1, commandHistory.count - 1)
        } else {
            historyIndex = max(historyIndex - 1, -1)
        }

        isRecallingHistory = true
        isProgrammaticConsoleAppend = true
        clearCurrentInputLine()
        if historyIndex >= 0 {
            let selected = commandHistory[commandHistory.count - 1 - historyIndex]
            consoleText += selected
        }
        isProgrammaticConsoleAppend = false
        isRecallingHistory = false
        keepCursorVisible(followPrompt: true)
    }

    private func clearCurrentInputLine() {
        let ns = consoleText as NSString
        if ns.length > protectedUTF16Length {
            consoleText = ns.substring(to: protectedUTF16Length)
        }
    }

    // MARK: - Clear / scroll

    private func clearConsole() {
        isProgrammaticConsoleAppend = true
        consoleText = banner
        markProtectedThroughEndOfText()
        appendPrompt()
        isProgrammaticConsoleAppend = false
        keepCursorVisible(followPrompt: true)
    }

    private func keepCursorVisible(followPrompt: Bool = false) {
        scrollToCaret(pinToEnd: followPrompt)
    }

    /// Scroll the console to the insertion point. Only pin the caret to the end
    /// when intentionally following a new prompt / history recall / clear.
    private func scrollToCaret(pinToEnd: Bool) {
        if pinToEnd {
            pinCaretRequest += 1
        }
        if let textView = consoleTextView {
            ConsoleTextView.scheduleScrollToInsertionPoint(in: textView, pinCaret: pinToEnd)
        }
    }
}

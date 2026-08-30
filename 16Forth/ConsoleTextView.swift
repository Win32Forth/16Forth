//
//  ConsoleTextView.swift
//  16Forth
//
//  Public domain.
//
//  Single-pane console with a protected engine-output prefix.
//  Stripped from 64Forth: no facility / SZ-EDITOR / Hyper / KEY routing.
//

import SwiftUI
import AppKit

/// NSTextView that keeps the caret out of the protected transcript prefix.
final class ConsoleNSTextView: NSTextView {
    /// First UTF-16 index the user may edit.
    var editableStartUTF16: Int = 0

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Never insert into the protected prompt; clamp to the input region.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let end = (string as NSString).length
        let start = min(max(0, editableStartUTF16), end)
        var r = replacementRange
        if r.location == NSNotFound {
            r = selectedRange()
        }
        if r.location < start {
            r = NSRange(location: end, length: 0)
            setSelectedRange(r)
        }
        super.insertText(insertString, replacementRange: r)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        let sel = selectedRange()
        if sel.length == 0 {
            let end = (string as NSString).length
            let start = min(max(0, editableStartUTF16), end)
            if sel.location < start {
                setSelectedRange(NSRange(location: end, length: 0))
            }
        }
    }
}

/// AppKit console editor. SwiftUI `TextEditor` does not protect a prefix or
/// reliably scroll to the insertion point after programmatic appends.
struct ConsoleTextView: NSViewRepresentable {
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    @Binding var pinCaretRequest: Int
    /// First UTF-16 index the user may edit (engine/protected output is before this).
    var editableStartUTF16: Int
    var onReturnPressed: () -> Bool
    var onHistoryUp: () -> Void = {}
    var onHistoryDown: () -> Void = {}
    var onTextViewReady: (NSTextView) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        // Fill the SwiftUI-proposed size (full window console, not a one-line field).
        scrollView.autoresizingMask = [.width, .height]

        let textView = ConsoleNSTextView()
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scrollView.documentView = textView

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.string = text
        let end = (text as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        textView.editableStartUTF16 = editableStartUTF16

        context.coordinator.textView = textView
        onTextViewReady(textView)
        DispatchQueue.main.async {
            Self.resizeTextViewToFitContent(textView)
            Self.scrollToEndNow(in: textView, pinCaret: true)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        if let ctv = textView as? ConsoleNSTextView {
            ctv.editableStartUTF16 = editableStartUTF16
        }

        var shouldScroll = false
        var pinOnScroll = false
        let needsPinCaret = context.coordinator.lastHandledPinCaretRequest != pinCaretRequest
        if needsPinCaret {
            context.coordinator.lastHandledPinCaretRequest = pinCaretRequest
        }

        if textView.string != text {
            let oldString = textView.string
            let selected = textView.selectedRange()
            let end = (text as NSString).length
            let oldEnd = (oldString as NSString).length
            let isPrefixAppend = text.hasPrefix(oldString) && end > oldEnd

            context.coordinator.isProgrammaticUpdate = true
            if isPrefixAppend {
                let suffix = (text as NSString).substring(from: oldEnd)
                if let storage = textView.textStorage {
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: oldEnd, length: 0), with: suffix)
                    storage.endEditing()
                } else {
                    textView.string = text
                }
            } else {
                textView.string = text
            }
            context.coordinator.isProgrammaticUpdate = false

            if needsPinCaret || isPrefixAppend || selected.location >= oldEnd {
                textView.setSelectedRange(NSRange(location: end, length: 0))
                shouldScroll = true
                pinOnScroll = true
            } else if selected.location <= end {
                textView.setSelectedRange(selected)
                shouldScroll = true
                pinOnScroll = false
            } else {
                textView.setSelectedRange(NSRange(location: end, length: 0))
                shouldScroll = true
                pinOnScroll = true
            }
            Self.resizeTextViewToFitContent(textView)
        } else if needsPinCaret {
            let end = (text as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            shouldScroll = true
            pinOnScroll = true
            Self.resizeTextViewToFitContent(textView)
        }

        if shouldScroll {
            Self.scheduleScrollToInsertionPoint(in: textView, pinCaret: pinOnScroll)
        }

        // Keep insertion point out of the protected prompt.
        let end = (textView.string as NSString).length
        let start = min(max(0, editableStartUTF16), end)
        let sel = textView.selectedRange()
        if sel.length == 0, sel.location < start {
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }

        if isFocused, let window = scrollView.window, window.firstResponder !== textView {
            window.makeFirstResponder(textView)
        }
    }

    static func scheduleScrollToInsertionPoint(in textView: NSTextView, pinCaret: Bool = true) {
        scrollToEndNow(in: textView, pinCaret: pinCaret)
        DispatchQueue.main.async {
            scrollToEndNow(in: textView, pinCaret: pinCaret)
        }
    }

    static func scrollToEndNow(in textView: NSTextView, pinCaret: Bool = true) {
        resizeTextViewToFitContent(textView)
        if pinCaret {
            let end = (textView.string as NSString).length
            if end > 0 {
                textView.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
        scrollToShowInsertionPoint(in: textView)
    }

    static func appendTextPreservingScroll(_ suffix: String, to textView: NSTextView) {
        guard !suffix.isEmpty else { return }
        let oldLen = (textView.string as NSString).length
        if let storage = textView.textStorage {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: oldLen, length: 0), with: suffix)
            storage.endEditing()
        } else {
            textView.string = textView.string + suffix
        }
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: end, length: 0))
        scrollToEndNow(in: textView)
    }

    private static func resizeTextViewToFitContent(_ textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)

        let usedRect = layoutManager.usedRect(for: textContainer)
        var contentBottom = usedRect.maxY
        let extraRect = layoutManager.extraLineFragmentRect
        if extraRect.height > 0, layoutManager.extraLineFragmentTextContainer === textContainer {
            contentBottom = max(contentBottom, extraRect.maxY)
        }

        let inset = textView.textContainerInset
        let targetHeight = max(
            contentBottom + inset.height * 2,
            textView.enclosingScrollView?.contentSize.height ?? 0
        )
        var frame = textView.frame
        if abs(frame.size.height - targetHeight) > 0.5 {
            frame.size.height = targetHeight
            textView.frame = frame
        }
    }

    fileprivate static func scrollToShowInsertionPoint(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = textView.enclosingScrollView else { return }

        layoutManager.ensureLayout(for: textContainer)

        let range = textView.selectedRange()
        let length = (textView.string as NSString).length
        let atEnd = range.location >= length

        if atEnd {
            scrollToDocumentBottom(
                textView: textView,
                scrollView: scrollView,
                layoutManager: layoutManager,
                textContainer: textContainer
            )
        } else if length > 0 {
            textView.scrollRangeToVisible(NSRange(location: range.location, length: max(range.length, 1)))
        }
    }

    private static func scrollToDocumentBottom(
        textView: NSTextView,
        scrollView: NSScrollView,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) {
        layoutManager.ensureLayout(for: textContainer)

        var contentBottom = layoutManager.usedRect(for: textContainer).maxY
        let extraRect = layoutManager.extraLineFragmentRect
        if extraRect.height > 0, layoutManager.extraLineFragmentTextContainer === textContainer {
            contentBottom = max(contentBottom, extraRect.maxY)
        }

        let origin = textView.textContainerOrigin
        let inset = textView.textContainerInset
        let documentBottom = contentBottom + origin.y + inset.height
        let docHeight = max(documentBottom, textView.frame.maxY)

        let clipView = scrollView.contentView
        let clipHeight = clipView.bounds.height
        let targetY = max(0, docHeight - clipHeight)

        if abs(clipView.bounds.origin.y - targetY) > 0.5 {
            clipView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }

        let len = (textView.string as NSString).length
        if len > 0 {
            textView.scrollRangeToVisible(NSRange(location: len, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConsoleTextView
        weak var textView: NSTextView?
        var isProgrammaticUpdate = false
        var lastHandledPinCaretRequest = 0

        init(parent: ConsoleTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView else { return }
            parent.text = textView.string
        }

        /// Refuse edits that would change the protected engine-output prefix.
        /// Selection/copy of history is still allowed.
        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            let len = (textView.string as NSString).length
            let minLoc = min(max(0, parent.editableStartUTF16), len)

            if affectedCharRange.location < minLoc {
                guard let replacement = replacementString, !replacement.isEmpty else {
                    return false
                }
                let end = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: end, length: 0))
                if let storage = textView.textStorage {
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: end, length: 0), with: replacement)
                    storage.endEditing()
                } else {
                    textView.insertText(replacement, replacementRange: NSRange(location: end, length: 0))
                }
                let newEnd = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: newEnd, length: 0))
                parent.text = textView.string
                return false
            }
            return true
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return parent.onReturnPressed()
            }

            let minLoc = min(max(0, parent.editableStartUTF16), (textView.string as NSString).length)
            let sel = textView.selectedRange()
            let caretInInputLine = sel.length == 0 && sel.location >= minLoc

            if caretInInputLine {
                if commandSelector == #selector(NSResponder.moveUp(_:)) {
                    parent.onHistoryUp()
                    return true
                }
                if commandSelector == #selector(NSResponder.moveDown(_:)) {
                    parent.onHistoryDown()
                    return true
                }
                if commandSelector == #selector(NSResponder.moveLeft(_:))
                    || commandSelector == #selector(NSResponder.moveBackward(_:)) {
                    if sel.location <= minLoc {
                        return true
                    }
                    textView.setSelectedRange(NSRange(location: sel.location - 1, length: 0))
                    return true
                }
                if commandSelector == #selector(NSResponder.moveWordLeft(_:))
                    || commandSelector == #selector(NSResponder.moveWordBackward(_:))
                    || commandSelector == #selector(NSResponder.moveToBeginningOfLine(_:))
                    || commandSelector == #selector(NSResponder.moveToLeftEndOfLine(_:))
                    || commandSelector == #selector(NSResponder.moveToBeginningOfParagraph(_:))
                    || commandSelector == #selector(NSResponder.pageUp(_:))
                    || commandSelector == #selector(NSResponder.moveToBeginningOfDocument(_:)) {
                    textView.setSelectedRange(NSRange(location: minLoc, length: 0))
                    return true
                }
            }

            return false
        }
    }
}

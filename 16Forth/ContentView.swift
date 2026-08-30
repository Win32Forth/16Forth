//
//  ContentView.swift
//  16Forth
//
//  Public domain.
//

import SwiftUI
import AppKit

@main
struct SixteenForthApp: App {
    var body: some Scene {
        WindowGroup("16Forth") {
            ContentView()
        }
        .defaultSize(width: 800, height: 500)
        .commands {
            CommandMenu("Tools") {
                Button("Clear Console") {
                    NotificationCenter.default.post(name: .clearConsole, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}

struct ContentView: View {
    var body: some View {
        ConsoleView()
            .frame(minWidth: 640, minHeight: 400)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

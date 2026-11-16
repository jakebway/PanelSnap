import SwiftUI
import UIKit

/// Quiet developer console reachable from Settings. Everything the app does with files is logged here.
struct ConsoleView: View {
    @ObservedObject private var console = Console.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if console.lines.isEmpty {
                            Text("Nothing logged yet.")
                                .foregroundStyle(Theme.secondary)
                        }
                        ForEach(Array(console.lines.enumerated()), id: \.offset) { item in
                            Text(item.element)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: item.element))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(item.offset)
                        }
                    }
                    .padding(14)
                }
                .onChange(of: console.lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("Console")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    Button { Console.logEnvironment(reason: "manual") } label: {
                        Label("Run diagnostics", systemImage: "stethoscope")
                    }
                    Button { UIPasteboard.general.string = console.text } label: {
                        Label("Copy all", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: console.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        try? FileManager.default.removeItem(at: Paths.companionCache)
                        try? FileManager.default.removeItem(at: Paths.panelCache)
                        Console.log("cleared cached panels and comic info")
                    } label: {
                        Label("Clear cached panels & info", systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(role: .destructive) { console.clear() } label: {
                        Label("Clear", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            if console.lines.isEmpty { Console.logEnvironment(reason: "opened console") }
        }
    }

    private func color(for line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("failed") { return Color(red: 1, green: 0.45, blue: 0.4) }
        if l.contains("----") { return Theme.accent }
        return Color(white: 0.82)
    }
}

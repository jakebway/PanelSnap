import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Buttons

/// The big "confirm" button: comic yellow with black lettering.
struct YellowButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 15 : 17, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, compact ? 16 : 28)
            .padding(.vertical, compact ? 9 : 14)
            .background(Theme.accent, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.black, lineWidth: 2))
            .background(Capsule().fill(Theme.red).offset(x: 3, y: 3))   // hard comic drop-shadow
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

/// A comic caption-box title: slanted red label, yellow offset shadow, heavy italic white lettering.
struct ComicTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 19, weight: .black, design: .rounded))
            .italic()
            .tracking(1.5)
            .foregroundStyle(Color.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            .background(Theme.red.skew(-0.2))
            .background(Theme.accent.skew(-0.2).offset(x: 3, y: 3))
    }
}

private extension View {
    func skew(_ amount: CGFloat) -> some View {
        return self.transformEffect(CGAffineTransform(a: 1, b: 0, c: amount, d: 1, tx: 0, ty: 0))
    }
}

/// Quiet grey button for secondary actions.
struct GreyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Theme.card2, in: Capsule())
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

/// Round grey icon button used in headers.
struct CircleIcon: View {
    let systemName: String
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 40, height: 40)
            .background(Theme.card2, in: Circle())
    }
}

// MARK: - Layout

/// Lays content out across the WHOLE screen and keeps it centered on the screen itself, even when the system
/// reserves more room on one side (e.g. the iPhone Duo's status area): both sides get the larger inset.
struct FullWidthCentered<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.safeAreaInsets.leading, geo.safeAreaInsets.trailing)
            content()
                .padding(.horizontal, side)
                .frame(width: geo.size.width, height: geo.size.height)
                // Only the wide (landscape) layout lets content rise level with the status widget. Upright, the
                // system status bar sits there and would cover (and swallow taps for) anything in the corner.
                .ignoresSafeArea(.container, edges: geo.size.width > geo.size.height ? .top : [])
        }
        .ignoresSafeArea(.container, edges: .horizontal)
    }
}

extension View {
    /// Reports whether the screen is currently wider than it is tall.
    func readLandscape(_ value: Binding<Bool>) -> some View {
        background(
            GeometryReader { g in
                Color.clear
                    .onAppear { value.wrappedValue = g.size.width > g.size.height }
                    .onChange(of: g.size) { _, new in value.wrappedValue = new.width > new.height }
            }
        )
    }

    /// Reports the top safe-area inset (the Duo's status area) so headers can sit snugly under it.
    func readSafeTop(_ value: Binding<CGFloat>) -> some View {
        background(
            GeometryReader { g in
                Color.clear
                    .onAppear { value.wrappedValue = g.safeAreaInsets.top }
                    .onChange(of: g.safeAreaInsets.top) { _, new in value.wrappedValue = new }
            }
        )
    }
}

// MARK: - File picker

/// Shows the system file browser straight from UIKit (not inside a SwiftUI sheet), so Open/Cancel always work.
/// Identical to the picker that works in iOXcode: asCopy true, so iOS hands us a private copy and no security-scoped
/// access is involved. That is the most reliable setup for sideloaded apps on the newest iOS.
enum FilePicker {
    private static var holder: Delegate?

    static func present(types: [UTType], multiple: Bool, onPick: @escaping ([URL]) -> Void) {
        // Wait a moment so a closing menu or sheet can't block the presentation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            vc.allowsMultipleSelection = multiple
            let d = Delegate(onPick)
            holder = d
            vc.delegate = d
            if let host = top() {
                Console.log("picker: presenting from \(type(of: host)), multiple=\(multiple)")
                host.present(vc, animated: true) { Console.log("picker: on screen") }
            } else {
                Console.log("picker: ERROR no view controller to present from")
            }
        }
    }

    /// Pick a whole folder (every comic inside gets added). Folders can't be copied by the picker, so this one opens in place.
    static func presentFolder(onPick: @escaping (URL) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            vc.allowsMultipleSelection = false
            let d = Delegate({ urls in if let u = urls.first { onPick(u) } })
            holder = d
            vc.delegate = d
            if let host = top() {
                Console.log("picker: presenting folder picker")
                host.present(vc, animated: true) { Console.log("picker: folder picker on screen") }
            } else {
                Console.log("picker: ERROR no view controller to present from")
            }
        }
    }

    private static func top() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        var vc = windows.first(where: { $0.isKeyWindow })?.rootViewController ?? windows.first?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(_ onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            FilePicker.holder = nil
            Console.log("picker: Open pressed, \(urls.count) file(s): " + urls.map { $0.lastPathComponent }.joined(separator: ", "))
            if !urls.isEmpty { onPick(urls) }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            FilePicker.holder = nil
            Console.log("picker: cancelled")
        }
    }
}

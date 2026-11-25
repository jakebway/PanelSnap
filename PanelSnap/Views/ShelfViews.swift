import SwiftUI
import UIKit

// MARK: - The wooden shelf behind the comics

/// A comic-book plank: inked outline, a lit top surface, a darker front and a hard offset shadow.
struct ShelfLedge: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 0.20), Color(red: 0.43, green: 0.27, blue: 0.15)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 5)
            Rectangle().fill(Color.black.opacity(0.85)).frame(height: 1.5)
            Rectangle()
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.18, blue: 0.10), Color(red: 0.20, green: 0.12, blue: 0.07)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 9)
                .overlay(alignment: .top) { Rectangle().fill(Color(red: 1, green: 0.8, blue: 0.4).opacity(0.18)).frame(height: 1.5) }
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.9)).frame(height: 2) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.9)).frame(height: 2) }
        .shadow(color: .black, radius: 0, x: 0, y: 3)       // the hard, inked drop shadow
    }
}

/// The same plank as `ShelfLedge`, shrunk for the tiny bookcase thumbnail (same wood, same inked edges).
struct MiniLedge: View {
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(red: 0.55, green: 0.36, blue: 0.20)).frame(height: 2)
            Rectangle().fill(Color.black.opacity(0.85)).frame(height: 0.75)
            Rectangle().fill(Color(red: 0.26, green: 0.16, blue: 0.09)).frame(height: 3)
        }
        .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.9)).frame(height: 0.75) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.9)).frame(height: 0.75) }
        .shadow(color: .black, radius: 0, x: 0, y: 1.5)
    }
}

/// Soft contact shadow where a cover's bottom edge meets the plank.
struct ContactShadow: View {
    var body: some View {
        Ellipse()
            .fill(RadialGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0)], center: .center, startRadius: 0, endRadius: 60))
            .scaleEffect(x: 1, y: 0.35)
            .allowsHitTesting(false)
    }
}

/// Height reserved under a cover for the plank (plank 17.5 + hard shadow 3).
let shelfLedgeRoom: CGFloat = 22

/// Behind a cover-sized cell: a plank that runs the whole width of the screen (every cell in
/// the row draws the same plank), with the cover standing on it.
struct ShelfBackdrop: View {
    var body: some View {
        GeometryReader { g in
            let h = g.size.width * 1.5
            ZStack(alignment: .top) {
                ShelfLedge()
                    .frame(width: 4000)
                    .frame(width: g.size.width)
                    .offset(y: h)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The tiny shelf that stands in for a folder

struct MiniCover: View {
    @EnvironmentObject var library: LibraryStore
    let entry: ComicEntry
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.card2)
            if let img = image { Image(uiImage: img).resizable().scaledToFill() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous).strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.45), radius: 1, x: 1, y: 0)
        .task(id: entry.id) {
            let url = library.coverURL(for: entry)
            if let hit = CoverCache.shared.cached(url) { image = hit } else { image = await CoverCache.shared.load(url) }
        }
    }
}

/// A small bookcase with the shelf's comics standing on two planks. Always exactly cover-shaped (2:3).
struct ShelfThumbnail: View {
    let comics: [ComicEntry]
    private let heights: [CGFloat] = [1.0, 0.9, 0.96, 0.88, 1.0, 0.93]

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                GeometryReader { g in
                    let w = g.size.width
                    let innerW = w * 0.9
                    let gap = w * 0.025
                    let bookW = (innerW - gap * 2) / 3
                    let bookH = bookW * 1.5
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.22, green: 0.14, blue: 0.09), Color(red: 0.12, green: 0.08, blue: 0.05)], startPoint: .top, endPoint: .bottom))
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(red: 0.55, green: 0.36, blue: 0.20).opacity(0.9), lineWidth: 3)
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.black.opacity(0.9), lineWidth: 1)
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            row(0, bookW: bookW, bookH: bookH, gap: gap, width: innerW)
                            Spacer(minLength: 0)
                            row(1, bookW: bookW, bookH: bookH, gap: gap, width: innerW)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
    }

    private func row(_ r: Int, bookW: CGFloat, bookH: CGFloat, gap: CGFloat, width: CGFloat) -> some View {
        let slice = Array(comics.dropFirst(r * 3).prefix(3))
        return ZStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(slice.enumerated()), id: \.element.id) { i, c in
                    let scale = heights[(r * 3 + i) % heights.count]
                    MiniCover(entry: c)
                        .frame(width: bookW * scale, height: bookH * scale)
                        .rotationEffect(.degrees(slice.count == 3 && i == 2 && r == 0 ? -5 : 0), anchor: .bottomLeading)
                }
            }
            .frame(width: width, alignment: .center)
            .padding(.bottom, 6.5)
            MiniLedge().frame(width: width + 8)
        }
        .frame(width: width + 8, height: bookH + 8, alignment: .bottom)
    }
}

/// A shelf as it appears in the library, like a folder among apps.
struct ShelfFolderCell: View {
    let name: String
    let comics: [ComicEntry]
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfThumbnail(comics: comics)
                .scaleEffect(highlighted ? 1.07 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: highlighted)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(comics.count == 1 ? "1 comic" : "\(comics.count) comics")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Dragging comics around the grid

/// Something a dragged comic can be held over.
enum DragTarget: Hashable {
    case comic(UUID)
    case shelf(String)
}

enum DragZone { case edge, middle }

struct DragFramesKey: PreferenceKey {
    static var defaultValue: [DragTarget: CGRect] = [:]
    static func reduce(value: inout [DragTarget: CGRect], nextValue: () -> [DragTarget: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Reports where this cell is, so one drop handler for the whole grid can tell what the finger is over.
    func dragFrame(_ target: DragTarget, in space: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: DragFramesKey.self, value: [target: g.frame(in: .named(space))])
        })
    }
}

/// Follows a dragged comic (or shelf) across a grid and decides what resting on something means, like the Home Screen:
/// on the edge of a cover it slides the others apart, in the middle of a comic it makes a shelf, in the middle of a shelf
/// it opens it. One of these watches the finger for the whole grid, so covers sliding around underneath can't confuse it.
final class DragState: ObservableObject {
    @Published var focus: DragTarget?          // a cover ready to become a shelf, or the shelf being hovered
    var frames: [DragTarget: CGRect] = [:]

    private var target: DragTarget?
    private var zone: DragZone = .edge
    private var since = Date()
    private var loop: Task<Void, Never>?
    private var dragged: DragTarget?
    private var canStack = false
    private var reorder: ((DragTarget, DragTarget) -> Void)?
    private var openShelf: ((String) -> Void)?

    /// What is under this point (covers are 2:3, with a caption underneath that counts as the edge).
    func hit(_ p: CGPoint) -> (DragTarget, DragZone)? {
        for (t, f) in frames {
            guard f.insetBy(dx: -6, dy: -11).contains(p) else { continue }
            let h = f.width * 1.5
            let middle = CGRect(x: f.minX + f.width * 0.22, y: f.minY + h * 0.2, width: f.width * 0.56, height: h * 0.6)
            return (t, middle.contains(p) ? .middle : .edge)
        }
        return nil
    }

    func track(_ p: CGPoint, dragged: DragTarget, canStack: Bool, first: DragTarget?, last: DragTarget?,
               reorder: @escaping (DragTarget, DragTarget) -> Void, openShelf: @escaping (String) -> Void) {
        self.dragged = dragged
        self.canStack = canStack
        self.reorder = reorder
        self.openShelf = openShelf
        var t = hit(p)?.0
        var z = hit(p)?.1 ?? .edge
        if t == dragged { t = nil }
        if t == nil {
            // Held in the empty space past the last item (or before the first): slide it there, so its greyed-out place shows.
            let e = pastEnds(p, first: first, last: last)
            if e > 0, let l = last, l != dragged { t = l }
            else if e < 0, let f = first, f != dragged { t = f }
        }
        if case .shelf = dragged { z = .edge }      // a shelf being moved just slides past whatever it rests on
        if case .comic = dragged, case .comic(_)? = t, !canStack { z = .edge }
        if z != zone { zone = z; since = Date() }
        if t != target {
            target = t
            since = Date()
            if focus != nil { focus = nil }
        }
        if target != nil && loop == nil {
            loop = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    guard let self = self else { return }
                    self.evaluate()
                }
            }
        }
    }

    private func evaluate() {
        guard let t = target, let d = dragged else { loop?.cancel(); loop = nil; return }
        let el = Date().timeIntervalSince(since)
        func setFocus(_ f: DragTarget?) { if focus != f { focus = f } }
        switch (d, t) {
        case (.shelf, _):
            if el > 0.3 { target = nil; reorder?(d, t) }
        case (.comic, .shelf(let name)):
            if zone == .middle {
                setFocus(t)
                if el > 0.6 {
                    target = nil
                    setFocus(nil)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    openShelf?(name)
                }
            } else {
                setFocus(nil)
                if el > 0.3 { target = nil; reorder?(d, t) }
            }
        case (.comic, .comic):
            if zone == .middle && canStack {
                if el > 0.6 && focus != t {
                    focus = t
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } else {
                setFocus(nil)
                if el > 0.3 { target = nil; reorder?(d, t) }
            }
        }
    }

    /// The comic the dragged one is resting on the middle of, long enough to make a shelf (at the moment of letting go).
    func stackCandidate(at p: CGPoint) -> UUID? {
        if case .comic(let id)? = focus { return id }
        if let (t, z) = hit(p), z == .middle, canStack, case .comic(let id) = t, t != dragged,
           target == t, Date().timeIntervalSince(since) > 0.5 { return id }
        return nil
    }

    /// Whether the finger is below the last item (or above the first): `+1` for the end, `-1` for the start.
    func pastEnds(_ p: CGPoint, first: DragTarget?, last: DragTarget?) -> Int {
        if hit(p) != nil { return 0 }
        // Below the last row, or in the empty space to the right of the last item: the end.
        if let l = last, let f = frames[l], p.y > f.maxY || (p.y > f.minY - 11 && p.x > f.maxX) { return 1 }
        // Above the first row, or just to the left of the first item: the start.
        if let fi = first, let f = frames[fi], p.y < f.minY || (p.y < f.maxY + 11 && p.x < f.minX) { return -1 }
        return 0
    }

    func stop() {
        loop?.cancel()
        loop = nil
        target = nil
        if focus != nil { focus = nil }
    }

    // Holding a dragged comic at the screen edge, inside a shelf, takes it out of the shelf.
    private var edgeTimer: Task<Void, Never>?
    @Published var edgeHot = false

    func edgeDwell(_ action: @escaping () -> Void) {
        edgeTimer?.cancel()
        edgeHot = true
        edgeTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self = self else { return }
            self.edgeHot = false
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }
    }

    func edgeCancel() {
        edgeTimer?.cancel()
        edgeTimer = nil
        edgeHot = false
    }
}

/// One drop handler for a whole grid of covers (the library or an open shelf).
struct GridDropDelegate: DropDelegate {
    @Binding var dragging: UUID?
    @Binding var active: Bool
    var draggingShelf: Binding<String?> = .constant(nil)
    let state: DragState
    let canStack: Bool
    let first: () -> DragTarget?
    let last: () -> DragTarget?
    var enter: ((UUID) -> Void)? = nil                 // an open shelf takes the comic in as soon as it is over it
    let reorder: (DragTarget, DragTarget) -> Void
    let stack: (UUID, UUID) -> Void
    var openShelf: (String) -> Void = { _ in }
    var intoShelf: (UUID, String) -> Void = { _, _ in }

    private var current: DragTarget? {
        if let s = draggingShelf.wrappedValue { return .shelf(s) }
        if let c = dragging { return .comic(c) }
        return nil
    }

    func validateDrop(info: DropInfo) -> Bool { return current != nil }

    private func update(_ info: DropInfo) {
        guard let d = current else { return }
        active = true
        if case .comic(let id) = d { enter?(id) }
        state.track(info.location, dragged: d, canStack: canStack, first: first(), last: last(), reorder: reorder, openShelf: openShelf)
    }

    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)       // a move, so no green plus
    }
    func dropExited(info: DropInfo) { state.stop() }

    func performDrop(info: DropInfo) -> Bool {
        let p = info.location
        let d = current
        let stackOnto = state.stackCandidate(at: p)
        let hit = state.hit(p)
        let ends = state.pastEnds(p, first: first(), last: last())
        state.stop()
        dragging = nil
        draggingShelf.wrappedValue = nil
        active = false
        guard let item = d else { return false }
        if case .comic(let id) = item {
            if let other = stackOnto, other != id {
                stack(id, other)
                return true
            }
            if let (t, _) = hit, case .shelf(let name) = t {
                intoShelf(id, name)
                return true
            }
        }
        if ends > 0, let l = last(), l != item { reorder(item, l) }
        else if ends < 0, let f = first(), f != item { reorder(item, f) }
        return true
    }
}

// MARK: - Naming a shelf

struct ShelfNameRequest: Identifiable {
    let id = UUID()
    var renaming: String?          // nil = a new shelf
    var moving: Set<UUID>          // comics that go into a new shelf
    var initial: String
    var suggestions: [String]
}

struct ShelfNameSheet: View {
    let request: ShelfNameRequest
    let existing: [String]
    let preview: [ComicEntry]
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(request: ShelfNameRequest, existing: [String], preview: [ComicEntry], onSave: @escaping (String) -> Void) {
        self.request = request
        self.existing = existing
        self.preview = preview
        self.onSave = onSave
        _name = State(initialValue: request.initial)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var clash: Bool {
        existing.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame && $0 != request.renaming }
    }
    private var canSave: Bool { !trimmed.isEmpty && !(request.renaming != nil && clash) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(request.renaming == nil ? "New Shelf" : "Rename Shelf")
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, 22)

                ShelfThumbnail(comics: preview)
                    .frame(width: 118)

                if request.renaming == nil && !request.moving.isEmpty {
                    Text(request.moving.count == 1 ? "1 comic will go on this shelf" : "\(request.moving.count) comics will go on this shelf")
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                }

                HStack(spacing: 8) {
                    TextField("Shelf name", text: $name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { save() }
                        .autocorrectionDisabled()
                    if !name.isEmpty {
                        Button { name = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
                    }
                }
                .padding(14)
                .background(Theme.card2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? Theme.accent : Color.clear, lineWidth: 2))

                if clash {
                    Text(request.renaming == nil ? "A shelf with this name already exists. The comics will be added to it."
                                                 : "A shelf with this name already exists.")
                        .font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }

                if !request.suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SUGGESTIONS").font(.caption.weight(.bold)).foregroundStyle(Theme.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                            ForEach(request.suggestions, id: \.self) { s in
                                Button { name = s } label: {
                                    Text(s).font(.subheadline.weight(.semibold)).lineLimit(1)
                                        .foregroundStyle(trimmed == s ? Theme.onAccent : .white)
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(trimmed == s ? Theme.accent : Theme.card2, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Text("Cancel").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.card2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button { save() } label: {
                        Text(request.renaming == nil ? "Create" : "Save").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(YellowButtonStyle(compact: false))
                    .disabled(!canSave)
                    .opacity(canSave ? 1 : 0.45)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
    }

    private func save() {
        guard canSave else { return }
        onSave(trimmed)
        dismiss()
    }
}

/// A strip along the screen edge: a comic held on it inside a shelf leaves the shelf (it drops into the library).
struct EdgeDropDelegate: DropDelegate {
    @Binding var dragging: UUID?
    @Binding var active: Bool
    let state: DragState
    let leave: (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool { return dragging != nil }
    func dropEntered(info: DropInfo) {
        guard let id = dragging else { return }
        state.edgeDwell { leave(id) }
    }
    func dropExited(info: DropInfo) { state.edgeCancel() }
    func dropUpdated(info: DropInfo) -> DropProposal? { return DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        state.edgeCancel()
        guard let id = dragging else { return false }
        leave(id)
        dragging = nil
        active = false
        return true
    }
}

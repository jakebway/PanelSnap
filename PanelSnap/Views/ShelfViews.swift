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

/// A plain thin plank for the tiny bookcase thumbnail.
struct MiniLedge: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Color(red: 0.50, green: 0.33, blue: 0.18), Color(red: 0.30, green: 0.19, blue: 0.10)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(height: 4)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.8)).frame(height: 1) }
            .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
    }
}

/// Behind a cover-sized cell: a faint back wall and a plank that runs the whole width of the screen (every cell in
/// the row draws the same plank), with the cover standing on it.
struct ShelfBackdrop: View {
    var body: some View {
        GeometryReader { g in
            let h = g.size.width * 1.5
            ZStack(alignment: .top) {
                ShelfLedge()
                    .frame(width: 4000)
                    .frame(width: g.size.width)
                    .offset(y: h - 3)
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
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
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
                            .fill(LinearGradient(colors: [Color(white: 0.15), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
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
            .padding(.bottom, 3)
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

// MARK: - Making a shelf by holding one comic over another

/// Tracks whether the comic being dragged has rested on another one long enough to make a shelf.
final class DragState: ObservableObject {
    @Published var stackTarget: UUID?
    private var hover: UUID?
    private var timer: Task<Void, Never>?

    func begin(_ id: UUID) {
        if hover == id { return }
        clear()
        hover = id
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled, let self = self, self.hover == id else { return }
            self.stackTarget = id
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    func clear() {
        timer?.cancel()
        timer = nil
        hover = nil
        if stackTarget != nil { stackTarget = nil }
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

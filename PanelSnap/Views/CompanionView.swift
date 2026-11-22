import SwiftUI
import UIKit

/// "Companion": everything you need to understand the comic you're reading.
struct CompanionView: View {
    @ObservedObject var model: CompanionModel
    @EnvironmentObject var settings: AppSettings
    var onClose: () -> Void

    @State private var revealed = false
    @State private var selected: CharacterCard?
    @State private var showFix = false
    @StateObject private var ask = CompanionAsk()
    @State private var question = ""
    @State private var spoilers = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    issueBanner
                    statusRow
                    if CompanionAsk.isSupported { askSection }

                    if let t = model.data.issueSummary {
                        section("About this issue") { textBlock(t) }
                    }
                    if let t = model.data.issueSynopsis {
                        section("What happens (spoilers)") { spoilerBlock(t) }
                    }
                    if let t = model.data.seriesSummary {
                        section("The series") { textBlock(t) }
                    }
                    if !model.data.characters.isEmpty {
                        section("Who's who") { characterStrip }
                    }
                    if !model.data.teams.isEmpty || !model.data.locations.isEmpty {
                        section("Teams & places") { teamsAndPlaces }
                    }
                    if !model.data.arcs.isEmpty {
                        section("Story arc") {
                            FlowChips(items: model.data.arcs, tint: Theme.accent)
                        }
                    }
                    if !model.data.creators.isEmpty {
                        section("Made by") { creators }
                    }
                    if !model.data.links.isEmpty {
                        section("Read more") { links }
                    }
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            .navigationTitle("Companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onClose() }
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(item: $selected) { card in
            CharacterSheet(model: model, name: card.name)
        }
        .sheet(isPresented: $showFix) {
            FixMatchSheet(model: model)
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let img = CoverCache.shared.image(for: model.coverURL) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(Color.gray.opacity(0.25))
                }
            }
            .frame(width: 84, height: 126)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 6) {
                Text(model.data.series ?? model.entry.title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if !issueLine.isEmpty {
                    Text(issueLine).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !model.data.genres.isEmpty {
                    FlowChips(items: Array(model.data.genres.prefix(4)), tint: .secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var issueLine: String {
        var line = ""
        if let n = model.data.issue, !n.isEmpty { line = "Issue #" + n }
        if let t = model.data.title, !t.isEmpty {
            line += (line.isEmpty ? "" : " · ") + t
        }
        return line
    }

    private var subtitle: String {
        var parts: [String] = []
        if let p = model.data.publisher, !p.isEmpty { parts.append(p) }
        if let y = model.data.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var statusRow: some View {
        if model.phase == .loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Looking Up This Comic…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else if let tip = model.tip {
            Label(tip, systemImage: "lightbulb")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Shown for a collected edition: which issue Companion is following.
    @ViewBuilder
    private var issueBanner: some View {
        if let mark = model.activeMark {
            Label("Following your place: you're in issue #\(mark.issue)", systemImage: "bookmark.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("companion-issue-banner")
        } else if model.scanning {
            HStack(spacing: 8) {
                ProgressView()
                Text("Finding the issues in this collection…").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Ask (on-device model)

    private var askSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about this comic").font(.headline)
            HStack(spacing: 8) {
                TextField("Who is…? What's going on?", text: $question)
                    .submitLabel(.send)
                    .onSubmit { send(question) }
                Button { send(question) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                }
                .disabled(ask.busy || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { question = s; send(s) } label: {
                            Text(s).font(.footnote.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Theme.card2, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Toggle("Allow spoilers", isOn: $spoilers).font(.footnote)
            if ask.busy {
                HStack(spacing: 8) { ProgressView(); Text("Thinking…").font(.footnote).foregroundStyle(.secondary) }
            } else if ask.failed {
                Text("I couldn't answer that just now. Try asking it another way.").font(.footnote).foregroundStyle(.secondary)
            } else if !ask.answer.isEmpty {
                Text(ask.answer)
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Answered on your phone from the information on this page. It can still be wrong.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var suggestions: [String] {
        var list = ["Who are the main characters?", "What's going on so far?"]
        if let first = model.data.characters.first?.name { list.insert("Who is \(first)?", at: 0) }
        return list
    }

    private func send(_ text: String) {
        let context = model.data.llmContext(spoilers: spoilers, mark: model.activeMark,
                                            page: model.currentPage, pageCount: model.pageCount)
        Task { await ask.ask(text, context: context) }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    private func textBlock(_ t: TextBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(t.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            sourceLine(t)
        }
    }

    private func sourceLine(_ t: TextBlock) -> some View {
        Group {
            if let u = t.url, let url = URL(string: u) {
                Link(destination: url) {
                    Label(t.source, systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            } else {
                Text(t.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func spoilerBlock(_ t: TextBlock) -> some View {
        let hidden = settings.spoilerShield && !revealed
        return ZStack {
            textBlock(t)
                .blur(radius: hidden ? 9 : 0)
                .allowsHitTesting(!hidden)
            if hidden {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { revealed = true }
                } label: {
                    Label("Tap to Reveal Spoilers", systemImage: "eye")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Theme.card2, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var characterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(model.data.characters) { c in
                    Button {
                        selected = c
                    } label: {
                        VStack(spacing: 6) {
                            Avatar(name: c.name, imageURL: c.imageURL, size: 64)
                            Text(c.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 76)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var teamsAndPlaces: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.data.teams.isEmpty {
                FlowChips(items: model.data.teams, tint: .blue)
            }
            if !model.data.locations.isEmpty {
                FlowChips(items: model.data.locations, tint: .green)
            }
        }
    }

    private var creators: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groupedCreators, id: \.0) { pair in
                HStack(alignment: .top) {
                    Text(pair.0)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 92, alignment: .leading)
                    Text(pair.1.joined(separator: ", "))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var groupedCreators: [(String, [String])] {
        var order: [String] = []
        var map: [String: [String]] = [:]
        for c in model.data.creators {
            if map[c.role] == nil {
                order.append(c.role)
                map[c.role] = []
            }
            if !(map[c.role] ?? []).contains(c.name) { map[c.role]?.append(c.name) }
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    private var links: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.data.links) { l in
                if let url = URL(string: l.url) {
                    Link(destination: url) {
                        HStack {
                            Text(l.title)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.subheadline)
                        .padding(12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showFix = true
            } label: {
                Label("Not the Right Comic?", systemImage: "magnifyingglass")
                    .font(.subheadline)
            }
            Button {
                model.load(force: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.subheadline)
            }
            if !model.data.sources.isEmpty {
                Text("Sources: " + model.data.sources.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Character guide: Superhero API (MIT) and FiveThirtyEight (CC BY 4.0). Comic data: Grand Comics Database (CC BY-SA 4.0). Wikipedia, Open Library and fan-wiki text under their own open licences.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 6)
    }
}

// MARK: - Small building blocks

struct Avatar: View {
    let name: String
    let imageURL: String?
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(Theme.accent.opacity(0.18))
            Text(initials)
                .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.accent)
            if let s = imageURL, let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }

    private var initials: String {
        let words = name.split(separator: " ").prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0) }
        return letters.joined().uppercased()
    }
}

/// Wrapping row of little capsules.
struct FlowChips: View {
    let items: [String]
    let tint: Color

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(tint)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxWidth, max(widest, 0)), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct CharacterSheet: View {
    @ObservedObject var model: CompanionModel
    let name: String
    @Environment(\.dismiss) private var dismiss

    private var card: CharacterCard? {
        return model.data.characters.first(where: { $0.name == name })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Avatar(name: name, imageURL: card?.imageURL, size: 110)
                        .padding(.top, 8)
                    Text(name)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let real = card?.role, !real.isEmpty {
                        Text(real)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let facts = card?.facts, !facts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(facts.filter { $0.label != "Real name" }, id: \.self) { f in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(f.label.uppercased())
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(f.value)
                                        .font(.subheadline)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    if let blurb = card?.blurb {
                        Text(blurb)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let src = card?.source {
                            Text("Source: " + src)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if card?.facts == nil {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking Up This Character…")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let u = card?.url, let url = URL(string: u) {
                        Link(destination: url) {
                            Label("Read More", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Character")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await model.loadCharacter(name)
        }
    }
}

struct FixMatchSheet: View {
    @ObservedObject var model: CompanionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("Type the real series name and issue number, for example “Saga” and “12”.")) {
                    TextField("Series name", text: $model.fixSeries)
                        .autocorrectionDisabled()
                    TextField("Issue number", text: $model.fixIssue)
                        .keyboardType(.numbersAndPunctuation)
                }
            }
            .navigationTitle("Fix the Match")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Search") {
                        model.relookup(series: model.fixSeries, issue: model.fixIssue)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

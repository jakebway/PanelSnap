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
    @State private var showChat = false
    @State private var draft = ""
    @State private var pending: String?
    @FocusState private var typing: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    issueBanner
                    statusRow
                    storyCard
                    if !model.data.characters.isEmpty {
                        section("Main characters") { characterStrip }
                    }
                    if CompanionAsk.isSupported {
                        AskEntryCard(model: model, ask: model.ask) { pending = nil; showChat = true }
                    }
                    if !model.data.teams.isEmpty || !model.data.locations.isEmpty {
                        section("Teams & places") { teamsAndPlaces }
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
            .scrollDismissesKeyboard(.interactively)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if CompanionAsk.isSupported { askBar }
            }
            .onChange(of: draft) { _, _ in typingChanged() }
            .onChange(of: typing) { _, focused in if focused { model.ask.prewarm(publisher: model.data.publisher) } }
            .fullScreenCover(isPresented: $showChat, onDismiss: { pending = nil }) {
                AskChatView(model: model, ask: model.ask, initialQuestion: pending)
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

    // MARK: Ask bar

    /// The message bar is always on the Companion screen. Sending opens the chat with the question already on its way.
    private var askBar: some View {
        VStack(spacing: 8) {
            if !draftReady && !typing {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(quickAsks, id: \.self) { q in
                            Button { pending = q; showChat = true } label: {
                                Text(q).font(.footnote.weight(.medium))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Theme.card2, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                TextField("Ask about this comic…", text: $draft)
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(sendDraft)
                    .accessibilityIdentifier("ask-field")
                Button(action: sendDraft) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 32, height: 32)
                        .background(draftReady ? Theme.accent : Theme.accent.opacity(0.35), in: Circle())
                }
                .disabled(!draftReady)
                .accessibilityIdentifier("ask-send-inline")
            }
            .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
            .background(Theme.card2, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
            .padding(.horizontal, 14)
        }
        .padding(.top, 8).padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var quickAsks: [String] {
        var list = ["What's the story so far?", "Who are the main characters?"]
        if let first = model.data.characters.first?.name { list.append("Who is \(first)?") }
        if let arc = model.data.arcs.first { list.append("What is \(arc) about?") }
        return list
    }

    private func typingChanged() {
        model.speculate(draft)
    }

    private var draftReady: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func sendDraft() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        draft = ""
        typing = false
        pending = q
        showChat = true
    }

    // MARK: Story

    /// The heart of the screen: the story arc and what it's about. A collected edition gets the whole-book picture.
    @ViewBuilder
    private var storyCard: some View {
        let d = model.data
        let omnibus = model.plannedCount >= 2
        // Only text that tells the story leads. A series description about who made the comic and when goes under "About the series".
        let lead: TextBlock? = [d.issueSummary, d.seriesSummary].compactMap { $0 }.first(where: { !looksLikeHistory($0.text) })
        let more: TextBlock? = d.seriesSummary.flatMap { s in (lead?.text == s.text) ? nil : s }
        let marks = model.issueMarks.sorted { $0.page < $1.page }
        let beats = omnibus ? model.collectionStory : []
        if lead != nil || d.issueSynopsis != nil || !d.arcs.isEmpty || more != nil || !beats.isEmpty || model.storyLoading {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: omnibus ? "books.vertical" : "text.book.closed")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(omnibus ? "The whole story" : "The story").font(.headline)
                    Spacer()
                }
                if omnibus, let f = marks.first, let l = marks.last, marks.count >= 2 {
                    Text("\(marks.count) issues · \(f.series ?? "") #\(f.issue) to #\(l.issue)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !d.arcs.isEmpty {
                    FlowChips(items: Array(d.arcs.prefix(omnibus ? 8 : 3)), tint: Theme.accent)
                }
                if let t = lead {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(TextClean.shorten(t.text, limit: 520))
                            .font(.callout).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                        sourceLine(t)
                    }
                }
                if omnibus && model.storyLoading && beats.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Reading each issue…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !beats.isEmpty {
                    spoilerBeats(beats)
                } else if let t = d.issueSynopsis {
                    spoilerText(t, label: lead == nil ? "THE STORY · SPOILERS" : "WHAT HAPPENS · SPOILERS")
                }
                if let t = more {
                    DisclosureGroup("About the series") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(TextClean.shorten(t.text, limit: 520)).font(.callout).lineSpacing(3)
                            sourceLine(t)
                        }
                        .padding(.top, 6)
                    }
                    .font(.subheadline.weight(.medium))
                    .tint(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    /// True for text about the comic's publication (who made it, when, for which publisher) rather than its story.
    private func looksLikeHistory(_ text: String) -> Bool {
        let l = text.lowercased()
        let keys = ["comic book series", "published by", "first appeared", "is an american", "created by", "first published",
                    "longest-running", "ongoing series", "publication history", "was launched"]
        return keys.filter { l.contains($0) }.count >= 2
    }

    /// The issues of a collected edition, each with the opening of its plot, behind the spoiler shield.
    private func spoilerBeats(_ beats: [CompanionModel.StoryBeat]) -> some View {
        let hidden = settings.spoilerShield && !revealed
        return VStack(alignment: .leading, spacing: 8) {
            Text("ISSUE BY ISSUE · SPOILERS")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ZStack {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(beats) { b in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.label).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                            Text(b.text).font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let s = beats.first?.source { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
                .blur(radius: hidden ? 8 : 0)
                if hidden {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { revealed = true }
                    } label: {
                        Label("Tap to Reveal", systemImage: "eye")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.card2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func spoilerText(_ t: TextBlock, label: String) -> some View {
        let hidden = settings.spoilerShield && !revealed
        return VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            ZStack {
                Text(TextClean.shorten(t.text, limit: 700))
                    .font(.callout).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .blur(radius: hidden ? 8 : 0)
                if hidden {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) { revealed = true }
                    } label: {
                        Label("Tap to Reveal", systemImage: "eye")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Theme.card2, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
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
            VStack(alignment: .leading, spacing: 4) {
                let name = (mark.series ?? "").isEmpty ? "issue" : "\(mark.series ?? "") "
                Label((mark.estimated == true ? "Probably in " : "Following your place: you're in ") + "\(name)#\(mark.issue)", systemImage: "bookmark.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                if model.readingPages {
                    Text("Getting ready for your questions…").font(.caption2).foregroundStyle(.secondary)
                } else if model.scanning {
                    Text((mark.estimated == true ? "Checking the pages to be sure" : "Still reading the other pages") + " · \(Int(model.scanFraction * 100))%")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("companion-issue-banner")
        } else if model.scanning {
            HStack(spacing: 8) {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.plannedCount >= 2 ? "This collection has \(model.plannedCount) issues. Finding where yours starts…" : "Finding the issues in this collection…")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Reading page text on this phone · \(Int(model.scanFraction * 100))%")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } else if model.scanFinished && model.issueMarks.isEmpty && model.plannedCount >= 0 {
            Text("Couldn't find printed issue numbers in this one, so Companion is showing the whole book.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            content()
        }
    }

    private func textBlock(_ t: TextBlock) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.text)
                .font(.callout)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            sourceLine(t)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                ForEach(Array(model.data.characters.prefix(12))) { c in
                    Button {
                        selected = c
                    } label: {
                        VStack(spacing: 5) {
                            Avatar(name: c.name, imageURL: c.imageURL, size: 64)
                            Text(c.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(width: 80)
                            if let r = c.role, !r.isEmpty {
                                Text(r).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).frame(width: 80)
                            }
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


// MARK: - Ask: the chat

/// The small card in the Companion panel that opens the chat.
struct AskEntryCard: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var ask: CompanionAsk
    var open: () -> Void

    private var last: AskExchange? { return ask.history.last(where: { $0.issueKey == model.issueKey && !$0.failed }) }

    var body: some View {
        if let last = last {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Your chat", systemImage: "bubble.left.and.text.bubble.right")
                            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                        Spacer()
                        Text("Open").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(last.question).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    if !last.answer.isEmpty {
                        Text(last.answer).font(.footnote).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask-open")
        }
    }
}

/// A full-screen assistant chat about the comic. Your questions sit on the right, answers read as plain text beside a small
/// sparkle, and the message bar floats above the keyboard.
struct AskChatView: View {
    @ObservedObject var model: CompanionModel
    @ObservedObject var ask: CompanionAsk
    var initialQuestion: String? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("companion.spoilers") private var spoilers = false
    @State private var text = ""
    @State private var sentInitial = false
    @State private var viewKey: String?
    @State private var showHistory = false
    @State private var showBrowser = false
    @FocusState private var typing: Bool

    private var activeKey: String { return viewKey ?? model.issueKey }
    private var viewingPast: Bool { return viewKey != nil && viewKey != model.issueKey }

    private var messages: [AskExchange] {
        return Array(ask.history.filter { $0.issueKey == activeKey }.suffix(60))
    }

    private var title: String {
        if let m = model.activeMark { return (m.series ?? "Issue") + " #" + m.issue }
        return model.data.series ?? model.entry.title
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if viewingPast { pastBanner }
                        if messages.isEmpty && !viewingPast { emptyState }
                        ForEach(messages) { ex in
                            userBubble(ex.question)
                            assistantBubble(ex, isLast: ex.id == messages.last?.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture { typing = false }
                .onChange(of: text) { _, new in model.speculate(new) }
                .onChange(of: messages.count) { _, _ in toBottom(proxy, animated: true) }
                .onChange(of: messages.last?.answer) { _, _ in toBottom(proxy, animated: false) }
                .onChange(of: typing) { _, focused in
                    if focused { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { toBottom(proxy, animated: true) } }
                }
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { toBottom(proxy, animated: false) } }
            }
            .background(Theme.bg)
            .safeAreaInset(edge: .bottom, spacing: 0) { inputBar }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button("Done") { typing = false; dismiss() }
                    Button { typing = false; showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Past chats")
                    .accessibilityIdentifier("ask-history")
                    Menu {
                        Toggle(isOn: $spoilers) { Label("Allow spoilers", systemImage: "eye") }
                        Button(role: .destructive) {
                            withAnimation { ask.clear(issueKey: activeKey) }
                        } label: { Label("Clear this chat", systemImage: "trash") }
                        .disabled(messages.isEmpty || ask.busy)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityIdentifier("ask-menu")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                            Text("Companion").font(.subheadline.weight(.semibold))
                        }
                        Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                ChatHistorySheet(ask: ask, currentKey: model.issueKey) { key in
                    viewKey = (key == model.issueKey) ? nil : key
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            ask.prewarm(publisher: model.data.publisher)
            if let q = initialQuestion, !sentInitial { sentInitial = true; send(q) }
        }
    }

    private func toBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        if animated { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) } }
        else { proxy.scrollTo("bottom", anchor: .bottom) }
    }

    // MARK: Pieces

    private var pastBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            Text("Past chat · " + ChatHistorySheet.label(for: activeKey)).font(.footnote.weight(.semibold))
            Spacer()
            Button("Back") { withAnimation { viewKey = nil } }
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func avatar(_ size: CGFloat) -> some View {
        Image(systemName: "sparkles")
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: size, height: size)
            .background(Theme.accent, in: Circle())
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            avatar(52).padding(.top, 36)
            VStack(spacing: 4) {
                Text("Ask me anything").font(.title3.weight(.semibold))
                Text("Answers come from the pages and the comics wikis")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button { send(s) } label: {
                        HStack {
                            Text(s).font(.subheadline)
                            Spacer(minLength: 6)
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private func userBubble(_ q: String) -> some View {
        HStack {
            Spacer(minLength: 56)
            Text(q)
                .font(.callout)
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func assistantBubble(_ ex: AskExchange, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            avatar(26).padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                if ex.failed {
                    Text("I couldn't answer that just now. Try asking it another way.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if ex.answer.isEmpty {
                    HStack(spacing: 8) {
                        TypingDots()
                        if isLast && !ask.stage.isEmpty { Text(ask.stage).font(.caption).foregroundStyle(.secondary) }
                    }
                } else {
                    Text(ex.answer).font(.callout).lineSpacing(4).textSelection(.enabled)
                    if let e = ex.engine {
                        Label(e == "cloud" ? "Apple's private cloud model" : "Looked at this page",
                              systemImage: e == "cloud" ? "icloud" : "eye")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 16)
    }

    private var inputBar: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    typing = false
                    if let u = model.diveDeeperURL { BrowserModel.shared.open(u) }
                    else { BrowserModel.shared.searchHome((model.data.series ?? model.entry.title) + " comic") }
                    showBrowser = true
                } label: {
                    Label("Dive Deeper", systemImage: "safari")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.card2, in: Capsule())
                        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ask-dive")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 8)
            inputField
        }
        .background(.ultraThinMaterial)
        .fullScreenCover(isPresented: $showBrowser) { BrowserView() }
    }

    private var inputField: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask about this comic…", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit { send(text) }
                .padding(.vertical, 8)
            Button { send(text) } label: {
                Image(systemName: ask.busy ? "ellipsis" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Theme.accent : Theme.accent.opacity(0.35), in: Circle())
            }
            .disabled(!canSend)
            .padding(.bottom, 4)
            .accessibilityIdentifier("ask-send")
        }
        .padding(.leading, 14).padding(.trailing, 6)
        .background(Theme.card2, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        return !ask.busy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var suggestions: [String] {
        var list = ["What's the story so far?", "Who are the main characters?"]
        if let first = model.data.characters.first?.name { list.insert("Who is \(first)?", at: 0) }
        if let place = model.data.locations.first { list.append("What is \(place)?") }
        return list
    }

    private func send(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !ask.busy else { return }
        text = ""
        viewKey = nil                      // new questions always belong to the issue you're reading
        typing = false                     // put the keyboard away so the answer can be read
        let allow = spoilers
        let key = model.issueKey
        let publisher = model.data.publisher
        // A short follow-up ("I thought Pietro lived there") is searched together with the question before it.
        let earlier = messages.last(where: { !$0.failed })?.question
        let searchText = (q.split(separator: " ").count < 9 && earlier != nil) ? earlier! + " " + q : q
        Task {
            await ask.ask(q, issueKey: key, publisher: publisher, context: { budget in
                await model.askContext(spoilers: allow, question: searchText, budget: budget)
            }, pageImage: { await model.currentPageImage() })
        }
    }
}

/// Every past chat, grouped by issue, newest first. Tapping one opens it in the chat.
struct ChatHistorySheet: View {
    @ObservedObject var ask: CompanionAsk
    let currentKey: String
    var pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    static func label(for key: String) -> String {
        return key.isEmpty ? "This comic" : key.replacingOccurrences(of: "#", with: " #")
    }

    private var groups: [(key: String, items: [AskExchange])] {
        var order: [String] = []
        var map: [String: [AskExchange]] = [:]
        for ex in ask.history.reversed() where !ex.failed {
            if map[ex.issueKey] == nil { order.append(ex.issueKey) }
            map[ex.issueKey, default: []].append(ex)
        }
        return order.map { (key: $0, items: map[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right").font(.largeTitle).foregroundStyle(.tertiary)
                        Text("No chats yet").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(groups, id: \.key) { g in
                            Button { pick(g.key); dismiss() } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(ChatHistorySheet.label(for: g.key)).font(.subheadline.weight(.semibold))
                                        if g.key == currentKey {
                                            Text("Reading now").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                                        }
                                        Spacer()
                                        Text("\(g.items.count)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(g.items.first?.question ?? "").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .padding(.vertical, 2)
                            }
                            .listRowBackground(Theme.card)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Past Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

/// Three dots that pulse while the answer is being worked out.
struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.white.opacity(0.35 + 0.55 * max(0, sin(t * 4 - Double(i) * 0.7))))
                        .frame(width: 8, height: 8)
                }
            }
        }
        .frame(height: 20)
    }
}

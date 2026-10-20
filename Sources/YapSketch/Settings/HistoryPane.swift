import AppKit
import SwiftUI

struct HistoryPane: View {
    /// An item to select when History next loads ("r:" + a recording's folder name).
    @MainActor static var reveal: String?

    @State private var items: [HistoryItem] = []
    @State private var groups: [(String, [HistoryItem])] = []
    @State private var loaded = false
    @State private var selection: String?
    @State private var confirmingClear = false

    var body: some View {
        list
            .onChange(of: selection) { old, _ in if old != nil { SettingsWindow.shared.viewer = nil } }
            .background(.paper)
            #if DEBUG
            .onAppear {
                if ProcessInfo.processInfo.environment["YAPSKETCH_SNAPSHOT_EXPAND"] != nil, let r = RecordingSummary.all().first {
                    RecordingDetail.open(r, at: 0)
                }
            }
            #endif
    }

    private var list: some View {
        HStack(spacing: 0) {
            // A plain column rather than a List: the day headings scroll with it instead of
            // floating over the rows.
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        PageTitle("History")
                        Spacer()
                        Button("Clear All") { confirmingClear = true }.buttonStyle(.paper).disabled(items.isEmpty)
                    }
                    .padding(.leading, Brand.pageInset).padding(.trailing, 14).padding(.top, Brand.headerTop)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(groups, id: \.0) { title, group in
                                SectionLabel(title).padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                                ForEach(group) { item in row(item).id(item.id) }
                            }
                        }
                        // A row's text lines up with the title.
                        .padding(.leading, Brand.pageInset - 10).padding(.trailing, 12).padding(.bottom, 12)
                    }
                    .clipped()
                }
                .frame(width: 264)
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    move(-1, proxy)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    move(1, proxy)
                    return .handled
                }
                #if DEBUG
                .onChange(of: items.count) {
                    if ProcessInfo.processInfo.environment["YAPSKETCH_SNAPSHOT_SCROLL"] != nil, items.count > 12 {
                        proxy.scrollTo(items[12].id, anchor: .top)
                    }
                }
                #endif
            }
            Rectangle().fill(.rule).frame(width: 1)
            switch items.first(where: { $0.id == selection }) {
            case .recording(let r): RecordingDetail(item: r)
            case .dictation(let d): DictationDetail(entry: d)
            case nil:
                Text(!loaded ? "" : items.isEmpty ? "No recordings or dictations yet" : "Select a recording or dictation")
                    .font(.ui(14)).foregroundStyle(.soft).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: reload)
        .alert("Clear all history?", isPresented: $confirmingClear) {
            Button("Clear All", role: .destructive, action: clearAll)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(clearMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchRecordingsChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .yapSketchDictationsChanged)) { _ in reload() }
    }

    private func row(_ item: HistoryItem) -> some View {
        let r = ListRow(item: item, selected: item.id == selection) { delete(item) }
            .onTapGesture { selection = item.id }
        return r.contextMenu {
            switch item {
            case .recording(let rec):
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([rec.folder]) }
                Button("Delete Recording", role: .destructive) { delete(item) }
            case .dictation:
                Button("Delete Dictation", role: .destructive) { delete(item) }
            }
        }
    }

    private func move(_ d: Int, _ proxy: ScrollViewProxy) {
        guard !items.isEmpty else { return }
        let i = items.firstIndex { $0.id == selection } ?? -d
        let next = items[min(max(i + d, 0), items.count - 1)].id
        selection = next
        proxy.scrollTo(next)
    }

    nonisolated private static func grouped(_ items: [HistoryItem]) -> [(String, [HistoryItem])] {
        let cal = Calendar.current
        var out: [(String, [HistoryItem])] = []
        for item in items {
            let title =
                cal.isDateInToday(item.date)
                ? "Today"
                : cal.isDateInYesterday(item.date)
                    ? "Yesterday"
                    : item.date.formatted(.dateTime.weekday(.wide).day().month())
            if out.last?.0 == title { out[out.count - 1].1.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    /// Read off the main thread: thousands of recordings never hold up the window.
    private func reload() {
        Task {
            let (all, grouped) = await Task.detached(priority: .userInitiated) {
                let all = (RecordingSummary.all().map(HistoryItem.recording) + DictationHistory.all().map(HistoryItem.dictation))
                    .sorted { $0.date > $1.date }
                return (all, HistoryPane.grouped(all))
            }.value
            let onNewest = selection == items.first?.id
            items = all
            groups = grouped
            loaded = true
            if onNewest || selection == nil || !all.contains(where: { $0.id == selection }) { selection = all.first?.id }
            if let r = Self.reveal, all.contains(where: { $0.id == r }) {
                selection = r
                Self.reveal = nil
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["YAPSKETCH_SNAPSHOT_RECORDING"] != nil {
                selection = all.first(where: \.isRecording)?.id
            }
            #endif
        }
    }

    /// To the Trash, so a slip can be undone from there.
    private func delete(_ item: HistoryItem) {
        switch item {
        case .recording(let r): try? FileManager.default.trashItem(at: r.folder, resultingItemURL: nil)
        case .dictation(let d): DictationHistory.delete(d)
        }
        if selection == item.id { selection = nil }
        reload()
    }

    private var clearMessage: String {
        let r = items.filter(\.isRecording).count
        let d = items.count - r
        let parts = [r > 0 ? "\(r) recording\(r == 1 ? "" : "s")" : nil, d > 0 ? "\(d) dictation\(d == 1 ? "" : "s")" : nil].compactMap { $0 }
        return parts.formatted(.list(type: .and)) + " will be moved to the Trash."
    }

    private func clearAll() {
        for item in items {
            switch item {
            case .recording(let r): try? FileManager.default.trashItem(at: r.folder, resultingItemURL: nil)
            case .dictation(let d): DictationHistory.delete(d, notify: false)
            }
        }
        selection = nil
        NotificationCenter.default.post(name: .yapSketchDictationsChanged, object: nil)
        reload()
    }
}

private enum HistoryItem: Identifiable, Equatable {
    case recording(RecordingSummary)
    case dictation(DictationHistory.Entry)

    var id: String {
        switch self {
        case .recording(let r): "r:" + r.id
        case .dictation(let d): "d:" + d.id
        }
    }

    var date: Date {
        switch self {
        case .recording(let r): r.date
        case .dictation(let d): d.date
        }
    }

    var isRecording: Bool { if case .recording = self { true } else { false } }
}

private struct KindIcon: View {
    let recording: Bool
    var body: some View {
        Group {
            if recording {
                Circle().fill(.coral).frame(width: 7, height: 7)
            } else {
                Image(systemName: "mic.fill").font(.system(size: 9.5)).foregroundStyle(.soft)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityLabel(recording ? "Recording" : "Dictation")
    }
}

private struct ListRow: View {
    let item: HistoryItem
    let selected: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let (meta, trailing, text): (String, String, String) =
            switch item {
            case .recording(let r): ("\(time(r.date)) · \(r.title)", CLI.id(r.folder), r.failure ?? r.plainNarration)
            case .dictation(let d): ("\(time(d.date)) · Dictation", clock(d.duration), d.text.isEmpty ? (d.failure ?? "") : d.text)
            }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                KindIcon(recording: item.isRecording)
                Text(meta).font(.ui(11.5)).lineLimit(1)
                Spacer(minLength: 4)
                // On hover, a bin in place of the id or length (same line, nothing moves).
                Text(trailing).font(.mono(11.5)).opacity(hovering ? 0 : 1)
                    .overlay(alignment: .trailing) {
                        if hovering {
                            Button(action: onDelete) {
                                Image(systemName: "trash").font(.system(size: 11.5)).frame(width: 22, height: 18).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(.soft).help(item.isRecording ? "Delete recording" : "Delete dictation")
                        }
                    }
            }
            .foregroundStyle(.soft)
            Text(text).font(.ui(13)).foregroundStyle(selected ? .ink : .inkSoft).lineSpacing(2).lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? .card : .clear))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? .ink : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func time(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
}

private func clock(_ seconds: Double) -> String { String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60) }

private struct DetailHeader<Actions: View>: View {
    let recording: Bool
    let chip: String
    let title: String
    let details: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                name.layoutPriority(-1)
                Spacer(minLength: 0)
                HStack(spacing: 8) { actions }.fixedSize()
            }
            .frame(minHeight: Brand.headerHeight)
            Text(details).font(.ui(12.5)).foregroundStyle(.soft).lineLimit(1).truncationMode(.tail)
        }
    }

    private var name: some View {
        HStack(spacing: 8) {
            KindIcon(recording: recording)
            Text(chip).font(.mono(12)).foregroundStyle(.ink).lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 4).background(RoundedRectangle(cornerRadius: 6).fill(.rule))
                .textSelection(.enabled)
            Text(title).font(.ui(12.5, .medium)).foregroundStyle(.ink).lineLimit(1).truncationMode(.tail)
        }
    }
}

private struct DictationDetail: View {
    let entry: DictationHistory.Entry
    @State private var copied = false
    @State private var sound: NSSound?
    @State private var retrying = false

    var body: some View {
        let e = entry
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(
                    // When it was goes with the date, so it can't pass for a length.
                    recording: false, chip: clock(e.duration), title: "Dictation",
                    details: "\(e.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(e.model)"
                ) {
                    Button {
                        play(DictationHistory.folder.appendingPathComponent(e.audio))
                    } label: {
                        Image(systemName: sound?.isPlaying == true ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.paper)
                    .help("Play the audio")
                    .accessibilityLabel(sound?.isPlaying == true ? "Stop" : "Play the audio")
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e.text, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .buttonStyle(.ink)
                    .disabled(e.text.isEmpty)
                }
                if e.text.isEmpty, let failure = e.failure {
                    Banner(text: "\(failure). The audio is saved.", good: false) {
                        if retrying {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Try Again") {
                                retrying = true
                                Task {
                                    _ = await DictationHistory.retry(e)
                                    retrying = false
                                }
                            }
                            .buttonStyle(.paper)
                        }
                    }
                } else {
                    Text(e.text).font(.ui(15)).foregroundStyle(.ink).lineSpacing(6).textSelection(.enabled)
                }
                if e.raw != e.text, !e.raw.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("As heard")
                        Text(e.raw).font(.ui(13.5)).foregroundStyle(.soft).textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 26).padding(.top, Brand.headerTop).padding(.bottom, 26)
        }
        .onChange(of: entry) {
            sound?.stop()
            sound = nil
        }
    }

    private func play(_ url: URL) {
        if let s = sound, s.isPlaying {
            s.stop()
            sound = nil
            return
        }
        sound = NSSound(contentsOf: url, byReference: true)
        sound?.play()
    }
}

private struct RecordingDetail: View {
    let item: RecordingSummary
    @State private var copied = false
    @State private var retrying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DetailHeader(
                    recording: true, chip: id, title: item.title,
                    details: item.failure != nil
                        ? item.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
                        : "\(item.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(item.length) · \(item.points.count) point\(item.points.count == 1 ? "" : "s")"
                ) {
                    Button(copied ? "Copied" : "Copy", action: copy).buttonStyle(.ink).help("Copy the instructions for your agent")
                        .disabled(item.failure != nil)
                }
                if let failure = item.failure {
                    Banner(text: "\(failure). The recording is saved.", good: false) {
                        if retrying {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Try Again") {
                                retrying = true
                                NotificationCenter.default.post(name: .yapSketchRetryReport, object: item.folder)
                            }
                            .buttonStyle(.paper)
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .yapSketchRecordingsChanged)) { _ in retrying = false }
                }
                if !item.narration.isEmpty {
                    narration.font(.ui(15)).foregroundStyle(.ink).lineSpacing(6).textSelection(.enabled)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14, alignment: .top)], spacing: 16) {
                    ForEach(item.points, id: \.n) { p in
                        PointCard(point: p) { Self.open(item, at: item.points.filter { $0.picture != nil }.firstIndex(of: p) ?? 0) }
                    }
                }
                if item.failure == nil {
                    (Text("Agents can open this with ") + Text("yapsketch show \(id)").font(.mono(12.5)).foregroundColor(.ink))
                        .font(.ui(12.5)).foregroundStyle(.soft).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 26).padding(.top, Brand.headerTop).padding(.bottom, 26)
        }
    }

    private var id: String { CLI.id(item.folder) }

    /// The recording's pictures over the whole window, starting at the `index`th.
    @MainActor
    static func open(_ item: RecordingSummary, at index: Int) {
        let pictures = item.points.compactMap { p in p.picture.map { PictureViewer.Picture(n: p.n, url: $0) } }
        guard !pictures.isEmpty else { return }
        SettingsWindow.shared.viewer = PictureViewer.Pictures(all: pictures, index: min(index, pictures.count - 1))
    }

    private var narration: Text {
        item.narration.reduce(Text("")) { acc, piece in
            var t = acc + Text(piece.text)
            if let n = piece.marker { t = t + Text(" [\(n)] ").font(.mono(13)).foregroundColor(.coral) }
            return t
        }
    }

    private func copy() {
        guard let prompt = try? String(contentsOf: item.folder.appendingPathComponent("PROMPT.md"), encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

private struct PointCard: View {
    let point: RecordingSummary.Point
    let expand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A fixed 16:10 frame, so every card is the same shape and the grid lines up.
            Color.panel
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    if let url = point.picture { LoadedImage(url: url, maxPixels: 900) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.line))
                .overlay(alignment: .topLeading) {
                    Text("\(point.n)").font(.ui(11, .semibold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(.coral)).padding(8)
                }
                .contentShape(Rectangle())
                .onTapGesture { if point.picture != nil { expand() } }
                .help(point.picture != nil ? "Expand" : "")
        }
    }
}

private struct LoadedImage: View {
    let url: URL
    let maxPixels: Int
    var corner: CGFloat = 0
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image ?? Thumbnails.cached(url, maxPixels: maxPixels) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            image = Thumbnails.cached(url, maxPixels: maxPixels)
            if image == nil { image = await Thumbnails.load(url, maxPixels: maxPixels) }
        }
    }
}

extension Notification.Name {
    /// A recording's report was written (or rewritten): History reloads.
    static let yapSketchRecordingsChanged = Notification.Name("yapSketchRecordingsChanged")
    /// Make a recording's report again (its folder is the object), after it couldn't be made.
    static let yapSketchRetryReport = Notification.Name("yapSketchRetryReport")
}

import AppKit
import SwiftUI

/// The app icon itself (Resources/Icon/icon-rounded.png, the same picture as the website's),
/// so it can't drift from the real one. Without the bundle (the debug binary), a plain tile.
struct AppMark: View {
    var size: CGFloat = 26

    var body: some View {
        Group {
            if let icon = Self.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous).fill(Color(nsColor: Brand.markPaper))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    static let icon: NSImage? = Bundle.main.url(forResource: "AppMark", withExtension: "png").flatMap(NSImage.init(contentsOf:))

    /// The mark for AppKit views.
    static func image(size: CGFloat) -> NSImage {
        let image = icon?.copy() as? NSImage ?? NSImage(size: CGSize(width: size, height: size))
        image.size = CGSize(width: size, height: size)
        return image
    }
}

/// One key, as printed on a keycap: white, with a deeper bottom edge.
struct Keycap: View {
    let text: String
    var large = false

    var body: some View {
        let h: CGFloat = large ? 32 : 26
        // Geist Mono draws ⌃⌥⇧⌘ small; SF's are the ones on the keyboard.
        let symbol = text.count == 1 && "⌃⌥⇧⌘".contains(text)
        Text(text)
            .font(symbol ? .system(size: large ? 14 : 12.5) : .mono(large ? 14 : 12.5))
            .foregroundStyle(.ink)
            .padding(.horizontal, large ? 9 : 7)
            .frame(minWidth: h, minHeight: h)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: large ? 8 : 6).fill(.line)
                    RoundedRectangle(cornerRadius: large ? 8 : 6).fill(.white)
                        .padding([.top, .horizontal], 1).padding(.bottom, large ? 2.5 : 2)
                }
            }
    }
}

/// A shortcut as keycaps: its modifiers, then its key.
struct Keycaps: View {
    let keys: [String]
    var large = false

    init(_ shortcut: Shortcut, large: Bool = false) {
        self.init(keys: shortcut.modifierSymbols.map(String.init) + [shortcut.keyName], large: large)
    }

    init(keys: [String], large: Bool = false) {
        self.keys = keys
        self.large = large
    }

    var body: some View {
        HStack(spacing: large ? 5 : 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, k in Keycap(text: k, large: large) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.joined())
    }
}

/// A page's title, in the serif, centred on the window's header line.
struct PageTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.serif(28)).kerning(-0.5).foregroundStyle(.ink).lineLimit(1)
            .frame(height: Brand.headerHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A section's name: small, mono, spaced capitals.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.mono(11)).kerning(1.2).foregroundStyle(.soft).accessibilityAddTraits(.isHeader)
    }
}

/// A white card on the paper, its rows ruled apart.
struct BrandCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    row
                    if row.id != rows.last?.id { Rectangle().fill(.rule).frame(height: 1) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(.card))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.line))
    }
}

/// A labelled card, with an optional note under it.
struct BrandSection<Content: View>: View {
    let label: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(_ label: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.label = label
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label { SectionLabel(label) }
            BrandCard { content }
            if let footer { Text(footer).font(.ui(12.5)).foregroundStyle(.soft).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A card's row: a title, maybe a second line, and a control on the right.
struct BrandRow<Content: View>: View {
    let title: String
    var subtitle: String?
    var subtitleColor: Color = .soft
    /// A short tag beside the title, such as "Recommended".
    var badge: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, subtitle: String? = nil, subtitleColor: Color = .soft, badge: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleColor = subtitleColor
        self.badge = badge
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(.ui(14)).foregroundStyle(.ink)
                    if let badge {
                        Text(badge).font(.ui(11, .semibold)).foregroundStyle(.coralText)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(.coralWash))
                            .overlay(Capsule().strokeBorder(.coral.opacity(0.35)))
                    }
                }
                if let subtitle { Text(subtitle).font(.ui(12.5)).foregroundStyle(subtitleColor).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            // The control keeps its full width; a long subtitle wraps instead of squeezing it.
            content().fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: subtitle == nil ? 48 : 60)
    }
}

extension BrandRow where Content == InkSwitch {
    /// A switch row.
    init(_ title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(title, subtitle: subtitle) { InkSwitch(title: title, isOn: isOn) }
    }
}

/// An on/off switch: ink when on, a warm grey when off. A button underneath, so it takes
/// focus and Space like any control, and reads out as a switch.
struct InkSwitch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Capsule().fill(isOn ? .ink : .off)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.card).frame(width: 18, height: 18).shadow(color: .black.opacity(isOn ? 0 : 0.15), radius: 1, y: 1)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Settings pages: a serif title over cards, on the paper, scrolling.
struct BrandPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title)
                content
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, Brand.pageInset).padding(.top, Brand.headerTop).padding(.bottom, 36)
            // Not centred: the title stays put whatever the width (History's can't move).
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.paper)
    }
}

/// The main action: an ink pill.
struct InkButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(large ? 14.5 : 13, .medium))
            .foregroundStyle(.card)
            .padding(.horizontal, large ? 24 : 14)
            .frame(minHeight: large ? 44 : 32)
            .background(Capsule().fill(.ink))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.8 : 1)
            .contentShape(Capsule())
    }
}

/// A quieter action: a white pill with a line round it.
struct PaperButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(large ? 13.5 : 13))
            .foregroundStyle(.ink)
            .padding(.horizontal, large ? 16 : 12)
            .frame(minHeight: large ? 44 : 28)
            .background(Capsule().fill(configuration.isPressed ? .rule : .card))
            .overlay(Capsule().strokeBorder(.line))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Plain text that acts: Back, Open Settings again.
struct TextButtonStyle: ButtonStyle {
    var color: Color = .ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.ui(13.5)).foregroundStyle(color).opacity(configuration.isPressed ? 0.6 : 1)
            .padding(.horizontal, 6).frame(minHeight: 44).contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
    static var inkLarge: InkButtonStyle { InkButtonStyle(large: true) }
}

extension ButtonStyle where Self == PaperButtonStyle {
    static var paper: PaperButtonStyle { PaperButtonStyle() }
    static var paperLarge: PaperButtonStyle { PaperButtonStyle(large: true) }
}

/// Green, with a tick: done, granted.
struct DoneMark: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            Circle().fill(.done)
            Path { p in
                p.move(to: CGPoint(x: 5, y: 9.3))
                p.addLine(to: CGPoint(x: 7.6, y: 11.9))
                p.addLine(to: CGPoint(x: 13, y: 6.6))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: 18, height: 18)
            .scaleEffect(size / 18)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A line of news in a wash: green when it's good, coral when something's needed.
struct Banner<Trailing: View>: View {
    let text: String
    var good = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if good {
                DoneMark()
            } else {
                Circle().fill(.coral).frame(width: 9, height: 9).padding(.horizontal, 4.5)
            }
            Text(text).font(.ui(13.5, .medium)).foregroundStyle(good ? .doneText : .ink)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 14).fill(good ? .doneWash : .coralWash))
        .overlay { if !good { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.coral.opacity(0.35)) } }
    }
}

extension Banner where Trailing == EmptyView {
    init(text: String, good: Bool = true) { self.init(text: text, good: good) { EmptyView() } }
}

/// Two or three choices side by side: paper track, the chosen one a white tab. Each is a
/// button, read out as selected when it is.
struct BrandSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.0) { value, title in
                let on = value == selection
                Button {
                    selection = value
                } label: {
                    Text(title).font(.ui(12.5, on ? .medium : .regular)).foregroundStyle(on ? .ink : .soft)
                        .frame(maxWidth: .infinity).padding(.vertical, 6).padding(.horizontal, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? .card : .clear).shadow(color: .shade.opacity(on ? 0.12 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(.rule))
    }
}

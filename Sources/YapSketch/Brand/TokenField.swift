import AppKit
import SwiftUI

/// Words as chips, kept as one word per line in `text`.
struct TokenField: View {
    @Binding var text: String
    var prompt = "Add a word"
    @State private var draft = ""
    @State private var focus = false

    private var tokens: [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(tokens, id: \.self) { chip($0) }
            TokenInput(text: $draft, focus: $focus, prompt: prompt, commit: add, removeLast: removeLast)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)
                .frame(height: 26)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.paper))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.line))
        .contentShape(Rectangle())
        .onTapGesture { focus = true }
    }

    private func chip(_ word: String) -> some View {
        HStack(spacing: 5) {
            Text(word).font(.ui(13)).foregroundStyle(.ink).lineLimit(1)
            Button {
                remove(word)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.soft)
                    .frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 26)
        .background(Capsule().fill(.card))
        .overlay(Capsule().strokeBorder(.line))
    }

    private func add(_ words: String) {
        var all = tokens
        for w in words.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !w.isEmpty {
            if !all.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) { all.append(w) }
        }
        text = all.joined(separator: "\n")
    }

    private func remove(_ word: String) { text = tokens.filter { $0 != word }.joined(separator: "\n") }

    private func removeLast() {
        guard let last = tokens.last else { return }
        remove(last)
    }
}

private struct TokenInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focus: Bool
    let prompt: String
    let commit: (String) -> Void
    let removeLast: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = Brand.ui(13)
        f.textColor = Brand.ink
        f.placeholderAttributedString = NSAttributedString(string: prompt, attributes: [.font: Brand.ui(13), .foregroundColor: Brand.soft])
        f.cell?.lineBreakMode = .byTruncatingTail
        f.delegate = context.coordinator
        f.setAccessibilityLabel("Add a custom word")
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        if focus {
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                focus = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TokenInput
        init(_ parent: TokenInput) { self.parent = parent }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            let value = f.stringValue
            // A comma ends a word; what follows it stays in the field.
            if let comma = value.lastIndex(of: ",") {
                parent.commit(String(value[..<comma]))
                let rest = String(value[value.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                f.stringValue = rest
                parent.text = rest
            } else {
                parent.text = value
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                commitField(control)
                return true
            case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty:
                parent.removeLast()
                return true
            default:
                return false
            }
        }

        /// Leaving the field keeps what was typed.
        func controlTextDidEndEditing(_ n: Notification) {
            if let f = n.object as? NSControl { commitField(f) }
        }

        private func commitField(_ control: NSControl) {
            let value = control.stringValue.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            parent.commit(value)
            control.stringValue = ""
            parent.text = ""
        }
    }
}

/// Lays its views out in rows, wrapping when one doesn't fit; the last one (the field) takes
/// what's left of its row, or a row of its own if that's under 120 points.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        let frames = arrange(subviews, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if i == subviews.count - 1 {
                if width - x < 120 && x > 0 {
                    x = 0
                    y += rowHeight + spacing
                    rowHeight = 0
                }
                size.width = width - x
            } else if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            size.width = min(size.width, width)
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

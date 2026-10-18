import AppKit
import SwiftUI

/// A recording's pictures over the whole Settings window: pinch, double-tap or double-click to
/// zoom, ← → between them, Esc to close.
struct PictureViewer: View {
    struct Picture: Equatable {
        let n: Int
        let url: URL
    }

    struct Pictures: Equatable {
        var all: [Picture]
        var index: Int
    }

    @ObservedObject var nav: SettingsWindow

    var body: some View {
        if let shown = nav.viewer, shown.all.indices.contains(shown.index) {
            let picture = shown.all[shown.index]
            ZStack {
                Color(white: 0.07)
                VStack(spacing: 0) {
                    ZoomableImage(url: picture.url) { nav.viewer = nil }
                        .padding(.horizontal, 24).padding(.top, 44)
                    bar(shown, picture).frame(height: 56)
                }
                VStack {
                    HStack {
                        Spacer()
                        Button { nav.viewer = nil } label: {
                            Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.borderless).foregroundStyle(.white.opacity(0.8)).padding(10).help("Close (esc)")
                    }
                    Spacer()
                }
                // Keys work wherever focus is, as long as the window is in front.
                Group {
                    Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("") { nav.viewer = nil }.keyboardShortcut(.cancelAction)
                }
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            .ignoresSafeArea()
        }
    }

    private func bar(_ shown: Pictures, _ picture: Picture) -> some View {
        HStack(spacing: 0) {
            Button { step(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 30) }
                .help("Previous (←)").opacity(shown.all.count > 1 ? 1 : 0)
            Text(shown.all.count > 1 ? "[\(picture.n)] · \(shown.index + 1) of \(shown.all.count)" : "[\(picture.n)]")
                .font(.mono(12.5)).foregroundStyle(.white.opacity(0.8)).frame(width: 130)
            Button { step(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 30) }
                .help("Next (→)").opacity(shown.all.count > 1 ? 1 : 0)
        }
        .buttonStyle(.borderless).foregroundStyle(.white)
    }

    private func step(_ d: Int) {
        guard var shown = nav.viewer, shown.all.count > 1 else { return }
        shown.index = (shown.index + d + shown.all.count) % shown.all.count
        nav.viewer = shown
    }
}

/// The picture fitted to the space, in a scroll view that magnifies: macOS's own pinch and
/// smart zoom, plus double-click; dragging or scrolling moves around once zoomed in. A click
/// beside the picture closes.
private struct ZoomableImage: NSViewRepresentable {
    let url: URL
    let close: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FittingScrollView {
        let scroll = FittingScrollView()
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 8
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.contentView = CenteringClipView()
        scroll.contentView.drawsBackground = false
        let image = NSImageView()
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.cornerRadius = 6
        scroll.documentView = image

        let double = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClick(_:)))
        double.numberOfClicksRequired = 2
        let single = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleClick(_:)))
        single.numberOfClicksRequired = 1
        single.delegate = context.coordinator
        scroll.addGestureRecognizer(double)
        scroll.addGestureRecognizer(single)
        context.coordinator.scroll = scroll
        context.coordinator.double = double
        return scroll
    }

    func updateNSView(_ scroll: FittingScrollView, context: Context) {
        context.coordinator.close = close
        guard context.coordinator.url != url, let view = scroll.documentView as? NSImageView else { return }
        context.coordinator.url = url
        scroll.magnification = 1
        view.image = NSImage(contentsOf: url)
        scroll.needsLayout = true
    }

    final class Coordinator: NSObject, NSGestureRecognizerDelegate {
        var url: URL?
        var close: () -> Void = {}
        weak var scroll: FittingScrollView?
        weak var double: NSGestureRecognizer?

        /// A single click waits until it can't be the start of a double-click.
        func gestureRecognizer(_ g: NSGestureRecognizer, shouldRequireFailureOf other: NSGestureRecognizer) -> Bool {
            other === double
        }

        @objc func doubleClick(_ g: NSClickGestureRecognizer) {
            guard let scroll else { return }
            let at = g.location(in: scroll.documentView)
            scroll.animator().setMagnification(scroll.magnification > 1.01 ? 1 : 2.5, centeredAt: at)
        }

        @objc func singleClick(_ g: NSClickGestureRecognizer) {
            guard let scroll, scroll.magnification <= 1.01, let view = scroll.documentView as? NSImageView else { return }
            if !scroll.imageRect(in: view).contains(g.location(in: view)) { close() }
        }
    }
}

/// Keeps the picture as big as the view at 1×, whatever the window's size; zooming then
/// magnifies it from there.
private final class FittingScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let doc = documentView else { return }
        let size = contentSize
        if doc.frame.size != size { doc.frame = CGRect(origin: .zero, size: size) }
    }

    /// Where the fitted picture is drawn inside `view`.
    func imageRect(in view: NSImageView) -> CGRect {
        guard let image = view.image, image.size.width > 0, image.size.height > 0 else { return .zero }
        let b = view.bounds
        let scale = min(b.width / image.size.width, b.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(x: b.midX - size.width / 2, y: b.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// Centers the picture when it's smaller than the view.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

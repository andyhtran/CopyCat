import AppKit
import SwiftUI

struct WindowFocusSink: NSViewRepresentable {
    final class SinkView: NSView {
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { false }
        override func drawFocusRingMask() {}
        override var focusRingMaskBounds: NSRect { .zero }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            if window.isKeyWindow {
                window.makeFirstResponder(self)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = SinkView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func windowFocusSink() -> some View {
        background(WindowFocusSink().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

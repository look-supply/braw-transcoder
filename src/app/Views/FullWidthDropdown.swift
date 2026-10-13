import SwiftUI
import AppKit

// A native popup with a flexible intrinsic width, so the control itself fills
// its row rather than only expanding the SwiftUI frame around it.
struct FullWidthDropdown: NSViewRepresentable {
    struct Option: Equatable { let title: String; let value: Int }
    let title: String
    let options: [Option]
    @Binding var selection: Int
    @Environment(\.isEnabled) private var isEnabled

    final class Popup: NSPopUpButton {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: FullWidthDropdown
        var options: [Option] = []
        init(_ parent: FullWidthDropdown) { self.parent = parent }
        @objc func select(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard options.indices.contains(index) else { return }
            parent.selection = options[index].value
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Popup {
        let popup = Popup(frame: .zero, pullsDown: false)
        popup.target = context.coordinator
        popup.action = #selector(Coordinator.select(_:))
        return popup
    }
    func updateNSView(_ popup: Popup, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.options != options {
            popup.removeAllItems()
            popup.addItems(withTitles: options.map(\.title))
            context.coordinator.options = options
        }
        popup.selectItem(at: options.firstIndex { $0.value == selection } ?? -1)
        popup.isEnabled = isEnabled
        popup.setAccessibilityLabel(title)
    }
}


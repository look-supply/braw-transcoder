import SwiftUI
import AppKit

struct ResettableSettingLabel: View {
    let title: String
    let reset: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    var body: some View {
        Text(title)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if isEnabled { reset() } }
            .help("Double-click to reset \(title)")
            .accessibilityAction(named: Text("Reset \(title)")) { if isEnabled { reset() } }
    }
}

struct NumericSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let initialValue: Double
    let step: Double
    let scrubStep: Double
    let precision: Int
    var suffix = ""
    @State private var resetHovered = false
    private var canReset: Bool { abs(value - initialValue) >= 0.00000001 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ResettableSettingLabel(title: title) { value = initialValue }
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 4)
                ScrubbableNumberField(title: title, value: $value, range: range,
                                     step: step, scrubStep: scrubStep, precision: precision)
                    .frame(width: 64, height: 20)
                    .help("Click to type or drag horizontally to adjust. Hold Option for finer adjustment.")
                if !suffix.isEmpty { Text(suffix).font(.caption).foregroundStyle(.secondary) }
                Button { value = initialValue } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13)).frame(width: 20, height: 20)
                        .foregroundStyle(resetHovered && canReset ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canReset)
                .onHover { resetHovered = $0 }
                .padding(.leading, 8)
                .help("Reset \(title)")
                .accessibilityLabel("Reset \(title)")
            }
            Slider(value: Binding(get: { value }, set: { requested in
                value = min(range.upperBound, max(range.lowerBound, (requested / step).rounded() * step))
            }), in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

struct ScrubbableNumberField: NSViewRepresentable {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let scrubStep: Double
    let precision: Int
    @Environment(\.isEnabled) private var isEnabled

    final class Field: NSTextField {
        static let scrubCursor: NSCursor = {
            let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
                let path = NSBezierPath()
                let points = [NSPoint(x: 2, y: 9), NSPoint(x: 8, y: 15),
                              NSPoint(x: 8, y: 11), NSPoint(x: 16, y: 11),
                              NSPoint(x: 16, y: 15), NSPoint(x: 22, y: 9),
                              NSPoint(x: 16, y: 3), NSPoint(x: 16, y: 7),
                              NSPoint(x: 8, y: 7), NSPoint(x: 8, y: 3)]
                path.move(to: points[0])
                for point in points.dropFirst() { path.line(to: point) }
                path.close()
                path.lineWidth = 2
                path.lineJoinStyle = .round
                NSColor.white.setStroke(); path.stroke()
                NSColor.black.setFill(); path.fill()
                return true
            }
            return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 9))
        }()
        var scrub: ((Double) -> Void)?
        var scrubStep = 0.01
        var currentValue = 0.0
        // AppKit's begin-editing notification can wait until the first keystroke.
        // The field editor is the source of truth for focus, including empty edits.
        var editing: Bool { currentEditor() != nil }
        var isScrubbing = false
        private var pointerTracking: NSTrackingArea?

        func updatePointerCursor() {
            if !isEnabled { NSCursor.arrow.set() }
            else if isScrubbing || !editing { Self.scrubCursor.set() }
            else { NSCursor.iBeam.set() }
        }
        override func updateTrackingAreas() {
            if let pointerTracking { removeTrackingArea(pointerTracking) }
            super.updateTrackingAreas()
            let area = NSTrackingArea(rect: .zero,
                options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited,
                          .mouseMoved, .cursorUpdate, .enabledDuringMouseDrag],
                owner: self, userInfo: nil)
            addTrackingArea(area)
            pointerTracking = area
        }
        override func cursorUpdate(with event: NSEvent) { updatePointerCursor() }
        override func mouseEntered(with event: NSEvent) { updatePointerCursor() }
        override func mouseMoved(with event: NSEvent) { updatePointerCursor() }
        override func mouseExited(with event: NSEvent) {
            if !isScrubbing { NSCursor.arrow.set() }
        }
        func prepareForMouseDown(_ event: NSEvent) {
            guard editing, event.window === window else { return }
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if event.type == .rightMouseDown && inside { return }
            // Dismiss before hit testing: an active field editor would otherwise
            // receive the drag and select text instead of adjusting the number.
            window?.makeFirstResponder(nil)
            if inside { updatePointerCursor() }
            else { NSCursor.arrow.set() }
        }
        override func selectText(_ sender: Any?) {
            guard isEnabled else { return }
            isEditable = true
            isSelectable = true
            super.selectText(sender)
            updatePointerCursor()
        }

        override func resetCursorRects() {
            if isEnabled && !editing { addCursorRect(bounds, cursor: Self.scrubCursor) }
            else { super.resetCursorRects() }
        }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled, let window else { return }
            if editing { window.makeFirstResponder(nil) }
            let origin = event.locationInWindow.x
            let start = currentValue
            var dragged = false
            window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { next, stop in
                guard let next else { stop.pointee = true; return }
                let distance = next.locationInWindow.x - origin
                if next.type == .leftMouseDragged && (dragged || abs(distance) >= 3) {
                    dragged = true
                    self.isScrubbing = true
                    self.updatePointerCursor()
                    let fine = next.modifierFlags.contains(.option) ? 0.1 : 1.0
                    self.scrub?(start + distance * self.scrubStep * fine)
                }
                if next.type == .leftMouseUp { stop.pointee = true }
            }
            isScrubbing = false
            if !dragged { selectText(nil) }
            updatePointerCursor()
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ScrubbableNumberField
        var outsideClickMonitor: Any?
        init(_ parent: ScrubbableNumberField) { self.parent = parent }
        func formatted(_ value: Double) -> String {
            String(format: "%.*f", parent.precision, value)
        }
        func apply(_ requested: Double, to field: Field) {
            guard requested.isFinite else { return }
            let bounded = min(parent.range.upperBound, max(parent.range.lowerBound, requested))
            let rounded = (bounded / parent.step).rounded() * parent.step
            let applied = min(parent.range.upperBound, max(parent.range.lowerBound, rounded))
            field.currentValue = applied
            if parent.value != applied { parent.value = applied }
            if !field.editing { field.stringValue = formatted(applied) }
        }
        @objc func commit(_ field: Field) {
            let draft = (field.currentEditor()?.string ?? field.stringValue)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            if let parsed = Double(draft), parsed.isFinite { apply(parsed, to: field) }
        }
        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? Field else { return }
            field.updatePointerCursor()
            field.window?.invalidateCursorRects(for: field)
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? Field else { return }
            let cancelled = (notification.userInfo?["NSTextMovement"] as? Int) == NSCancelTextMovement
            if !cancelled { commit(field) }
            field.currentValue = parent.value
            field.stringValue = formatted(parent.value)
            field.isEditable = false
            field.isSelectable = false
            field.window?.invalidateCursorRects(for: field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> Field {
        let field = Field(frame: .zero)
        // The idle control cannot start native text selection on mouse-down.
        // Only a completed click enables editing; a drag stays in scrub mode.
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.scrub = { [weak field, weak coordinator = context.coordinator] value in
            guard let field, let coordinator else { return }
            coordinator.apply(value, to: field)
        }
        context.coordinator.outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak field] event in
            field?.prepareForMouseDown(event)
            return event
        }
        return field
    }
    static func dismantleNSView(_ field: Field, coordinator: Coordinator) {
        if let monitor = coordinator.outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.outsideClickMonitor = nil
        }
    }
    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = isEnabled
        field.scrubStep = scrubStep
        field.currentValue = value
        field.setAccessibilityLabel(title)
        if !field.editing { field.stringValue = context.coordinator.formatted(value) }
        field.window?.invalidateCursorRects(for: field)
    }
}

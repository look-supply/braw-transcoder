import AppKit
import SwiftUI

@MainActor final class NumericFixture: ObservableObject {
    @Published var value = 0.0
    @Published var flag = false
}
struct NumericFixtureView: View {
    @ObservedObject var fixture: NumericFixture
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NumericSlider(title: "Exposure", value: $fixture.value, range: -5...5,
                          initialValue: 0, step: 0.01, scrubStep: 0.01, precision: 2)
            Toggle(isOn: $fixture.flag) {
                HStack {
                    ResettableSettingLabel(title: "Highlight recovery") { fixture.flag = false }
                    Spacer(minLength: 8)
                }
            }.toggleStyle(.switch).controlSize(.small)
        }.padding(12)
    }
}

@main @MainActor struct NumericSliderTests {
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let fixture = NumericFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 250, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: NumericFixtureView(fixture: fixture))
        window.contentView = host
        window.orderFront(nil)
        Task {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let field = descendants(host).compactMap { $0 as? ScrubbableNumberField.Field }.first!
            let bounds = field.convert(field.bounds, to: host)
            precondition(bounds.minX >= 0 && bounds.maxX <= host.bounds.width, "Numeric field overflowed narrow Inspector")
            let hover = NSEvent.mouseEvent(with: .mouseMoved,
                location: field.convert(NSPoint(x: 10, y: 10), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0)!
            field.mouseMoved(with: hover)
            precondition(NSCursor.current == ScrubbableNumberField.Field.scrubCursor, "Hover did not use east/west cursor")

            field.selectText(nil)
            field.mouseMoved(with: hover)
            precondition(field.editing && NSCursor.current == NSCursor.iBeam, "Text editing did not use I-beam cursor")
            let editor = field.currentEditor() as! NSTextView
            editor.deleteBackward(nil)
            for character in ["-", "1", ".", "3", "5"] {
                editor.insertText(character, replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(editor.string == "-1.35" && fixture.value == 0, "Partial numeric input was rewritten or applied early")
            let outsideUp = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 2, y: 2), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            let outsideDown = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 2, y: 2), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.postEvent(outsideUp, atStart: true)
            NSApp.postEvent(outsideDown, atStart: true)
            try await Task.sleep(for: .milliseconds(30))
            precondition(abs(fixture.value + 1.35) < 0.000001, "Decimal input did not commit")
            precondition(!field.editing && field.currentEditor() == nil, "Clicking blank space did not defocus numeric field")
            field.mouseMoved(with: hover)
            precondition(NSCursor.current == ScrubbableNumberField.Field.scrubCursor, "Hover after editing retained text cursor")

            @MainActor func drag(_ pixels: Double, modifiers: NSEvent.ModifierFlags = []) async throws {
                let origin = field.convert(NSPoint(x: 10, y: 10), to: nil)
                @MainActor func event(_ type: NSEvent.EventType, x: Double) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: origin.y),
                        modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                }
                NSApp.postEvent(event(.leftMouseUp, x: origin.x + pixels), atStart: true)
                NSApp.postEvent(event(.leftMouseDragged, x: origin.x + pixels), atStart: true)
                NSApp.postEvent(event(.leftMouseDown, x: origin.x), atStart: true)
                try await Task.sleep(for: .milliseconds(50))
            }
            // Start from focused text to catch field-editor interception of a drag.
            field.selectText(nil)
            try await drag(100)
            precondition(abs(fixture.value + 0.35) < 0.000001, "Horizontal dragging did not increment value")
            precondition(!field.editing && NSCursor.current == ScrubbableNumberField.Field.scrubCursor, "Scrubbing focused text or retained I-beam cursor")
            try await drag(-100, modifiers: .option)
            precondition(abs(fixture.value + 0.45) < 0.000001, "Fine dragging did not decrement value")
            try await drag(10000)
            precondition(fixture.value == 5, "Scrubbing exceeded upper limit")
            try await drag(-10000)
            precondition(fixture.value == -5, "Scrubbing exceeded lower limit")
            let clickPoint = field.convert(NSPoint(x: 10, y: 10), to: nil)
            let clickUp = NSEvent.mouseEvent(with: .leftMouseUp, location: clickPoint, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            let clickDown = NSEvent.mouseEvent(with: .leftMouseDown, location: clickPoint, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.postEvent(clickUp, atStart: true)
            NSApp.postEvent(clickDown, atStart: true)
            try await Task.sleep(for: .milliseconds(50))
            let clickedEditor = field.currentEditor() as! NSTextView
            precondition(clickedEditor.selectedRange() == NSRange(location: 0, length: field.stringValue.utf16.count),
                         "Click selected one digit instead of enabling whole-value editing")
            window.makeFirstResponder(nil)
            try await Task.sleep(for: .milliseconds(50))
            // The reset icon follows 6pt row spacing + 8pt leading padding and
            // has a 20pt hit area. Exercise the actual SwiftUI button mouse action.
            let resetPoint = field.convert(NSPoint(x: field.bounds.maxX + 24, y: field.bounds.midY), to: nil)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: resetPoint, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: resetPoint, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            try await Task.sleep(for: .milliseconds(30))
            precondition(fixture.value == 0 && field.stringValue == "0.00", "Reset did not restore initial value and display")
            fixture.value = 2
            try await Task.sleep(for: .milliseconds(30))
            let labelPoint = host.convert(NSPoint(x: 30, y: field.convert(field.bounds, to: host).midY), to: nil)
            for count in [2, 1] {
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: labelPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: 0)!
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: labelPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: 1)!
                NSApp.postEvent(up, atStart: true)
                NSApp.postEvent(down, atStart: true)
            }
            try await Task.sleep(for: .milliseconds(100))
            precondition(fixture.value == 0, "Double-clicking label did not restore initial value")
            fixture.flag = true
            try await Task.sleep(for: .milliseconds(30))
            let toggle = descendants(host).compactMap { $0 as? NSSwitch }.first!
            let toggleLabelPoint = host.convert(NSPoint(x: 30, y: toggle.convert(toggle.bounds, to: host).midY), to: nil)
            for count in [2, 1] {
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: toggleLabelPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: 0)!
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: toggleLabelPoint, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: count, clickCount: count, pressure: 1)!
                NSApp.postEvent(up, atStart: true)
                NSApp.postEvent(down, atStart: true)
            }
            try await Task.sleep(for: .milliseconds(100))
            precondition(!fixture.flag, "Double-clicking switch label did not restore default")
            for (text, expected) in [("99", 5.0), ("-99", -5.0), ("nan", -5.0), ("", -5.0)] {
                field.selectText(nil)
                let editor = field.currentEditor() as! NSTextView
                editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                window.makeFirstResponder(nil)
                try await Task.sleep(for: .milliseconds(10))
                precondition(fixture.value == expected, "Invalid/out-of-range text escaped validation")
            }
            field.isEnabled = false
            let disabledDown = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            field.mouseDown(with: disabledDown)
            precondition(fixture.value == -5, "Disabled field responded to mouse input")
            print("PASS: numeric typing, partial decimals, drag/fine drag, limits, reset, narrow layout")
            exit(0)
        }
        NSApp.run()
    }
}

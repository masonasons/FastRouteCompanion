//
//  FormBuilder.swift
//  FastRoute Companion
//
//  Builds labelled forms in an NSGridView, with every control carrying its
//  label as its accessibility label so a screen reader says what a field is
//  for wherever focus lands.
//

import AppKit

@MainActor
final class FormBuilder {
    let grid: NSGridView

    init() {
        grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.rowAlignment = .firstBaseline
        grid.translatesAutoresizingMaskIntoConstraints = false
    }

    @discardableResult
    func addRow(_ label: String, _ control: NSView) -> NSGridRow {
        let text = NSTextField(labelWithString: label)
        text.alignment = .right
        control.setAccessibilityLabel(label.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
        let row = grid.addRow(with: [text, control])
        return row
    }

    /// A control that spans both columns, such as a checkbox or a table.
    @discardableResult
    func addFullWidth(_ view: NSView) -> NSGridRow {
        let row = grid.addRow(with: [view])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        return row
    }

    func addHeading(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let row = addFullWidth(label)
        row.topPadding = 8
    }

    // MARK: Controls

    static func textField(_ value: String, width: CGFloat = 260) -> NSTextField {
        let f = NSTextField(string: value)
        f.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        return f
    }

    static func numberField(_ value: Int, width: CGFloat = 100) -> NSTextField {
        let f = NSTextField(string: String(value))
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        f.alignment = .right
        return f
    }

    static func numberField(_ value: Double, width: CGFloat = 100) -> NSTextField {
        let f = NSTextField(string: FormBuilder.format(value))
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        f.alignment = .right
        return f
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    static func popup(_ titles: [String], selected: Int) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        if titles.indices.contains(selected) { p.selectItem(at: selected) }
        return p
    }

    static func checkbox(_ title: String, on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        return b
    }

    /// A slider whose value is read out in the caller's words, not as a percentage.
    static func slider(min: Double, max: Double, value: Double, describe: @escaping (Double) -> String) -> DescribedSlider {
        let s = DescribedSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        s.describe = describe
        s.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return s
    }

    static func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        return stack
    }
}

/// An NSSlider that reports its actual setting ("250 Hz", "-6 dB") to
/// accessibility and in a label beside it, instead of a position percentage.
final class DescribedSlider: NSSlider {
    var describe: ((Double) -> String)?
    var onChange: ((Double) -> Void)?
    let readout = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(changed(_:))
    }

    required init?(coder: NSCoder) { fatalError() }

    convenience init(value: Double, minValue: Double, maxValue: Double, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
        self.target = self
        self.action = #selector(changed(_:))
    }

    override var doubleValue: Double {
        didSet { readout.stringValue = describe?(doubleValue) ?? "" }
    }

    override func accessibilityValue() -> Any? {
        describe?(doubleValue) ?? super.accessibilityValue()
    }

    @objc private func changed(_ sender: Any?) {
        readout.stringValue = describe?(doubleValue) ?? ""
        onChange?(doubleValue)
    }

    /// Up and Page Up raise the value; Down and Page Down lower it.
    override func keyDown(with event: NSEvent) {
        let step = (maxValue - minValue) / 20
        switch event.keyCode {
        case 126, 116:   // up, page up
            doubleValue = min(maxValue, doubleValue + (event.keyCode == 116 ? step * 2 : step))
            changed(nil)
        case 125, 121:   // down, page down
            doubleValue = max(minValue, doubleValue - (event.keyCode == 121 ? step * 2 : step))
            changed(nil)
        default:
            super.keyDown(with: event)
        }
    }

    /// The slider with its readout beside it.
    func withReadout() -> NSStackView {
        readout.stringValue = describe?(doubleValue) ?? ""
        readout.setAccessibilityElement(false)
        let stack = NSStackView(views: [self, readout])
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }
}

/// A prompt for one line of text, as a sheet.
enum TextPrompt {
    @MainActor
    static func ask(_ message: String, detail: String = "", initial: String = "", in window: NSWindow?,
                    completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        field.setAccessibilityLabel(message)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

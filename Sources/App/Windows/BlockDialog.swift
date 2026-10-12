//
//  BlockDialog.swift
//  FastRoute Companion
//
//  The sheet every block's settings live in: a scrolling form, OK, Cancel
//  and Apply. Apply (Command Shift A) pushes the change into the running
//  session without closing, so it can be heard and adjusted again.
//

import AppKit

@MainActor
class BlockDialog: NSWindowController {
    var block: Block
    let onApply: (Block) -> Void
    let form = FormBuilder()
    private var parentWindow: NSWindow?

    init(block: Block, title: String, onApply: @escaping (Block) -> Void) {
        self.block = block
        self.onApply = onApply
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        super.init(window: window)
        buildForm()
        layout()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Subclasses add their rows to `form`.
    func buildForm() {}

    /// Subclasses read the controls back into a block, or return nil after
    /// telling the user what is wrong.
    func collect() -> Block? { block }

    /// Subclasses that watch for changes while open can stop here.
    func dialogWillClose() {}

    private var strongSelf: BlockDialog?

    private func layout() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = NSView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(form.grid)
        NSLayoutConstraint.activate([
            form.grid.topAnchor.constraint(equalTo: clip.topAnchor, constant: 16),
            form.grid.leadingAnchor.constraint(equalTo: clip.leadingAnchor, constant: 20),
            form.grid.trailingAnchor.constraint(lessThanOrEqualTo: clip.trailingAnchor, constant: -20),
            form.grid.bottomAnchor.constraint(equalTo: clip.bottomAnchor, constant: -16),
        ])
        scroll.documentView = clip
        clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true

        let ok = NSButton(title: "OK", target: self, action: #selector(okPressed(_:)))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyPressed(_:)))
        apply.keyEquivalent = "A"
        apply.keyEquivalentModifierMask = [.command, .shift]
        apply.setAccessibilityHelp("Applies the settings to the running session without closing. Command Shift A.")
        let buttons = FormBuilder.buttonRow([apply, cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        let fitting = form.grid.fittingSize
        let height = min(fitting.height + 100, (NSScreen.main?.visibleFrame.height ?? 800) - 120)
        window.setContentSize(NSSize(width: max(680, fitting.width + 60), height: max(320, height)))
    }

    func present(in parent: NSWindow) {
        guard let window else { return }
        parentWindow = parent
        strongSelf = self
        if let first = form.grid.subviews.first(where: { $0 is NSControl && $0.acceptsFirstResponder }) {
            window.initialFirstResponder = first
        }
        parent.beginSheet(window) { [weak self] _ in
            self?.dialogWillClose()
            self?.strongSelf = nil
        }
    }

    @objc private func okPressed(_ sender: Any?) {
        guard let updated = collect() else { return }
        block = updated
        onApply(updated)
        finish()
    }

    @objc private func applyPressed(_ sender: Any?) {
        guard let updated = collect() else { return }
        block = updated
        onApply(updated)
        window?.contentView?.announce("Applied")
    }

    @objc private func cancelPressed(_ sender: Any?) { finish() }

    private func finish() {
        guard let window, let parentWindow else { return }
        parentWindow.endSheet(window)
    }

    // MARK: Validation helpers

    func complain(_ message: String, detail: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    func intValue(_ field: NSTextField, _ name: String, _ range: ClosedRange<Int>) -> Int? {
        guard let v = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), range.contains(v) else {
            complain("\(name) has to be a whole number from \(range.lowerBound) to \(range.upperBound).")
            window?.makeFirstResponder(field)
            return nil
        }
        return v
    }

    func doubleValue(_ field: NSTextField, _ name: String, _ range: ClosedRange<Double>) -> Double? {
        guard let v = Double(field.stringValue.trimmingCharacters(in: .whitespaces)), range.contains(v) else {
            complain("\(name) has to be a number from \(FormBuilder.format(range.lowerBound)) to \(FormBuilder.format(range.upperBound)).")
            window?.makeFirstResponder(field)
            return nil
        }
        return v
    }

    static func note(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.textColor = .secondaryLabelColor
        f.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        f.preferredMaxLayoutWidth = 560
        f.isSelectable = false
        return f
    }
}

//
//  NavigableTableView.swift
//  FastRoute Companion
//
//  An NSTableView that turns the keys a list needs into closures: Return to
//  open, Space to toggle, Delete, and the Command and Option arrow chords
//  FastRoute uses for moving blocks and nudging volume.
//

import AppKit

final class NavigableTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCommandUp: (() -> Void)?
    var onCommandDown: (() -> Void)?
    var onOptionUp: (() -> Void)?
    var onOptionDown: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?

    private enum Key {
        static let `return`: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let space: UInt16 = 49
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let upArrow: UInt16 = 126
        static let downArrow: UInt16 = 125
        static let f10: UInt16 = 109
        static let applicationsKey: UInt16 = 110
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case Key.return, Key.keypadEnter:
            if let onReturn { onReturn(); return }
        case Key.space:
            if let onSpace { onSpace(); return }
        case Key.delete, Key.forwardDelete:
            if let onDelete { onDelete(); return }
        case Key.upArrow:
            if flags == [.command], let onCommandUp { onCommandUp(); return }
            if flags == [.option], let onOptionUp { onOptionUp(); return }
        case Key.downArrow:
            if flags == [.command], let onCommandDown { onCommandDown(); return }
            if flags == [.option], let onOptionDown { onOptionDown(); return }
        case Key.applicationsKey:
            if showContextMenuForSelection() { return }
        case Key.f10:
            if flags.contains(.shift), showContextMenuForSelection() { return }
        default:
            break
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menuProvider else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 && !selectedRowIndexes.contains(row) { selectRowIndexes([row], byExtendingSelection: false) }
        return menuProvider(row)
    }

    /// Opens the context menu for the selected row from the keyboard, as
    /// Shift F10 or the Applications key does in FastRoute.
    @discardableResult
    func showContextMenuForSelection() -> Bool {
        let row = selectedRow
        guard row >= 0, let menuProvider, let menu = menuProvider(row) else { return false }
        let rect = rect(ofRow: row)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + 20, y: rect.maxY), in: self)
        return true
    }

    /// The row to act on: the clicked row for a context menu, else the selection.
    var actionRow: Int {
        if clickedRow >= 0 { return clickedRow }
        return selectedRow
    }

    func selectAndScroll(row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes([row], byExtendingSelection: false)
        scrollRowToVisible(row)
    }
}

extension NSView {
    /// Tells VoiceOver something happened that the screen does not show by itself.
    func announce(_ text: String) {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

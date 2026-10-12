//
//  SessionWindowController.swift
//  FastRoute Companion
//
//  One session: its blocks in pipeline order, the keys FastRoute uses on
//  them, and a status field saying what each running block is doing.
//

import AppKit

@MainActor
final class SessionWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, ItemActions {
    let sessionID: UUID
    private let store: SessionStore
    private let engine: SessionEngine
    private let table = NavigableTableView()
    private let status = StatusView()
    private var runButton: NSButton!
    var onClose: (() -> Void)?

    init(sessionID: UUID, store: SessionStore, engine: SessionEngine) {
        self.sessionID = sessionID
        self.store = store
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.setFrameAutosaveName("SessionWindow-\(sessionID.uuidString)")
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
        status.provider = { [weak self] in
            guard let self, let session = self.session else { return "" }
            return self.engine.statusText(for: session)
        }
        status.startUpdating()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    var session: Session? { store.session(id: sessionID) }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let heading = NSTextField(labelWithString: "Session blocks, in pipeline order:")
        heading.translatesAutoresizingMaskIntoConstraints = false

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Block"
        nameColumn.width = 200
        let detailColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("detail"))
        detailColumn.title = "Settings"
        detailColumn.width = 460
        table.addTableColumn(nameColumn)
        table.addTableColumn(detailColumn)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Session blocks")
        table.onReturn = { [weak self] in self?.editBlock(nil) }
        table.onSpace = { [weak self] in self?.toggleBlock(nil) }
        table.onDelete = { [weak self] in self?.deleteItem(nil) }
        table.onCommandUp = { [weak self] in self?.moveBlockUp(nil) }
        table.onCommandDown = { [weak self] in self?.moveBlockDown(nil) }
        table.onOptionUp = { [weak self] in self?.volumeUp(nil) }
        table.onOptionDown = { [weak self] in self?.volumeDown(nil) }
        table.doubleAction = #selector(editBlock(_:))
        table.target = self
        table.menuProvider = { [weak self] row in self?.contextMenu(row: row) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let addButton = NSButton(title: "Add Block…", target: self, action: #selector(addBlock(_:)))
        runButton = NSButton(title: "Run", target: self, action: #selector(runOrStop(_:)))
        let buttons = FormBuilder.buttonRow([addButton, runButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Return opens a block's settings, Space turns it on or off, Command Up and Down move it, Option Up and Down change its volume, Command R runs the session.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: "Status:")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        for v in [heading, scroll, buttons, hint, statusLabel, status] { content.addSubview(v) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.initialFirstResponder = table
    }

    func refresh() {
        guard let session else { close(); return }
        window?.title = session.title + (engine.isRunning(sessionID) ? " (running)" : "")
        runButton.title = engine.isRunning(sessionID) ? "Stop" : "Run"
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 && selected < table.numberOfRows { table.selectRowIndexes([selected], byExtendingSelection: false) }
        status.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        status.stopUpdating()
        onClose?()
    }

    private var selectedBlock: Block? {
        guard let session else { return nil }
        let row = table.actionRow
        guard row >= 0, row < session.blocks.count else { return nil }
        return session.blocks[row]
    }

    // MARK: Actions

    @objc func addBlock(_ sender: Any?) {
        guard let window else { return }
        BlockLibrarySheet.present(in: window) { [weak self] kind in
            guard let self, let kind, var session = self.session else { return }
            let block = Block.new(kind: kind)
            session.blocks.append(block)
            self.store.update(session)
            self.refresh()
            self.table.selectAndScroll(row: session.blocks.count - 1)
            self.edit(block: block)
        }
    }

    @objc func editBlock(_ sender: Any?) {
        guard let block = selectedBlock else { return }
        edit(block: block)
    }

    private func edit(block: Block) {
        guard let window else { return }
        let apply: (Block) -> Void = { [weak self] updated in
            guard let self else { return }
            self.store.updateBlock(sessionID: self.sessionID, block: updated)
            if self.engine.isRunning(self.sessionID) { self.engine.apply(block: updated, in: self.sessionID) }
            self.refresh()
        }
        switch block.kind {
        case .netSend:
            NetSendDialog(block: block, onApply: apply).present(in: window)
        case .netReceive:
            NetReceiveDialog(block: block, onApply: apply).present(in: window)
        }
    }

    @objc func toggleBlock(_ sender: Any?) {
        guard var block = selectedBlock else { return }
        block.enabled.toggle()
        store.updateBlock(sessionID: sessionID, block: block)
        if engine.isRunning(sessionID) { engine.apply(block: block, in: sessionID) }
        refresh()
        table.announce(block.enabled ? "\(block.displayName) on" : "\(block.displayName) off")
    }

    @objc func moveBlockUp(_ sender: Any?) { moveBlock(by: -1) }
    @objc func moveBlockDown(_ sender: Any?) { moveBlock(by: 1) }

    private func moveBlock(by delta: Int) {
        guard var session else { return }
        let row = table.selectedRow
        let target = row + delta
        guard row >= 0, session.blocks.indices.contains(target) else { return }
        session.blocks.swapAt(row, target)
        store.update(session)
        refresh()
        table.selectAndScroll(row: target)
        table.announce("\(session.blocks[target].displayName) moved to position \(target + 1) of \(session.blocks.count)")
    }

    @objc func volumeUp(_ sender: Any?) { changeVolume(by: 5) }
    @objc func volumeDown(_ sender: Any?) { changeVolume(by: -5) }

    private func changeVolume(by delta: Int) {
        guard var block = selectedBlock else { return }
        block.volumePercent = max(0, min(200, block.volumePercent + delta))
        store.updateBlock(sessionID: sessionID, block: block)
        engine.setGain(block: block, in: sessionID)
        refresh()
        table.announce("\(block.displayName) volume \(block.volumePercent) percent")
    }

    @objc func renameItem(_ sender: Any?) {
        guard var block = selectedBlock else { return }
        TextPrompt.ask("Name this block", detail: "Leave it empty to use the block's own name.", initial: block.customName ?? "", in: window) { [weak self] name in
            guard let self, let name else { return }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            block.customName = trimmed.isEmpty ? nil : trimmed
            self.store.updateBlock(sessionID: self.sessionID, block: block)
            self.refresh()
        }
    }

    @objc func deleteItem(_ sender: Any?) {
        guard var session, let block = selectedBlock, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(block.displayName) from \(session.title)?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let row = self.table.selectedRow
            session.blocks.removeAll { $0.id == block.id }
            self.store.update(session)
            if self.engine.isRunning(self.sessionID) {
                var off = block
                off.enabled = false
                self.engine.apply(block: off, in: self.sessionID)
            }
            self.refresh()
            self.table.selectAndScroll(row: min(row, self.table.numberOfRows - 1))
        }
    }

    @objc func runOrStop(_ sender: Any?) {
        guard let session else { return }
        AppDelegate.shared.toggleSession(session, from: window)
        refresh()
        table.announce(engine.isRunning(sessionID) ? "Running" : "Stopped")
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(editBlock(_:)), #selector(toggleBlock(_:)), #selector(renameItem(_:)), #selector(deleteItem(_:)),
             #selector(volumeUp(_:)), #selector(volumeDown(_:)):
            return selectedBlock != nil
        case #selector(moveBlockUp(_:)):
            return table.selectedRow > 0
        case #selector(moveBlockDown(_:)):
            return table.selectedRow >= 0 && table.selectedRow < table.numberOfRows - 1
        case #selector(runOrStop(_:)):
            item.title = engine.isRunning(sessionID) ? "Stop" : "Run"
            return true
        default:
            return true
        }
    }

    private func contextMenu(row: Int) -> NSMenu? {
        guard let session, row >= 0, row < session.blocks.count else { return nil }
        let block = session.blocks[row]
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(editBlock(_:)), keyEquivalent: "")
        menu.addItem(withTitle: block.enabled ? "Turn Off" : "Turn On", action: #selector(toggleBlock(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Name…", action: #selector(renameItem(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move Up", action: #selector(moveBlockUp(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Move Down", action: #selector(moveBlockDown(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Remove", action: #selector(deleteItem(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { session?.blocks.count ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let session else { return nil }
        let block = session.blocks[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let text = id == "detail" ? BlockSummary.describe(block) : block.displayName
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if id == "name" {
            var parts = [block.displayName, block.enabled ? "on" : "off"]
            if block.volumePercent != 100 { parts.append("volume \(block.volumePercent) percent") }
            field.setAccessibilityLabel(parts.joined(separator: ", "))
            if !block.enabled { field.textColor = .secondaryLabelColor }
        }
        return cell
    }
}

enum BlockSummary {
    static func describe(_ block: Block) -> String {
        switch block.kind {
        case .netSend:
            let s = block.netSend
            let codec = s.proto == .vban ? "16 bit PCM" : s.codec.shortName
            let where_: String
            switch s.mode {
            case .waitForReceivers: where_ = "for whoever asks on port \(s.effectivePort)"
            case .group(let g): where_ = "to the group \(g.ipv4String) port \(s.effectivePort)"
            case .oneHost(let h): where_ = "to \(h) port \(s.effectivePort)"
            }
            return "\"\(s.streamName)\" \(codec) over \(s.proto.displayName) \(where_); input: \(s.inputs.summary)"
        case .netReceive:
            let s = block.netReceive
            let from = s.asksAHost ? "asks \(s.host)" : (s.proto == .vban ? "on port \(s.effectivePort)" : "group \(s.effectiveGroup.ipv4String) port \(s.effectivePort)")
            let name = s.streamName.isEmpty ? "any stream" : "\"\(s.streamName)\""
            let out = s.outputDeviceUID.flatMap { AudioDevices.device(uid: $0)?.name } ?? "default output"
            return "\(name) over \(s.proto.displayName), \(from), \(s.bufferMs) ms buffer, to \(out)"
        }
    }
}

/// The blocks library: a list of the block kinds, Return adds the chosen one.
@MainActor
enum BlockLibrarySheet {
    static func present(in window: NSWindow, completion: @escaping (BlockKind?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Blocks library"
        alert.informativeText = "Choose a block to add to the session."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
        for kind in BlockKind.allCases {
            popup.addItem(withTitle: "\(kind.displayName): \(kind.summary)")
        }
        popup.setAccessibilityLabel("Block")
        alert.accessoryView = popup
        alert.window.initialFirstResponder = popup
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { completion(nil); return }
            completion(BlockKind.allCases[popup.indexOfSelectedItem])
        }
    }
}

//
//  SessionsWindowController.swift
//  FastRoute Companion
//
//  The sessions list: Command N makes one, Return opens it, Command R runs
//  it, and the field at the bottom says what is running.
//

import AppKit

@MainActor
final class SessionsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, ItemActions {
    private let store: SessionStore
    private let engine: SessionEngine
    private let table = NavigableTableView()
    private let status = StatusView()

    init(store: SessionStore, engine: SessionEngine) {
        self.store = store
        self.engine = engine
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "FastRoute Companion"
        window.setFrameAutosaveName("SessionsWindow")
        window.center()
        super.init(window: window)
        buildContent()
        status.provider = { [weak self] in
            guard let self else { return "" }
            return self.engine.overallStatusText(sessions: self.store.sessions)
        }
        status.startUpdating()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildContent() {
        guard let window else { return }
        let content = NSView()
        window.contentView = content

        let heading = NSTextField(labelWithString: "Sessions:")
        heading.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.title = "Session"
        column.width = 400
        table.addTableColumn(column)
        let stateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        stateColumn.title = "State"
        stateColumn.width = 160
        table.addTableColumn(stateColumn)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Sessions")
        table.onReturn = { [weak self] in self?.openSelectedSession(nil) }
        table.onDelete = { [weak self] in self?.deleteItem(nil) }
        table.onSpace = { [weak self] in self?.runOrStop(nil) }
        table.doubleAction = #selector(openSelectedSession(_:))
        table.target = self
        table.menuProvider = { [weak self] row in self?.contextMenu(row: row) }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Command N makes a session, Return opens it, Command R runs or stops it, Delete removes it. Shift F10 opens the menu with Run on Startup.")
        hint.textColor = .secondaryLabelColor
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: "Status:")
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(heading)
        content.addSubview(scroll)
        content.addSubview(hint)
        content.addSubview(statusLabel)
        content.addSubview(status)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            hint.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -16),
            statusLabel.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.initialFirstResponder = table
        refresh()
    }

    func refresh() {
        let selected = table.selectedRow
        table.reloadData()
        if selected >= 0 && selected < table.numberOfRows { table.selectRowIndexes([selected], byExtendingSelection: false) }
        status.refresh()
    }

    private var selectedSession: Session? {
        let row = table.actionRow
        guard row >= 0, row < store.sessions.count else { return nil }
        return store.sessions[row]
    }

    // MARK: Actions

    @objc func newSession(_ sender: Any?) {
        TextPrompt.ask("Session title", detail: "Name the new session.", in: window) { [weak self] title in
            guard let self, let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            let session = self.store.add(Session(title: title.trimmingCharacters(in: .whitespaces)))
            self.refresh()
            if let row = self.store.index(of: session.id) { self.table.selectAndScroll(row: row) }
            AppDelegate.shared.openSession(session.id)
        }
    }

    @objc func openSelectedSession(_ sender: Any?) {
        guard let session = selectedSession else { return }
        AppDelegate.shared.openSession(session.id)
    }

    @objc func runOrStop(_ sender: Any?) {
        guard let session = selectedSession else { return }
        AppDelegate.shared.toggleSession(session, from: window)
        refresh()
        table.announce(engine.isRunning(session.id) ? "\(session.title) running" : "\(session.title) stopped")
    }

    @objc func toggleAutoRun(_ sender: Any?) {
        guard var session = selectedSession else { return }
        session.autoRun.toggle()
        store.update(session)
        refresh()
        table.announce(session.autoRun ? "\(session.title) will run when the app starts" : "\(session.title) will not run on its own")
    }

    @objc func renameItem(_ sender: Any?) {
        guard var session = selectedSession else { return }
        TextPrompt.ask("Rename session", initial: session.title, in: window) { [weak self] title in
            guard let self, let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            session.title = title.trimmingCharacters(in: .whitespaces)
            self.store.update(session)
            self.refresh()
        }
    }

    @objc func deleteItem(_ sender: Any?) {
        guard let session = selectedSession else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(session.title)?"
        alert.informativeText = "Its blocks go with it. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.engine.stop(session.id)
            AppDelegate.shared.closeSessionWindow(session.id)
            let row = self.table.selectedRow
            self.store.remove(id: session.id)
            self.refresh()
            self.table.selectAndScroll(row: min(row, self.table.numberOfRows - 1))
        }
    }

    @objc func showHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "FastRoute Companion"
        alert.informativeText = """
        Sessions hold blocks. A Net Send block captures a microphone, system audio or chosen applications and sends it to another computer over FastRoute or VBAN. A Net Receive block plays what another computer sends on an output device.

        Sessions list: Command N new session, Return open, Command R run or stop, F2 rename, Delete remove. The context menu sets a session to run when the app starts.

        Session window: Command Shift N adds a block, Return opens its settings, Space turns it on or off, Command Up and Down move it, Option Up and Down change its volume, F2 renames it, Delete removes it, Command R runs or stops the session.

        FastRoute senders announce themselves on the local network, so a Net Receive block lists them. For a machine further away, start the sender first and type its name or address into the Net Receive block; the receiving side asks, so nothing has to be opened there.
        """
        alert.beginSheetModal(for: window!)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(openSelectedSession(_:)), #selector(renameItem(_:)), #selector(deleteItem(_:)), #selector(runOrStop(_:)):
            return selectedSession != nil
        case #selector(toggleAutoRun(_:)):
            item.state = (selectedSession?.autoRun ?? false) ? .on : .off
            return selectedSession != nil
        default:
            return true
        }
    }

    private func contextMenu(row: Int) -> NSMenu? {
        guard row >= 0, row < store.sessions.count else { return nil }
        let session = store.sessions[row]
        let menu = NSMenu()
        menu.addItem(withTitle: engine.isRunning(session.id) ? "Stop" : "Run", action: #selector(runOrStop(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open", action: #selector(openSelectedSession(_:)), keyEquivalent: "")
        let auto = menu.addItem(withTitle: "Run on Startup", action: #selector(toggleAutoRun(_:)), keyEquivalent: "")
        auto.state = session.autoRun ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Rename…", action: #selector(renameItem(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Delete", action: #selector(deleteItem(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { store.sessions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let session = store.sessions[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        if id == "state" {
            var parts: [String] = []
            if engine.isRunning(session.id) { parts.append("running") }
            if session.autoRun { parts.append("runs on startup") }
            text = parts.joined(separator: ", ")
        } else {
            text = session.title
        }
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
        if id != "state" {
            let state = engine.isRunning(session.id) ? ", running" : ""
            field.setAccessibilityLabel("\(session.title)\(state)\(session.autoRun ? ", runs on startup" : "")")
        }
        return cell
    }
}

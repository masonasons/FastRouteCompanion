//
//  NetReceiveDialog.swift
//  FastRoute Companion
//
//  Settings for a Net Receive block: the senders heard on the network,
//  which one to follow or which machine to ask, the buffer, and, unlike
//  FastRoute's, the output device to play on.
//

import AppKit

@MainActor
final class NetReceiveDialog: BlockDialog, NSTableViewDataSource, NSTableViewDelegate {
    private var nameField: NSTextField!
    private var protocolPopup: NSPopUpButton!
    private var sendersTable = NavigableTableView()
    private var sendersLabel: NSTextField!
    private var streamField: NSTextField!
    private var hostField: NSTextField!
    private var portField: NSTextField!
    private var bufferSlider: DescribedSlider!
    private var outputPopup: NSPopUpButton!
    private var outputDevices: [AudioDevice] = []
    private var senders: [DiscoveredSender] = []
    private var vbanHosts: [DiscoveredVBANHost] = []
    private var sourceID: UInt32
    private var sourceGroup: UInt32
    private var observer: NSObjectProtocol?

    init(block: Block, onApply: @escaping (Block) -> Void) {
        sourceID = block.netReceive.sourceID
        sourceGroup = block.netReceive.group
        super.init(block: block, title: "Net Receive Block", onApply: onApply)
        observer = NotificationCenter.default.addObserver(forName: DiscoveryService.didUpdate, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadSenders() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func dialogWillClose() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    override func buildForm() {
        let s = block.netReceive
        nameField = FormBuilder.textField(block.customName ?? "")
        nameField.placeholderString = "Net Receive"
        form.addRow("Name:", nameField)

        protocolPopup = FormBuilder.popup(NetProtocol.allCases.map(\.displayName), selected: s.proto.rawValue)
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged(_:))
        form.addRow("Protocol:", protocolPopup)

        sendersLabel = NSTextField(labelWithString: "Senders heard, Return takes one:")
        form.addFullWidth(sendersLabel)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sender"))
        column.width = 560
        sendersTable.addTableColumn(column)
        sendersTable.headerView = nil
        sendersTable.dataSource = self
        sendersTable.delegate = self
        sendersTable.setAccessibilityLabel("Senders heard")
        sendersTable.onReturn = { [weak self] in self?.useSelectedSender(nil) }
        sendersTable.doubleAction = #selector(useSelectedSender(_:))
        sendersTable.target = self
        let scroll = NSScrollView()
        scroll.documentView = sendersTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 580).isActive = true
        form.addFullWidth(scroll)
        let use = NSButton(title: "Use Selected Sender", target: self, action: #selector(useSelectedSender(_:)))
        let refresh = NSButton(title: "Ask Again", target: self, action: #selector(refreshSenders(_:)))
        form.addFullWidth(FormBuilder.buttonRow([use, refresh]))
        form.addFullWidth(BlockDialog.note("Senders on this network announce themselves, so the list fills itself in; taking one fills in the fields below. For a machine elsewhere, type its name or address below instead."))

        streamField = FormBuilder.textField(s.streamName)
        streamField.placeholderString = "blank takes whatever arrives"
        form.addRow("Stream name:", streamField)

        hostField = FormBuilder.textField(s.host)
        hostField.placeholderString = "a name or IP address, or blank for a sender on the local network"
        form.addRow("Sender's address or name:", hostField)
        form.addFullWidth(BlockDialog.note("Type the name or IP address of the machine that is sending and this block asks it for the audio; nothing has to be opened on this side. Leave it blank for a sender on the local network."))

        portField = FormBuilder.numberField(Int(s.port))
        form.addRow("Port:", portField)

        bufferSlider = FormBuilder.slider(min: 10, max: 1000, value: Double(s.bufferMs)) { "\(Int($0)) ms" }
        form.addRow("Buffer, how much it holds back before playing:", bufferSlider.withReadout())
        bufferSlider.setAccessibilityLabel("Buffer")
        form.addFullWidth(BlockDialog.note("How unevenly the network may deliver before it is audible; more is more delay. 60 ms suits a cable, wifi usually wants more."))

        form.addHeading("Output")
        outputDevices = AudioDevices.outputDevices()
        var titles = ["Default output device"]
        titles.append(contentsOf: outputDevices.map(\.name))
        var index = 0
        if let uid = s.outputDeviceUID {
            if let i = outputDevices.firstIndex(where: { $0.uid == uid }) { index = i + 1 }
            else { titles.append("Not connected: \(uid)"); index = titles.count - 1 }
        }
        outputPopup = FormBuilder.popup(titles, selected: index)
        form.addRow("Play on:", outputPopup)

        reloadSenders()
        protocolChanged(nil)
    }

    private var isVBAN: Bool { protocolPopup.indexOfSelectedItem == NetProtocol.vban.rawValue }

    @objc private func protocolChanged(_ sender: Any?) {
        if let port = Int(portField.stringValue), port == FastRouteNet.defaultPort || port == VBAN.defaultPort {
            portField.stringValue = String(isVBAN ? VBAN.defaultPort : FastRouteNet.defaultPort)
        }
        sendersLabel.stringValue = isVBAN ? "VBAN hosts that answered, Return takes one:" : "Senders heard, Return takes one:"
        reloadSenders()
    }

    @objc private func refreshSenders(_ sender: Any?) {
        DiscoveryService.shared.refreshVBANHosts()
        reloadSenders()
        sendersTable.announce(isVBAN ? "\(vbanHosts.count) VBAN hosts" : "\(senders.count) senders")
    }

    private func reloadSenders() {
        let selected = sendersTable.selectedRow
        senders = DiscoveryService.shared.senders
        vbanHosts = DiscoveryService.shared.vbanHosts
        sendersTable.reloadData()
        if selected >= 0 && selected < sendersTable.numberOfRows { sendersTable.selectRowIndexes([selected], byExtendingSelection: false) }
    }

    @objc private func useSelectedSender(_ sender: Any?) {
        let row = sendersTable.selectedRow
        if isVBAN {
            guard row >= 0, row < vbanHosts.count else { return }
            let host = vbanHosts[row]
            hostField.stringValue = host.endpoint.address.ipv4String
            portField.stringValue = String(host.endpoint.port)
            sendersTable.announce("Taking \(host.summary)")
        } else {
            guard row >= 0, row < senders.count else { return }
            let s = senders[row]
            streamField.stringValue = s.beacon.streamName
            portField.stringValue = String(s.beacon.port)
            sourceID = s.beacon.streamID
            if s.beacon.group != 0 {
                hostField.stringValue = ""
                sourceGroup = s.beacon.group
            } else {
                sourceGroup = 0
                hostField.stringValue = s.source.address.ipv4String
            }
            sendersTable.announce("Taking \(s.beacon.streamName) on \(s.beacon.hostName)")
        }
        window?.makeFirstResponder(streamField)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        let n = isVBAN ? vbanHosts.count : senders.count
        return max(n, 1)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if isVBAN {
            text = vbanHosts.isEmpty ? "nobody has answered yet" : vbanHosts[row].summary
        } else {
            text = senders.isEmpty ? (DiscoveryService.shared.startError ?? "nothing has announced itself yet") : senders[row].summary
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
        return cell
    }

    // MARK: Collect

    override func collect() -> Block? {
        var b = block
        var s = b.netReceive
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        b.customName = name.isEmpty ? nil : name
        s.proto = NetProtocol(rawValue: protocolPopup.indexOfSelectedItem) ?? .fastRoute
        s.streamName = streamField.stringValue.trimmingCharacters(in: .whitespaces)
        s.host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        // The group comes from the sender taken from the list; a sender named
        // by hand is asked directly, so the group does not apply.
        s.group = s.asksAHost ? 0 : sourceGroup
        guard let port = intValue(portField, "Port", 1...65535) else { return nil }
        s.port = UInt16(port)
        s.bufferMs = Int(bufferSlider.doubleValue)
        s.sourceID = streamField.stringValue.isEmpty ? 0 : sourceID
        let index = outputPopup.indexOfSelectedItem
        if index == 0 { s.outputDeviceUID = nil }
        else if outputDevices.indices.contains(index - 1) { s.outputDeviceUID = outputDevices[index - 1].uid }
        b.netReceive = s
        return b
    }
}

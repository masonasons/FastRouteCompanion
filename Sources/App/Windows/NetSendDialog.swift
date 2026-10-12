//
//  NetSendDialog.swift
//  FastRoute Companion
//
//  Settings for a Net Send block: where and how it sends, and, unlike
//  FastRoute's, which inputs it captures: an input device, system audio and
//  any number of applications.
//

import AppKit

@MainActor
final class NetSendDialog: BlockDialog, NSTableViewDataSource, NSTableViewDelegate {
    private var nameField: NSTextField!
    private var protocolPopup: NSPopUpButton!
    private var streamField: NSTextField!
    private var addressField: NSTextField!
    private var portField: NSTextField!
    private var codecPopup: NSPopUpButton!
    private var packetField: NSTextField!
    private var hopsField: NSTextField!
    private var opusButton: NSButton!
    private var opusSettings: OpusSettings
    private var micPopup: NSPopUpButton!
    private var systemAudioBox: NSButton!
    private var appsTable = NavigableTableView()
    private var inputDevices: [AudioDevice] = []
    private var apps: [CapturableApplication] = []
    private var selectedBundleIDs: Set<String>

    init(block: Block, onApply: @escaping (Block) -> Void) {
        opusSettings = block.netSend.opus
        selectedBundleIDs = Set(block.netSend.inputs.applicationBundleIDs)
        super.init(block: block, title: "Net Send Block", onApply: onApply)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        let s = block.netSend
        nameField = FormBuilder.textField(block.customName ?? "")
        form.addRow("Name:", nameField)
        nameField.placeholderString = "Net Send"

        protocolPopup = FormBuilder.popup(NetProtocol.allCases.map(\.displayName), selected: s.proto.rawValue)
        protocolPopup.target = self
        protocolPopup.action = #selector(protocolChanged(_:))
        form.addRow("Protocol:", protocolPopup)

        streamField = FormBuilder.textField(s.streamName)
        form.addRow("Stream name:", streamField)
        form.addFullWidth(BlockDialog.note("A receiver finds this stream by its name. Over VBAN the name is what tells streams on one port apart."))

        addressField = FormBuilder.textField(s.address)
        addressField.placeholderString = "blank waits for receivers to ask; or a name, IP address or group"
        form.addRow("Send to:", addressField)
        form.addFullWidth(BlockDialog.note("Blank waits for receivers to ask, which is the usual way: start this, then name this Mac in the Net Receive block on the other machine. A machine's name or IP address pushes the audio straight at it. A group address such as 239.255.77.21 reaches everyone on the local network who joins it. Nothing is encrypted."))

        portField = FormBuilder.numberField(Int(s.port))
        form.addRow("Port:", portField)

        codecPopup = FormBuilder.popup(NetCodec.allCases.map(\.displayName), selected: Int(s.codec.rawValue))
        codecPopup.target = self
        codecPopup.action = #selector(codecChanged(_:))
        form.addRow("Codec:", codecPopup)

        packetField = FormBuilder.numberField(s.packetMs)
        form.addRow("Packet length, ms:", packetField)
        form.addFullWidth(BlockDialog.note("Long packets of uncompressed audio are cut down to what fits one datagram. Opus uses 2.5, 5, 10, 20, 40 or 60 ms, whichever is nearest."))

        hopsField = FormBuilder.numberField(s.ttl)
        form.addRow("Hops a group packet may cross:", hopsField)

        opusButton = NSButton(title: "Opus Settings…", target: self, action: #selector(showOpusSettings(_:)))
        form.addRow("", opusButton)

        form.addHeading("Input")
        inputDevices = AudioDevices.inputDevices()
        var micTitles = ["None", "Default input device"]
        micTitles.append(contentsOf: inputDevices.map(\.name))
        var micIndex = 0
        if let uid = s.inputs.microphoneUID {
            if uid == InputSelection.defaultDeviceUID { micIndex = 1 }
            else if let i = inputDevices.firstIndex(where: { $0.uid == uid }) { micIndex = i + 2 }
            else { micTitles.append("Not connected: \(uid)"); micIndex = micTitles.count - 1 }
        }
        micPopup = FormBuilder.popup(micTitles, selected: micIndex)
        form.addRow("Input device:", micPopup)

        systemAudioBox = FormBuilder.checkbox("System audio, everything this Mac plays except FastRoute Companion itself", on: s.inputs.systemAudio)
        systemAudioBox.target = self
        systemAudioBox.action = #selector(systemAudioChanged(_:))
        form.addFullWidth(systemAudioBox)

        let appsLabel = NSTextField(labelWithString: "Applications to capture, Space checks or unchecks one:")
        form.addFullWidth(appsLabel)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.width = 560
        appsTable.addTableColumn(column)
        appsTable.headerView = nil
        appsTable.dataSource = self
        appsTable.delegate = self
        appsTable.setAccessibilityLabel("Applications to capture")
        appsTable.onSpace = { [weak self] in self?.toggleSelectedApp() }
        appsTable.onReturn = { [weak self] in self?.toggleSelectedApp() }
        appsTable.doubleAction = #selector(appDoubleClicked(_:))
        appsTable.target = self
        let scroll = NSScrollView()
        scroll.documentView = appsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 160).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 580).isActive = true
        form.addFullWidth(scroll)
        let refresh = NSButton(title: "Refresh Applications", target: self, action: #selector(refreshApps(_:)))
        form.addFullWidth(refresh)
        form.addFullWidth(BlockDialog.note("Applications that are playing right now are marked. System audio already includes every application, so the list is ignored while system audio is on."))

        reloadApps()
        protocolChanged(nil)
        systemAudioChanged(nil)
    }

    // MARK: Control changes

    @objc private func protocolChanged(_ sender: Any?) {
        let vban = protocolPopup.indexOfSelectedItem == NetProtocol.vban.rawValue
        codecPopup.isEnabled = !vban
        opusButton.isEnabled = !vban && codecPopup.indexOfSelectedItem == Int(NetCodec.opus.rawValue)
        if let port = Int(portField.stringValue), port == FastRouteNet.defaultPort || port == VBAN.defaultPort {
            portField.stringValue = String(vban ? VBAN.defaultPort : FastRouteNet.defaultPort)
        }
        if vban { addressField.placeholderString = "the machine's name or IP address, or a group" }
        else { addressField.placeholderString = "blank waits for receivers to ask; or a name, IP address or group" }
    }

    @objc private func codecChanged(_ sender: Any?) {
        opusButton.isEnabled = codecPopup.isEnabled && codecPopup.indexOfSelectedItem == Int(NetCodec.opus.rawValue)
    }

    @objc private func systemAudioChanged(_ sender: Any?) {
        appsTable.isEnabled = systemAudioBox.state == .off
    }

    @objc private func showOpusSettings(_ sender: Any?) {
        guard let window else { return }
        OpusSettingsSheet.present(in: window, settings: opusSettings) { [weak self] updated in
            if let updated { self?.opusSettings = updated }
        }
    }

    @objc private func refreshApps(_ sender: Any?) {
        reloadApps()
        appsTable.announce("\(apps.count) applications listed")
    }

    @objc private func appDoubleClicked(_ sender: Any?) { toggleSelectedApp() }

    private func reloadApps() {
        var list = CapturableApplication.running()
        let running = Set(list.map(\.bundleID))
        for id in selectedBundleIDs where !running.contains(id) {
            list.append(CapturableApplication(bundleID: id, name: "\(id) (not running)", pid: 0, isPlayingAudio: false))
        }
        apps = list
        appsTable.reloadData()
    }

    private func toggleSelectedApp() {
        let row = appsTable.selectedRow
        guard row >= 0, row < apps.count else { return }
        let app = apps[row]
        if selectedBundleIDs.contains(app.bundleID) { selectedBundleIDs.remove(app.bundleID) } else { selectedBundleIDs.insert(app.bundleID) }
        appsTable.reloadData(forRowIndexes: [row], columnIndexes: [0])
        appsTable.announce(selectedBundleIDs.contains(app.bundleID) ? "\(app.name) checked" : "\(app.name) unchecked")
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < apps.count else { return }
        let app = apps[row]
        if sender.state == .on { selectedBundleIDs.insert(app.bundleID) } else { selectedBundleIDs.remove(app.bundleID) }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = apps[row]
        let title = app.isPlayingAudio ? "\(app.name) (playing)" : app.name
        let box = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxToggled(_:)))
        box.state = selectedBundleIDs.contains(app.bundleID) ? .on : .off
        box.tag = row
        box.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Collect

    override func collect() -> Block? {
        var b = block
        var s = b.netSend
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        b.customName = name.isEmpty ? nil : name
        s.proto = NetProtocol(rawValue: protocolPopup.indexOfSelectedItem) ?? .fastRoute
        s.streamName = streamField.stringValue.trimmingCharacters(in: .whitespaces)
        if s.streamName.isEmpty {
            complain("This Net Send block has no stream name. A receiver finds it by that name, so it needs one.")
            window?.makeFirstResponder(streamField)
            return nil
        }
        s.address = addressField.stringValue.trimmingCharacters(in: .whitespaces)
        if s.proto == .vban && s.address.isEmpty {
            complain("VBAN needs an address to send to.", detail: "Type the host name or address of the machine running VoiceMeeter or the VBAN app, or a multicast group.")
            window?.makeFirstResponder(addressField)
            return nil
        }
        if let literal = UInt32(ipv4String: s.address), literal.isMulticastIPv4 == false, (literal >> 24) >= 224 {
            complain("\(s.address) is not a multicast address.", detail: "A group address has to be between 224.0.0.0 and 239.255.255.255.")
            return nil
        }
        guard let port = intValue(portField, "Port", 1...65535) else { return nil }
        s.port = UInt16(port)
        s.codec = NetCodec(rawValue: UInt8(codecPopup.indexOfSelectedItem)) ?? .pcm16
        guard let packet = doubleValue(packetField, "Packet length", 1...60) else { return nil }
        s.packetMs = packet
        guard let hops = intValue(hopsField, "Hops", 1...255) else { return nil }
        s.ttl = hops
        s.opus = opusSettings
        var inputs = InputSelection()
        switch micPopup.indexOfSelectedItem {
        case 0: inputs.microphoneUID = nil
        case 1: inputs.microphoneUID = InputSelection.defaultDeviceUID
        default:
            let i = micPopup.indexOfSelectedItem - 2
            inputs.microphoneUID = inputDevices.indices.contains(i) ? inputDevices[i].uid : b.netSend.inputs.microphoneUID
        }
        inputs.systemAudio = systemAudioBox.state == .on
        inputs.applicationBundleIDs = apps.map(\.bundleID).filter { selectedBundleIDs.contains($0) }
        if inputs.isEmpty {
            complain("Choose something to send.", detail: "Pick an input device, turn on system audio, or check at least one application.")
            return nil
        }
        s.inputs = inputs
        b.netSend = s
        return b
    }
}

/// The Opus dialog: loss protection, complexity, speech or music, how the
/// bitrate may vary, and whether to send almost nothing during silence.
@MainActor
enum OpusSettingsSheet {
    static func present(in parent: NSWindow, settings: OpusSettings, completion: @escaping (OpusSettings?) -> Void) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Opus Settings"
        let form = FormBuilder()

        let bitrate = FormBuilder.slider(min: 6, max: 510, value: Double(settings.bitrateKbps)) { "\(Int($0)) kbps" }
        form.addRow("Bitrate:", bitrate.withReadout())
        bitrate.setAccessibilityLabel("Bitrate")
        form.addFullWidth(BlockDialog.note("At 48 kHz stereo, 96 to 128 kbps is transparent for most music; speech is fine well below that."))

        let complexity = FormBuilder.slider(min: 0, max: 10, value: Double(settings.complexity)) { String(Int($0)) }
        form.addRow("Complexity, quality against processor time:", complexity.withReadout())
        complexity.setAccessibilityLabel("Complexity")
        form.addFullWidth(BlockDialog.note("Complexity costs processor time on the sending machine only; 10 is Opus's own default and is not expensive next to the rest of a session."))

        let loss = FormBuilder.slider(min: 0, max: 100, value: Double(settings.lossPercent)) { "\(Int($0)) percent" }
        form.addRow("Packet loss to protect against:", loss.withReadout())
        loss.setAccessibilityLabel("Packet loss to protect against")
        form.addFullWidth(BlockDialog.note("Above zero, Opus puts a low rate copy of each packet inside the next one, and the receiver rebuilds a lost packet from its successor instead of guessing at it. Part of the bitrate goes on that. With no protection, a lost packet is guessed at from the ones before it."))

        let signal = FormBuilder.popup(OpusSettings.Signal.allCases.map(\.displayName), selected: settings.signal.rawValue)
        form.addRow("Carrying:", signal)

        let rateMode = FormBuilder.popup(OpusSettings.RateMode.allCases.map(\.displayName), selected: settings.rateMode.rawValue)
        form.addRow("Bitrate is:", rateMode)

        let dtx = FormBuilder.checkbox("Send almost nothing while the input is silent", on: settings.dtx)
        form.addFullWidth(dtx)
        form.addFullWidth(BlockDialog.note("Saves a great deal on a mostly quiet microphone, but the silence then stops arriving rather than arriving as silence, which anything measuring the far end will notice."))

        let ok = NSButton(title: "OK", target: nil, action: nil)
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: nil, action: nil)
        cancel.keyEquivalent = "\u{1b}"
        let buttons = FormBuilder.buttonRow([cancel, ok])
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(form.grid)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            form.grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            form.grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            form.grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: form.grid.bottomAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        window.contentView = content
        let size = content.fittingSize
        window.setContentSize(NSSize(width: max(560, size.width), height: size.height))
        window.initialFirstResponder = bitrate

        let target = SheetButtons { response in
            parent.endSheet(window, returnCode: response)
        }
        ok.target = target; ok.action = #selector(SheetButtons.ok(_:))
        cancel.target = target; cancel.action = #selector(SheetButtons.cancel(_:))
        parent.beginSheet(window) { response in
            withExtendedLifetime(target) {}
            guard response == .OK else { completion(nil); return }
            var s = settings
            s.bitrateKbps = Int(bitrate.doubleValue)
            s.complexity = Int(complexity.doubleValue)
            s.lossPercent = Int(loss.doubleValue)
            s.signal = OpusSettings.Signal(rawValue: signal.indexOfSelectedItem) ?? .auto
            s.rateMode = OpusSettings.RateMode(rawValue: rateMode.indexOfSelectedItem) ?? .variable
            s.dtx = dtx.state == .on
            completion(s)
        }
    }
}

/// Target for a sheet's OK and Cancel buttons.
final class SheetButtons: NSObject {
    private let handler: (NSApplication.ModalResponse) -> Void
    init(handler: @escaping (NSApplication.ModalResponse) -> Void) { self.handler = handler }
    @objc func ok(_ sender: Any?) { handler(.OK) }
    @objc func cancel(_ sender: Any?) { handler(.cancel) }
}

//
//  AppDelegate.swift
//  FastRoute Companion
//
//  Owns the session store and the engine, builds the menu, shows the sessions
//  list, and keeps one window per open session.
//

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore()
    let engine = SessionEngine()
    private var sessionsWindow: SessionsWindowController?
    private var sessionWindows: [UUID: SessionWindowController] = [:]

    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        DiscoveryService.shared.start()

        let controller = SessionsWindowController(store: store, engine: engine)
        sessionsWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        engine.onChange = { [weak self] in self?.refreshAllWindows() }
        store.onChange = { [weak self] in self?.refreshAllWindows() }

        for session in store.sessions where session.autoRun {
            startSession(session, from: controller.window)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stopAll()
        store.saveNow()
        DiscoveryService.shared.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSessionsWindow(nil)
        return true
    }

    // MARK: Windows

    @objc func showSessionsWindow(_ sender: Any?) {
        sessionsWindow?.showWindow(nil)
        sessionsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func openSession(_ id: UUID) {
        if let existing = sessionWindows[id] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard store.session(id: id) != nil else { return }
        let controller = SessionWindowController(sessionID: id, store: store, engine: engine)
        controller.onClose = { [weak self] in self?.sessionWindows.removeValue(forKey: id) }
        sessionWindows[id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func closeSessionWindow(_ id: UUID) {
        sessionWindows[id]?.close()
        sessionWindows.removeValue(forKey: id)
    }

    func refreshAllWindows() {
        sessionsWindow?.refresh()
        for w in sessionWindows.values { w.refresh() }
    }

    // MARK: Running

    /// Starts a session, asking for microphone access first when a block
    /// captures an input device, and reports what could not start.
    func startSession(_ session: Session, from window: NSWindow?) {
        let needsMic = session.blocks.contains { $0.enabled && $0.kind == .netSend && $0.netSend.inputs.microphoneUID != nil }
        let proceed = { [weak self] in
            guard let self else { return }
            do {
                try self.engine.run(session)
                let problems = self.engine.problems(for: session.id)
                if !problems.isEmpty {
                    ErrorAlert.show("Some blocks in \(session.title) could not start", detail: problems.joined(separator: "\n"), in: window)
                }
            } catch {
                ErrorAlert.show("\(session.title) could not start", detail: error.localizedDescription, in: window)
            }
        }
        if needsMic {
            SessionEngine.ensureMicrophoneAccess { granted in
                if granted { proceed() }
                else {
                    ErrorAlert.show("Microphone access is off", detail: "Allow FastRoute Companion to use the microphone in System Settings, Privacy & Security, Microphone, then run the session again.", in: window)
                }
            }
        } else {
            proceed()
        }
    }

    func toggleSession(_ session: Session, from window: NSWindow?) {
        if engine.isRunning(session.id) { engine.stop(session.id) } else { startSession(session, from: window) }
    }
}

enum ErrorAlert {
    @MainActor
    static func show(_ message: String, detail: String, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

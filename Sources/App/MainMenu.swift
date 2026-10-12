//
//  MainMenu.swift
//  FastRoute Companion
//
//  The menu bar, built in code. Actions go through the responder chain to
//  whichever window is in front.
//

import AppKit

enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu(title: "FastRoute Companion")
        appMenu.addItem(withTitle: "About FastRoute Companion", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FastRoute Companion", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FastRoute Companion", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Session…", action: #selector(SessionsWindowController.newSession(_:)), keyEquivalent: "n")
        let addBlock = file.addItem(withTitle: "Add Block…", action: #selector(SessionWindowController.addBlock(_:)), keyEquivalent: "n")
        addBlock.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Open Session", action: #selector(SessionsWindowController.openSelectedSession(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Rename…", action: #selector(ItemActions.renameItem(_:)), keyEquivalent: fKey(NSF2FunctionKey), mask: [])
        file.addItem(withTitle: "Delete", action: #selector(ItemActions.deleteItem(_:)), keyEquivalent: "\u{8}")
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit)

        let session = NSMenu(title: "Session")
        session.addItem(withTitle: "Run or Stop", action: #selector(ItemActions.runOrStop(_:)), keyEquivalent: "r")
        session.addItem(withTitle: "Auto Run on Startup", action: #selector(SessionsWindowController.toggleAutoRun(_:)), keyEquivalent: "")
        session.addItem(.separator())
        session.addItem(withTitle: "Edit Block…", action: #selector(SessionWindowController.editBlock(_:)), keyEquivalent: "\r")
        session.addItem(withTitle: "Turn Block On or Off", action: #selector(SessionWindowController.toggleBlock(_:)), keyEquivalent: "")
        session.addItem(withTitle: "Move Block Up", action: #selector(SessionWindowController.moveBlockUp(_:)), keyEquivalent: fKey(NSUpArrowFunctionKey), mask: [.command])
        session.addItem(withTitle: "Move Block Down", action: #selector(SessionWindowController.moveBlockDown(_:)), keyEquivalent: fKey(NSDownArrowFunctionKey), mask: [.command])
        session.addItem(withTitle: "Block Volume Up", action: #selector(SessionWindowController.volumeUp(_:)), keyEquivalent: fKey(NSUpArrowFunctionKey), mask: [.option])
        session.addItem(withTitle: "Block Volume Down", action: #selector(SessionWindowController.volumeDown(_:)), keyEquivalent: fKey(NSDownArrowFunctionKey), mask: [.option])
        main.addItem(submenu: session)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Sessions", action: #selector(AppDelegate.showSessionsWindow(_:)), keyEquivalent: "0")
        window.addItem(.separator())
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(submenu: window)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "FastRoute Companion Help", action: #selector(SessionsWindowController.showHelp(_:)), keyEquivalent: "?")
        main.addItem(submenu: help)
        NSApp.helpMenu = help

        return main
    }

    private static func fKey(_ code: Int) -> String {
        String(Character(UnicodeScalar(code)!))
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }

    @discardableResult
    func addItem(withTitle title: String, action: Selector?, keyEquivalent: String, mask: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = addItem(withTitle: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = mask
        return item
    }
}

/// Actions both windows answer, so the menu has one item for each.
@objc protocol ItemActions {
    func renameItem(_ sender: Any?)
    func deleteItem(_ sender: Any?)
    func runOrStop(_ sender: Any?)
}

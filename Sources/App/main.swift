//
//  main.swift
//  FastRoute Companion
//
//  Programmatic entry point, no storyboard: the whole interface is built in
//  code, which keeps an accessibility-first AppKit app easy to reason about.
//

import AppKit

let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}

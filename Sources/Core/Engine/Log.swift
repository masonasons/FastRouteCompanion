//
//  Log.swift
//  FastRoute Companion
//
//  Unified logging, readable with:
//    log stream --predicate 'subsystem == "me.masonasons.FastRouteCompanion"'
//

import Foundation
import os

enum Log {
    static let net = Logger(subsystem: "me.masonasons.FastRouteCompanion", category: "net")
    static let audio = Logger(subsystem: "me.masonasons.FastRouteCompanion", category: "audio")
}

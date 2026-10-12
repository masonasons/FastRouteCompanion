//
//  SessionEngine.swift
//  FastRoute Companion
//
//  Starts and stops sessions, keeps the running blocks, and answers the
//  status field. One per app.
//

import Foundation
import AVFoundation

@MainActor
final class SessionEngine {
    private struct Run {
        var blocks: [UUID: RunningBlock]
        var startedAt: Date
        var problems: [String]
    }

    private var runs: [UUID: Run] = [:]
    var onChange: (() -> Void)?

    func isRunning(_ sessionID: UUID) -> Bool { runs[sessionID] != nil }

    var runningSessionIDs: [UUID] { Array(runs.keys) }

    /// Starts every enabled block. Blocks that fail are reported and the
    /// rest keep running; a session with nothing runnable does not start.
    func run(_ session: Session) throws {
        guard runs[session.id] == nil else { return }
        let enabled = session.blocks.filter(\.enabled)
        guard !enabled.isEmpty else { throw BlockError.configuration("\(session.title) has no enabled blocks. Add one from the blocks library.") }
        var started: [UUID: RunningBlock] = [:]
        var problems: [String] = []
        for block in enabled {
            let runner = makeRunner(block)
            do {
                try runner.start()
                started[block.id] = runner
            } catch {
                problems.append("\(block.displayName): \(error.localizedDescription)")
            }
        }
        if started.isEmpty {
            throw BlockError.configuration(problems.joined(separator: "\n"))
        }
        runs[session.id] = Run(blocks: started, startedAt: Date(), problems: problems)
        onChange?()
    }

    func stop(_ sessionID: UUID) {
        guard let run = runs.removeValue(forKey: sessionID) else { return }
        for r in run.blocks.values { r.stop() }
        onChange?()
    }

    func stopAll() {
        for id in Array(runs.keys) { stop(id) }
    }

    /// Restarts one block with new settings while its session keeps running.
    func apply(block: Block, in sessionID: UUID) {
        guard var run = runs[sessionID] else { return }
        run.blocks[block.id]?.stop()
        run.blocks.removeValue(forKey: block.id)
        run.problems.removeAll { $0.hasPrefix(block.displayName + ":") }
        if block.enabled {
            let runner = makeRunner(block)
            do {
                try runner.start()
                run.blocks[block.id] = runner
            } catch {
                run.problems.append("\(block.displayName): \(error.localizedDescription)")
            }
        }
        runs[sessionID] = run
        onChange?()
    }

    func setGain(block: Block, in sessionID: UUID) {
        runs[sessionID]?.blocks[block.id]?.gain = Float(block.volumePercent) / 100
    }

    func problems(for sessionID: UUID) -> [String] { runs[sessionID]?.problems ?? [] }

    func blockStatus(_ blockID: UUID, in sessionID: UUID) -> String? {
        runs[sessionID]?.blocks[blockID]?.statusText
    }

    /// The status line for one session.
    func statusText(for session: Session) -> String {
        guard let run = runs[session.id] else { return "\(session.title) is not running." }
        let seconds = Int(Date().timeIntervalSince(run.startedAt))
        var lines = ["\(session.title) running for \(SessionEngine.duration(seconds))."]
        for block in session.blocks {
            if let r = run.blocks[block.id] { lines.append(r.statusText) }
        }
        lines.append(contentsOf: run.problems)
        return lines.joined(separator: "\n")
    }

    /// The status line for the sessions list.
    func overallStatusText(sessions: [Session]) -> String {
        let running = sessions.filter { runs[$0.id] != nil }
        if running.isEmpty { return "Nothing is running." }
        return running.map { statusText(for: $0) }.joined(separator: "\n")
    }

    private func makeRunner(_ block: Block) -> RunningBlock {
        switch block.kind {
        case .netSend: return NetSendRunner(block: block)
        case .netReceive: return NetReceiveRunner(block: block)
        }
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    /// Asks for microphone access when a session needs it, before starting.
    static func ensureMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { completion(granted) } }
        default: completion(false)
        }
    }
}

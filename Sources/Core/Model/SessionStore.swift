//
//  SessionStore.swift
//  FastRoute Companion
//
//  Keeps the sessions in a JSON file under Application Support and saves
//  shortly after every change.
//

import Foundation

@MainActor
final class SessionStore {
    private(set) var sessions: [Session] = []
    var onChange: (() -> Void)?

    private let fileURL: URL
    private var saveTimer: Timer?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("FastRoute Companion", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("sessions.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { sessions = []; return }
        do {
            sessions = try JSONDecoder().decode([Session].self, from: data)
        } catch {
            NSLog("Sessions could not be read: \(error)")
            sessions = []
        }
    }

    func saveNow() {
        saveTimer?.invalidate()
        saveTimer = nil
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("Sessions could not be saved: \(error)")
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.saveNow() }
        }
        onChange?()
    }

    func session(id: UUID) -> Session? { sessions.first { $0.id == id } }

    func index(of id: UUID) -> Int? { sessions.firstIndex { $0.id == id } }

    @discardableResult
    func add(_ session: Session) -> Session {
        sessions.append(session)
        scheduleSave()
        return session
    }

    func update(_ session: Session) {
        guard let i = index(of: session.id) else { return }
        sessions[i] = session
        scheduleSave()
    }

    func remove(id: UUID) {
        sessions.removeAll { $0.id == id }
        scheduleSave()
    }

    func move(from: Int, to: Int) {
        guard sessions.indices.contains(from), sessions.indices.contains(to) else { return }
        let s = sessions.remove(at: from)
        sessions.insert(s, at: to)
        scheduleSave()
    }

    func updateBlock(sessionID: UUID, block: Block) {
        guard let si = index(of: sessionID), let bi = sessions[si].blocks.firstIndex(where: { $0.id == block.id }) else { return }
        sessions[si].blocks[bi] = block
        scheduleSave()
    }
}

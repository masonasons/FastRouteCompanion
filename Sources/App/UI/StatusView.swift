//
//  StatusView.swift
//  FastRoute Companion
//
//  The read-only field at the bottom of each window that says what is running
//  and for how long, refreshed once a second.
//

import AppKit

final class StatusView: NSScrollView {
    let textView = NSTextView()
    private var timer: Timer?
    var provider: (() -> String)?

    init() {
        super.init(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.setAccessibilityLabel("Status")
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        documentView = textView
        hasVerticalScroller = true
        borderType = .bezelBorder
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 96).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func startUpdating() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopUpdating() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard let provider else { return }
        let text = provider()
        if textView.string != text { textView.string = text }
    }
}

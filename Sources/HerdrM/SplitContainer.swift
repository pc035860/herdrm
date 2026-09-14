import AppKit
import SwiftUI

/// Tracks which side of the ⌘D split holds the keyboard by KVO-observing the key
/// window's `firstResponder`.
///
/// `NSWindow.firstResponder` is documented as KVO-observable. `NSApplication.keyWindow`
/// is NOT documented as such, but was verified empirically to fire — including on the
/// transitions through nil — so the observer reinstalls itself when the key window
/// changes. Treat that half as a measured, non-contractual dependency on AppKit.
///
/// This class holds no copy of the focused leaf on purpose: it reports every computed
/// value to `onLeafChanged` without deduplicating. A cached leaf here went stale when
/// the split closed and then silently stopped reporting, which drew the active pane
/// dimmed and inverted the resize direction.
///
/// AppKit changes `firstResponder` and `keyWindow` on the main thread, so the callback
/// is delivered there too.
final class SplitFocusTracker {
    /// Called with the leaf that now holds the keyboard. Fires on every observed
    /// change, even when the value repeats — see the note above.
    var onLeafChanged: ((AppModel.SplitLeafID) -> Void)?

    /// Maps a first responder to the leaf whose view contains it. Supplied by the
    /// view layer: attach-registry hit → `.agent`, else the nearest registered
    /// leaf view ancestor, else nil (responder outside any pane — keeps the last
    /// report, same as the old side tracker). A single stored agent view would
    /// go stale the moment the selection switched while the old view was still
    /// first responder — the exact staleness the class comment above warns against.
    var resolveLeaf: ((NSView) -> AppModel.SplitLeafID?)?

    private var keyWindowObservation: NSKeyValueObservation?
    private var firstResponderObservation: NSKeyValueObservation?
    private var reportedLeaf: AppModel.SplitLeafID?

    func start() {
        keyWindowObservation = NSApp.observe(\.keyWindow, options: [.new]) { [weak self] _, _ in
            self?.installFirstResponderObserver()
        }
        installFirstResponderObserver()
    }

    private func installFirstResponderObserver() {
        firstResponderObservation?.invalidate()
        firstResponderObservation = NSApp.keyWindow?.observe(
            \.firstResponder,
            options: [.new]
        ) { [weak self] _, _ in
            self?.updateFocusedLeaf()
        }
        updateFocusedLeaf()
    }

    private func updateFocusedLeaf() {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView,
              let leaf = resolveLeaf?(responder),
              leaf != reportedLeaf
        else { return }
        reportedLeaf = leaf
        onLeafChanged?(leaf)
    }

    deinit {
        keyWindowObservation?.invalidate()
        firstResponderObservation?.invalidate()
    }
}

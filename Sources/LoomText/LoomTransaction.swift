//
//  LoomTransaction.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's YYTextTransaction.
//

import Foundation

/// Coalesces repeated actions into a single execution at the end of the
/// current main run-loop tick (observer order 0xFFFFFF — after Core
/// Animation's transaction commit).
///
/// Actions are keyed by `(target identity, key)`: committing the same
/// pair N times in one tick runs the *last* action once. Use it to fold
/// bursts of property changes into one display/update pass.
@MainActor
public enum LoomTransaction {

    private struct Key: Hashable {
        let target: ObjectIdentifier
        let name: String
    }

    private static var pending: [Key: () -> Void] = [:]
    private static var observerInstalled = false

    /// Schedules `action` to run at the end of the current run-loop
    /// tick, replacing any action previously committed with the same
    /// `(target, key)` in this tick. `target` is used for identity only
    /// and is not retained beyond the tick.
    public static func commit(target: AnyObject, key: String = "", action: @escaping () -> Void) {
        installObserverIfNeeded()
        pending[Key(target: ObjectIdentifier(target), name: key)] = action
    }

    private static func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        let activities: CFOptionFlags =
            CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.exit.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, 0xFFFFFF
        ) { _, _ in
            // The observer is installed on the main run loop; its
            // callbacks are main-thread by construction.
            MainActor.assumeIsolated {
                flush()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    private static func flush() {
        // Single swap per run-loop callback (YYText parity): actions
        // committed while flushing land in the *next* tick, so an action
        // that re-commits itself cannot spin this loop forever.
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = [:]
        for action in batch.values { action() }
    }
}

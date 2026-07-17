//
//  LoomSentinel.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's _YYTextSentinel.
//

import Foundation

/// A thread-safe incrementing counter — the cancellation primitive for
/// async rendering. A render captures the value at submission; any later
/// `increase()` (new content, layer teardown) makes the captured value
/// stale and the render observes it via `isCancelled` polls.
///
/// NSLock keeps the library dependency-free (no swift-atomics); the
/// counter is touched a handful of times per display pass, so lock cost
/// is irrelevant. Wrapping addition avoids an overflow trap on
/// long-lived layers.
final class LoomSentinel: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int32 = 0

    var value: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func increase() -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        storage &+= 1
        return storage
    }
}

/// Moves a known-thread-confined value across a `@Sendable` boundary.
/// The wrapper is only as safe as the caller's discipline — document the
/// confinement at every use site.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

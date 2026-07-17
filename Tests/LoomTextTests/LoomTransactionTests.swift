//
//  LoomTransactionTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import Foundation
import XCTest
@testable import LoomText

@MainActor
final class LoomTransactionTests: XCTestCase {

    private func spinMainRunLoop(_ interval: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    func testSameTargetAndKeyCoalescesToOneExecution() {
        var count = 0
        for _ in 0..<5 {
            LoomTransaction.commit(target: self, key: "update") { count += 1 }
        }
        spinMainRunLoop()
        XCTAssertEqual(count, 1)
    }

    func testLastCommittedActionWins() {
        var value = -1
        for i in 0..<5 {
            LoomTransaction.commit(target: self, key: "value") { value = i }
        }
        spinMainRunLoop()
        XCTAssertEqual(value, 4)
    }

    func testDistinctKeysAllExecute() {
        var ran = Set<String>()
        LoomTransaction.commit(target: self, key: "a") { ran.insert("a") }
        LoomTransaction.commit(target: self, key: "b") { ran.insert("b") }
        spinMainRunLoop()
        XCTAssertEqual(ran, ["a", "b"])
    }

    func testDistinctTargetsAllExecute() {
        final class Token {}
        let t1 = Token(), t2 = Token()
        var count = 0
        LoomTransaction.commit(target: t1, key: "x") { count += 1 }
        LoomTransaction.commit(target: t2, key: "x") { count += 1 }
        spinMainRunLoop()
        XCTAssertEqual(count, 2)
    }

    func testActionCommittedDuringFlushRunsInALaterTick() {
        // YYText parity: nested commits defer to the next run-loop tick —
        // a self-recommitting action must not spin the flush forever.
        var chained = false
        LoomTransaction.commit(target: self, key: "outer") {
            LoomTransaction.commit(target: self, key: "inner") { chained = true }
        }
        spinMainRunLoop(0.05)
        spinMainRunLoop(0.05)
        XCTAssertTrue(chained)
    }
}

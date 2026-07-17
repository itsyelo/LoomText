//
//  LoomAttachmentProviderTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

#if canImport(UIKit)
import UIKit
import XCTest
@testable import LoomText

@MainActor
final class LoomAttachmentProviderTests: XCTestCase {

    private let size = CGSize(width: 200, height: 40)

    private func providerText(
        provider: @escaping @MainActor () -> UIView,
        onUnmounted: (@MainActor (UIView) -> Void)? = nil
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "sticker ", attributes: [
            .font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black,
        ])
        text.append(.loom_attachmentString(
            viewProvider: provider,
            onViewUnmounted: onUnmounted,
            contentSize: CGSize(width: 24, height: 24),
            alignTo: UIFont.systemFont(ofSize: 16)
        ))
        return text
    }

    private func makeLabel(_ text: NSAttributedString) -> LoomLabel {
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = false
        label.textLayout = LoomTextLayout(containerSize: size, text: text)
        return label
    }

    func testProviderCalledPerMountAndRecycledPerUnmount() {
        var provided: [UIView] = []
        var recycled: [UIView] = []
        let label = makeLabel(providerText(
            provider: {
                let view = UIView()
                provided.append(view)
                return view
            },
            onUnmounted: { recycled.append($0) }
        ))

        label.layer.displayIfNeeded()
        XCTAssertEqual(provided.count, 1)
        XCTAssertEqual(provided.last?.superview, label)
        XCTAssertTrue(recycled.isEmpty)

        // Redisplay: old view recycles, provider dequeues a fresh one —
        // pool semantics.
        label.layer.setNeedsDisplay()
        label.layer.displayIfNeeded()
        XCTAssertEqual(provided.count, 2)
        XCTAssertEqual(recycled.count, 1)
        XCTAssertTrue(recycled[0] === provided[0], "recycle must hand back the mounted instance")
        XCTAssertNil(recycled[0].superview)

        // Clearing the layout recycles the last mounted view too.
        label.textLayout = nil
        label.layer.displayIfNeeded()
        XCTAssertEqual(recycled.count, 2)
        XCTAssertTrue(recycled[1] === provided[1])
    }

    func testMemoizedProviderKeepsIdentity() {
        // Ownership flavor A: the closure memoizes, so every mount
        // returns the same instance (animation state persists).
        var instance: UIView?
        let label = makeLabel(providerText(provider: {
            if let instance { return instance }
            let view = UIView()
            instance = view
            return view
        }))
        label.layer.displayIfNeeded()
        let first = instance
        label.layer.setNeedsDisplay()
        label.layer.displayIfNeeded()
        XCTAssertTrue(instance === first)
        XCTAssertEqual(first?.superview, label)
    }

    func testDirectContentPathUnchanged() {
        // Regression: the Task 09 direct-content flavor keeps working.
        let badge = UIView()
        let text = NSMutableAttributedString(attributedString: .loom_attachmentString(
            content: badge,
            contentSize: CGSize(width: 24, height: 24),
            alignTo: UIFont.systemFont(ofSize: 16)
        ))
        let label = makeLabel(text)
        label.layer.displayIfNeeded()
        XCTAssertEqual(badge.superview, label)
        label.textLayout = nil
        label.layer.displayIfNeeded()
        XCTAssertNil(badge.superview)
    }

    func testProviderAttachmentSpeaksNothingWithoutLabel() {
        // Accessibility must tolerate content == nil.
        let label = makeLabel(providerText(provider: { UIView() }))
        XCTAssertEqual(label.accessibilityLabel, "sticker ")
    }
}
#endif

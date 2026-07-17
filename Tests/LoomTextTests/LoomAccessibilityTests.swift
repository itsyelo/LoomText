//
//  LoomAccessibilityTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

#if canImport(UIKit)
import UIKit
import XCTest
@testable import LoomText

@MainActor
final class LoomAccessibilityTests: XCTestCase {

    private let size = CGSize(width: 300, height: 200)

    private func plainAttr(_ string: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: [
            .font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black,
        ])
    }

    private func makeLabel(_ text: NSAttributedString, container: LoomTextContainer? = nil) -> LoomLabel {
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = false
        let container = container ?? LoomTextContainer(size: size)
        label.textLayout = LoomTextLayout(container: container, text: text)
        return label
    }

    // MARK: - Plain text

    func testPlainLabelIsSingleStaticTextElement() {
        let label = makeLabel(plainAttr("Hello VoiceOver"))
        XCTAssertTrue(label.isAccessibilityElement)
        XCTAssertEqual(label.accessibilityLabel, "Hello VoiceOver")
        XCTAssertTrue(label.accessibilityTraits.contains(.staticText))
        XCTAssertNil(label.accessibilityElements)
    }

    func testAttachmentSpeaksItsLabel() {
        let badge = UIView()
        badge.accessibilityLabel = "verified badge"
        let text = plainAttr("name ")
        text.append(.loom_attachmentString(
            content: badge, contentSize: CGSize(width: 16, height: 16),
            alignTo: UIFont.systemFont(ofSize: 16)
        ))
        text.append(plainAttr(" end"))
        let label = makeLabel(text)
        XCTAssertEqual(label.accessibilityLabel, "name verified badge end")
    }

    // MARK: - Highlights → container

    private func highlightedLabel() -> (LoomLabel, NSRange) {
        let text = plainAttr("before LINK after")
        let range = NSRange(location: 7, length: 4)
        text.loom_setHighlight(
            range, pressedAttributes: [.foregroundColor: UIColor.green], userInfo: ["url": "x"]
        )
        return (makeLabel(text), range)
    }

    func testHighlightedLabelBecomesContainer() throws {
        let (label, range) = highlightedLabel()
        XCTAssertFalse(label.isAccessibilityElement)
        let elements = try XCTUnwrap(label.accessibilityElements as? [UIAccessibilityElement])
        XCTAssertEqual(elements.count, 3)

        XCTAssertEqual(elements[0].accessibilityLabel, "before ")
        XCTAssertTrue(elements[0].accessibilityTraits.contains(.staticText))
        XCTAssertEqual(elements[1].accessibilityLabel, "LINK")
        XCTAssertTrue(elements[1].accessibilityTraits.contains(.link))
        XCTAssertEqual(elements[2].accessibilityLabel, " after")

        // Link frame matches the highlight geometry.
        let layout = try XCTUnwrap(label.textLayout)
        XCTAssertEqual(elements[1].accessibilityFrameInContainerSpace, layout.rect(for: range).standardized)
        // Reading order follows string order: frames advance left to right.
        XCTAssertLessThan(
            elements[0].accessibilityFrameInContainerSpace.minX,
            elements[1].accessibilityFrameInContainerSpace.minX
        )
    }

    func testLinkElementActivationFiresTapAction() throws {
        let (label, range) = highlightedLabel()
        var fired: NSRange?
        label.highlightTapAction = { _, _, tappedRange, _ in fired = tappedRange }
        let elements = try XCTUnwrap(label.accessibilityElements as? [LoomAccessibilityElement])
        XCTAssertTrue(elements[1].accessibilityActivate())
        XCTAssertEqual(fired, range)
    }

    func testElementsCacheInvalidatesOnLayoutChange() throws {
        let (label, _) = highlightedLabel()
        let first = try XCTUnwrap(label.accessibilityElements as? [UIAccessibilityElement])
        label.textLayout = LoomTextLayout(containerSize: size, text: plainAttr("plain now"))
        XCTAssertTrue(label.isAccessibilityElement, "plain text must collapse back to one element")
        XCTAssertNil(label.accessibilityElements)
        _ = first
    }

    // MARK: - Truncation token

    func testHighlightedTokenIsActivatableLinkElement() throws {
        let body = plainAttr("Long feed body that wraps and truncates across the container width for sure.")
        let token = plainAttr("\u{2026}more")
        token.loom_setHighlight(
            NSRange(location: 0, length: token.length),
            pressedAttributes: [.foregroundColor: UIColor.blue],
            userInfo: ["action": "expand"]
        )
        let container = LoomTextContainer(
            size: CGSize(width: 120, height: 10_000),
            maximumNumberOfRows: 2,
            truncationToken: token
        )
        let label = makeLabel(body, container: container)
        XCTAssertEqual(label.textLayout?.isTruncated, true)

        let elements = try XCTUnwrap(label.accessibilityElements as? [LoomAccessibilityElement])
        let tokenElement = try XCTUnwrap(elements.last)
        XCTAssertEqual(tokenElement.accessibilityLabel, "\u{2026}more")
        XCTAssertTrue(tokenElement.accessibilityTraits.contains(.link))

        var payload: (text: String, range: NSRange)?
        label.highlightTapAction = { _, text, range, _ in payload = (text.string, range) }
        XCTAssertTrue(tokenElement.accessibilityActivate())
        XCTAssertEqual(payload?.text, "\u{2026}more")
        XCTAssertEqual(payload?.range, NSRange(location: 0, length: 5))
    }
}
#endif

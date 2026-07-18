//
//  LoomInkOverflowTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  Task 20 — ink overflow: grown background capsules bleed past the
//  layout box without clipping, while frames and measurement stay
//  untouched.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

final class LoomInkOverflowTests: XCTestCase {

    private let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

    private func attr(_ string: String) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        return NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
    }

    private func layout(
        _ string: String = "TAG and the rest",
        backgroundRange: NSRange = NSRange(location: 0, length: 3),
        insets: LoomEdgeInsets
    ) -> LoomTextLayout {
        let text = NSMutableAttributedString(attributedString: attr(string))
        text.loom_setBackground(
            LoomTextBackground(fillColor: green, cornerRadius: 4, insets: insets),
            range: backgroundRange
        )
        return LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: text)!
    }

    // MARK: - inkOverflow computation

    func testNoBackgroundMeansZeroOverflow() {
        let l = LoomTextLayout(containerSize: CGSize(width: 100, height: 40), text: attr("plain"))!
        XCTAssertTrue(l.inkOverflow.loomIsZero)
    }

    func testPositiveInsetsMeanZeroOverflow() {
        let l = layout(insets: LoomEdgeInsets(top: 2, left: 2, bottom: 2, right: 2))
        XCTAssertTrue(l.inkOverflow.loomIsZero)
    }

    func testNegativeInsetsBecomePerEdgeOverflow() {
        let l = layout(insets: LoomEdgeInsets(top: -1, left: -4, bottom: -2, right: -3))
        XCTAssertEqual(l.inkOverflow.top, 1)
        XCTAssertEqual(l.inkOverflow.left, 4)
        XCTAssertEqual(l.inkOverflow.bottom, 2)
        XCTAssertEqual(l.inkOverflow.right, 3)
    }

    func testMixedInsetsClampToGrowthOnly() {
        let l = layout(insets: LoomEdgeInsets(top: 3, left: -4, bottom: 0, right: 5))
        XCTAssertEqual(l.inkOverflow.top, 0)
        XCTAssertEqual(l.inkOverflow.left, 4)
        XCTAssertEqual(l.inkOverflow.bottom, 0)
        XCTAssertEqual(l.inkOverflow.right, 0)
    }

    func testMultipleBackgroundsTakeTheMax() {
        let text = NSMutableAttributedString(attributedString: attr("one two three"))
        text.loom_setBackground(
            LoomTextBackground(fillColor: green, insets: LoomEdgeInsets(top: 0, left: -2, bottom: 0, right: 0)),
            range: NSRange(location: 0, length: 3)
        )
        text.loom_setBackground(
            LoomTextBackground(fillColor: green, insets: LoomEdgeInsets(top: -3, left: -1, bottom: 0, right: 0)),
            range: NSRange(location: 4, length: 3)
        )
        let l = LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: text)!
        XCTAssertEqual(l.inkOverflow.left, 2)
        XCTAssertEqual(l.inkOverflow.top, 3)
    }

    func testTokenBackgroundCountsTowardOverflow() {
        let token = NSMutableAttributedString(attributedString: attr("…more"))
        token.loom_setBackground(
            LoomTextBackground(fillColor: green, insets: LoomEdgeInsets(top: 0, left: 0, bottom: -2, right: -5)),
            range: NSRange(location: 0, length: token.length)
        )
        let container = LoomTextContainer(
            size: CGSize(width: 150, height: 10_000),
            maximumNumberOfRows: 1,
            truncationToken: token
        )
        let body = attr(String(repeating: "内容很长。", count: 20))
        let l = LoomTextLayout(container: container, text: body)!
        XCTAssertTrue(l.isTruncated)
        XCTAssertEqual(l.inkOverflow.right, 5)
        XCTAssertEqual(l.inkOverflow.bottom, 2)
    }

    /// Overflow must never leak into measurement — that would break
    /// "measure once, render the same data".
    func testOverflowDoesNotAffectBoundingSize() {
        let grown = layout(insets: LoomEdgeInsets(top: -4, left: -4, bottom: -4, right: -4))
        let plain = layout(insets: .zero)
        XCTAssertEqual(grown.textBoundingSize, plain.textBoundingSize)
    }

    // MARK: - Padded-canvas drawing

    /// The capsule's left arc that a tight canvas clips must be fully
    /// inside a padded canvas when the draw shifts by the overflow.
    func testPaddedCanvasShowsFullLeftBleed() throws {
        let l = layout(insets: LoomEdgeInsets(top: 0, left: -4, bottom: 0, right: 0))
        let range = NSRange(location: 0, length: 3)
        let rect = l.rect(for: range)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.5, "capsule must sit at the line start")

        let bounding = l.textBoundingSize
        let overflow = l.inkOverflow
        let padded = CGSize(width: bounding.width + overflow.left, height: bounding.height)
        let canvas = try PixelCanvas(
            layout: l, canvas: padded,
            point: CGPoint(x: overflow.left, y: 0), scale: 2
        )
        func greenAt(_ x: CGFloat, _ y: CGFloat) -> Bool {
            let px = Int(x * canvas.scale), py = Int(y * canvas.scale)
            guard px >= 0, py >= 0, px < canvas.pixelWidth, py < canvas.pixelHeight else { return false }
            let base = (py * canvas.pixelWidth + px) * 4
            return canvas.pixels[base + 3] > 24 && canvas.pixels[base + 1] > canvas.pixels[base]
        }
        // Bled region: x ∈ [0, 4) of the padded canvas — previously
        // clipped away entirely.
        XCTAssertTrue(greenAt(1.5, rect.midY), "left bleed must be painted in the padded canvas")
        // Sanity: the shifted capsule interior still fills. A single
        // sample can land on a black glyph stroke — scan the row.
        var interiorGreen = false
        for x in stride(from: overflow.left + 1, to: overflow.left + rect.maxX, by: 0.5) where greenAt(x, rect.midY) {
            interiorGreen = true
            break
        }
        XCTAssertTrue(interiorGreen)
    }

    // MARK: - Layer plumbing (UIKit)

    #if canImport(UIKit)
    @MainActor
    func testInkLayerLifecycle() {
        let grown = layout(insets: LoomEdgeInsets(top: 0, left: -4, bottom: 0, right: 0))
        let label = LoomLabel(frame: CGRect(origin: .zero, size: grown.textBoundingSize))
        label.displaysAsynchronously = false
        let layer = label.layer as! LoomAsyncLayer

        label.textLayout = grown
        layer.displayIfNeeded()
        XCTAssertNotNil(layer.inkLayer, "grown capsule must render on the overflow layer")
        XCTAssertNil(layer.contents, "the base layer must not double-host the bitmap")
        XCTAssertEqual(layer.inkLayer!.frame.origin.x, -4)
        XCTAssertNotNil(layer.inkLayer!.contents)

        // A plain layout returns to the fast path and drops the sublayer.
        label.textLayout = LoomTextLayout(
            containerSize: CGSize(width: 200, height: 60), text: attr("plain")
        )
        layer.displayIfNeeded()
        XCTAssertNil(layer.inkLayer)
        XCTAssertNotNil(layer.contents)

        // Clearing clears everything.
        label.textLayout = nil
        layer.displayIfNeeded()
        XCTAssertNil(layer.inkLayer)
        XCTAssertNil(layer.contents)
    }
    #endif
}

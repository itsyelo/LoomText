//
//  LoomTextBackgroundTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

final class LoomTextBackgroundTests: XCTestCase {

    private let green = CGColor(red: 0, green: 1, blue: 0, alpha: 1)

    private func text(
        _ string: String = "before CAPSULE after",
        backgroundRange: NSRange = NSRange(location: 7, length: 7),
        cornerRadius: CGFloat = 0,
        insets: LoomEdgeInsets = .zero
    ) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let text = NSMutableAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        text.loom_setBackground(
            LoomTextBackground(fillColor: green, cornerRadius: cornerRadius, insets: insets),
            range: backgroundRange
        )
        return text
    }

    private func greenAt(_ canvas: PixelCanvas, x: CGFloat, y: CGFloat) -> Bool {
        let px = Int(x * canvas.scale), py = Int(y * canvas.scale)
        guard px >= 0, py >= 0, px < canvas.pixelWidth, py < canvas.pixelHeight else { return false }
        let base = (py * canvas.pixelWidth + px) * 4
        return canvas.pixels[base + 3] > 24 && canvas.pixels[base + 1] > canvas.pixels[base]
    }

    func testBackgroundFillsBehindRangeOnly() throws {
        let range = NSRange(location: 7, length: 7)
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 60), text: text())
        )
        let rect = layout.rect(for: range)
        let canvas = try PixelCanvas(
            layout: layout, canvas: CGSize(width: 400, height: 60), point: .zero, scale: 2
        )
        XCTAssertTrue(greenAt(canvas, x: rect.midX, y: rect.midY), "capsule center must be filled")
        XCTAssertTrue(greenAt(canvas, x: rect.minX + 1, y: rect.midY))
        XCTAssertFalse(greenAt(canvas, x: 2, y: rect.midY), "text before the range must have no fill")
        XCTAssertFalse(greenAt(canvas, x: rect.maxX + 8, y: rect.midY))
    }

    func testCornerRadiusLeavesCornersEmpty() throws {
        let range = NSRange(location: 7, length: 7)
        let square = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 60), text: text(cornerRadius: 0))
        )
        let rounded = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 60), text: text(cornerRadius: 8))
        )
        let rect = square.rect(for: range)
        let squareCanvas = try PixelCanvas(
            layout: square, canvas: CGSize(width: 400, height: 60), point: .zero, scale: 2
        )
        let roundedCanvas = try PixelCanvas(
            layout: rounded, canvas: CGSize(width: 400, height: 60), point: .zero, scale: 2
        )
        // Top-left corner pixel: filled when square, clipped when rounded.
        XCTAssertTrue(greenAt(squareCanvas, x: rect.minX + 0.5, y: rect.minY + 0.5))
        XCTAssertFalse(greenAt(roundedCanvas, x: rect.minX + 0.5, y: rect.minY + 0.5))
        // Both fill the center.
        XCTAssertTrue(greenAt(roundedCanvas, x: rect.midX, y: rect.midY))
    }

    func testMultilineRangeFillsEachFragment() throws {
        let string = "wrap wrap wrap wrap wrap wrap wrap wrap"
        let range = NSRange(location: 5, length: 25)
        let layout = try XCTUnwrap(
            LoomTextLayout(
                containerSize: CGSize(width: 90, height: 10_000),
                text: text(string, backgroundRange: range, cornerRadius: 4)
            )
        )
        let rects = layout.selectionRects(for: range)
        XCTAssertGreaterThan(rects.count, 1)
        let canvas = try PixelCanvas(
            layout: layout,
            canvas: CGSize(width: 90, height: layout.textBoundingSize.height + 4),
            point: .zero, scale: 2
        )
        // A single sample can land on a black glyph stroke covering the
        // fill — require green anywhere within each fragment instead.
        for rect in rects {
            var found = false
            for x in stride(from: rect.minX + 1, to: rect.maxX - 1, by: 2) where !found {
                for y in stride(from: rect.minY + 1, to: rect.maxY - 1, by: 2) where !found {
                    found = greenAt(canvas, x: x, y: y)
                }
            }
            XCTAssertTrue(found, "fragment \(rect) must contain fill pixels")
        }
    }

    func testHighlightedTokenBackgroundFillsTokenRect() throws {
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let token = NSMutableAttributedString(
            string: "\u{2026}more",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        token.loom_setBackground(
            LoomTextBackground(fillColor: green, cornerRadius: 4),
            range: NSRange(location: 0, length: token.length)
        )
        let body = NSAttributedString(
            string: "Long text that certainly wraps and truncates across two lines of content.",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let container = LoomTextContainer(
            size: CGSize(width: 140, height: 10_000), maximumNumberOfRows: 2, truncationToken: token
        )
        let layout = try XCTUnwrap(LoomTextLayout(container: container, text: body))
        let tokenRect = try XCTUnwrap(layout.truncationTokenRect)
        let canvas = try PixelCanvas(
            layout: layout,
            canvas: CGSize(width: 140, height: layout.textBoundingSize.height + 4),
            point: .zero, scale: 2
        )
        XCTAssertTrue(greenAt(canvas, x: tokenRect.midX, y: tokenRect.midY))
    }
}

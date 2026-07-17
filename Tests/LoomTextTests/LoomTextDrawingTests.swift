//
//  LoomTextDrawingTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import CoreText
import XCTest
@testable import LoomText

/// Headless CGContext rendering tests — run on macOS and iOS alike.
final class LoomTextDrawingTests: XCTestCase {

    private func attr(_ string: String, size: CGFloat = 16) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        return NSAttributedString(
            string: string,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
    }

    /// Renders a layout into an RGBA bitmap and returns the raw bytes.
    private func render(
        _ layout: LoomTextLayout,
        canvas: CGSize,
        cancel: (() -> Bool)? = nil
    ) throws -> [UInt8] {
        let width = max(1, Int(ceil(canvas.width)))
        let height = max(1, Int(ceil(canvas.height)))
        let bytesPerRow = width * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            layout.draw(in: context, size: canvas, cancel: cancel)
        }
        return data
    }

    private func inkCount(_ rgba: [UInt8]) -> Int {
        stride(from: 3, to: rgba.count, by: 4).reduce(0) { $0 + ($1 < rgba.count && rgba[$1] > 0 ? 1 : 0) }
    }

    func testDrawProducesInk() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 200, height: 50), text: attr("Hello LoomText"))
        )
        let pixels = try render(layout, canvas: CGSize(width: 200, height: 50))
        XCTAssertGreaterThan(inkCount(pixels), 50)
    }

    func testEmptyLayoutDrawsNothing() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 100, height: 50), text: attr(""))
        )
        let pixels = try render(layout, canvas: CGSize(width: 100, height: 50))
        XCTAssertEqual(inkCount(pixels), 0)
    }

    func testDrawIsDeterministic() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(
                containerSize: CGSize(width: 150, height: 200),
                text: attr("Deterministic rendering across repeated draws 确定性绘制")
            )
        )
        let first = try render(layout, canvas: CGSize(width: 150, height: 200))
        let second = try render(layout, canvas: CGSize(width: 150, height: 200))
        XCTAssertEqual(first, second)
    }

    func testCancelStopsDrawingEarly() throws {
        let text = attr("Line one line two line three line four line five line six line seven")
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 90, height: 500), text: text)
        )
        XCTAssertGreaterThan(layout.lines.count, 2)
        let full = try render(layout, canvas: CGSize(width: 90, height: 500))
        let cancelled = try render(layout, canvas: CGSize(width: 90, height: 500)) { true }
        XCTAssertGreaterThan(inkCount(cancelled), 0, "first line draws before the first cancel poll")
        XCTAssertLessThan(inkCount(cancelled), inkCount(full))
    }

    func testDrawAtOffsetShiftsInk() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 100, height: 30), text: attr("Offset"))
        )
        let canvas = CGSize(width: 200, height: 100)
        let width = Int(canvas.width)

        var data = [UInt8](repeating: 0, count: width * Int(canvas.height) * 4)
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress, width: width, height: Int(canvas.height),
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            )
            layout.draw(in: context, size: canvas, point: CGPoint(x: 100, y: 0))
        }
        // All ink must sit in the right half of the canvas.
        for y in 0..<Int(canvas.height) {
            for x in 0..<95 {
                let alpha = data[(y * width + x) * 4 + 3]
                XCTAssertEqual(alpha, 0, "unexpected ink at (\(x),\(y))")
                if alpha != 0 { return }
            }
        }
    }
}

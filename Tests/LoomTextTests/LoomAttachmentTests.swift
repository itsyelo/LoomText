//
//  LoomAttachmentTests.swift
//  LoomTextTests
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import LoomText

final class LoomAttachmentTests: XCTestCase {

    private func font(_ size: CGFloat = 16) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private func solidImage(width: Int, height: Int, red: CGFloat = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private func mixedText(
        contentSize: CGSize = CGSize(width: 20, height: 20),
        alignment: LoomTextVerticalAlignment = .center
    ) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "before ",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font()]
        )
        text.append(
            .loom_attachmentString(
                content: solidImage(width: Int(contentSize.width), height: Int(contentSize.height)),
                contentSize: contentSize,
                alignTo: font(),
                verticalAlignment: alignment
            )
        )
        text.append(
            NSAttributedString(
                string: " after",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font()]
            )
        )
        return text
    }

    // MARK: - Geometry

    func testAttachmentReservesContentSize() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: mixedText())
        )
        XCTAssertEqual(layout.attachments.count, 1)
        let rect = try XCTUnwrap(layout.attachmentRects.first)
        XCTAssertEqual(rect.width, 20, accuracy: 0.5)
        XCTAssertEqual(rect.height, 20, accuracy: 0.5)
        // A 20pt attachment on a 16pt line grows the line box.
        XCTAssertGreaterThanOrEqual(layout.lines[0].bounds.height + 0.5, 20)
        // The placeholder occupies exactly one character.
        XCTAssertEqual(layout.attachmentRanges.first?.length, 1)
    }

    func testVerticalAlignmentPinsEdges() throws {
        // YYText semantics: `.top` pins the attachment's TOP edge to the
        // font's ascent line (tall content hangs downward), `.bottom`
        // pins its BOTTOM edge to the descent line (tall content grows
        // upward), `.center` centers on the font box midline.
        let fontAscent = CTFontGetAscent(font())
        let fontDescent = CTFontGetDescent(font())

        func rect(_ alignment: LoomTextVerticalAlignment) throws -> (rect: CGRect, baseline: CGFloat) {
            let layout = try XCTUnwrap(
                LoomTextLayout(
                    containerSize: CGSize(width: 400, height: 100),
                    text: mixedText(alignment: alignment)
                )
            )
            return (try XCTUnwrap(layout.attachmentRects.first), layout.lines[0].position.y)
        }

        let top = try rect(.top)
        XCTAssertEqual(top.rect.minY, top.baseline - fontAscent, accuracy: 0.5)

        let bottom = try rect(.bottom)
        XCTAssertEqual(bottom.rect.maxY, bottom.baseline + fontDescent, accuracy: 0.5)

        let center = try rect(.center)
        let fontBoxMid = center.baseline - fontAscent + (fontAscent + fontDescent) / 2
        XCTAssertEqual(center.rect.midY, fontBoxMid, accuracy: 0.5)
    }

    func testAttachmentTruncatedOutIsDropped() throws {
        // Attachment lands beyond maxRows: not extracted, not drawn.
        let text = NSMutableAttributedString(
            string: "wrap wrap wrap wrap wrap wrap wrap wrap wrap wrap ",
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font()]
        )
        text.append(
            .loom_attachmentString(
                content: solidImage(width: 20, height: 20),
                contentSize: CGSize(width: 20, height: 20),
                alignTo: font()
            )
        )
        let container = LoomTextContainer(
            size: CGSize(width: 90, height: 10_000), maximumNumberOfRows: 2, truncationType: .none
        )
        let layout = try XCTUnwrap(LoomTextLayout(container: container, text: text))
        XCTAssertTrue(layout.isTruncated)
        XCTAssertTrue(layout.attachments.isEmpty)
    }

    // MARK: - Rendering

    func testImageAttachmentRendersRedInk() throws {
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 400, height: 100), text: mixedText())
        )
        let rect = try XCTUnwrap(layout.attachmentRects.first)
        let canvas = CGSize(
            width: layout.textBoundingSize.width + 10, height: layout.textBoundingSize.height + 10
        )
        let rendered = try PixelCanvas(layout: layout, canvas: canvas, point: .zero, scale: 2)

        // Sample the attachment center: must be red.
        let px = Int(rect.midX * 2), py = Int(rect.midY * 2)
        let base = (py * rendered.pixelWidth + px) * 4
        XCTAssertGreaterThan(rendered.pixels[base], 200, "attachment center should be red")
        XCTAssertLessThan(rendered.pixels[base + 1], 60)
        // And the ink stays within the claimed bounding box vertically.
        let ink = try XCTUnwrap(rendered.inkRect)
        XCTAssertLessThanOrEqual(ink.maxY, layout.textBoundingSize.height + 0.01)
        XCTAssertGreaterThanOrEqual(ink.minY, -0.01)
    }

    func testViewContentIsNotDrawnIntoBitmap() throws {
        // A non-image content must leave the attachment rect blank in
        // the bitmap (the label mounts it instead).
        final class Marker {}
        let text = NSMutableAttributedString(attributedString: .loom_attachmentString(
            content: Marker(),
            contentSize: CGSize(width: 20, height: 20),
            alignTo: font()
        ))
        let layout = try XCTUnwrap(
            LoomTextLayout(containerSize: CGSize(width: 100, height: 50), text: text)
        )
        XCTAssertEqual(layout.attachments.count, 1)
        let rendered = try PixelCanvas(
            layout: layout, canvas: CGSize(width: 100, height: 50), point: .zero, scale: 2
        )
        XCTAssertEqual(rendered.inkCount, 0)
    }
}

#if canImport(UIKit)
import UIKit

@MainActor
final class LoomAttachmentMountingTests: XCTestCase {

    private func attachmentText(content: Any) -> NSAttributedString {
        let text = NSMutableAttributedString(string: "pic ", attributes: [
            .font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.black,
        ])
        text.append(.loom_attachmentString(
            content: content,
            contentSize: CGSize(width: 24, height: 24),
            alignTo: UIFont.systemFont(ofSize: 16)
        ))
        return text
    }

    func testViewAttachmentMountsAndUnmounts() throws {
        let size = CGSize(width: 200, height: 40)
        let badge = UIView()
        badge.backgroundColor = .blue

        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = false
        label.textLayout = LoomTextLayout(containerSize: size, text: attachmentText(content: badge))
        label.layer.displayIfNeeded()

        XCTAssertEqual(badge.superview, label, "view attachment must be mounted")
        let layout = try XCTUnwrap(label.textLayout)
        XCTAssertEqual(badge.frame, layout.attachmentRects[0])

        label.textLayout = nil
        label.layer.displayIfNeeded()
        XCTAssertNil(badge.superview, "clearing the layout must unmount attachments")
    }

    func testLayerAttachmentMounts() throws {
        let size = CGSize(width: 200, height: 40)
        let badgeLayer = CALayer()
        let label = LoomLabel(frame: CGRect(origin: .zero, size: size))
        label.displaysAsynchronously = false
        label.textLayout = LoomTextLayout(containerSize: size, text: attachmentText(content: badgeLayer))
        label.layer.displayIfNeeded()
        XCTAssertEqual(badgeLayer.superlayer, label.layer)

        // Replacing the layout with unrelated content unmounts the layer.
        label.textLayout = LoomTextLayout(
            containerSize: size,
            text: NSAttributedString(string: "plain", attributes: [.font: UIFont.systemFont(ofSize: 16)])
        )
        label.layer.displayIfNeeded()
        XCTAssertNil(badgeLayer.superlayer)
    }
}
#endif

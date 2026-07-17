//
//  LoomTextAttachment.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//  Ported from YYText's YYTextAttachment + YYTextRunDelegate.
//

import CoreGraphics
import CoreText
import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension NSAttributedString.Key {
    /// Marks a run as an inline attachment. Value: ``LoomTextAttachment``.
    public static let loomTextAttachment = NSAttributedString.Key("LoomTextAttachment")
}

/// Vertical placement of an attachment relative to the aligned font.
public enum LoomTextVerticalAlignment: Sendable {
    case top
    case center
    case bottom
}

/// Inline content embedded in text: an image drawn into the rendered
/// bitmap, or a view/layer mounted by the label on the main thread.
///
/// `content` accepts `CGImage`/`UIImage` (drawn on the render thread —
/// both immutable) or `UIView`/`CALayer` (never drawn; ``LoomLabel``
/// mounts them at the attachment's rect after the bitmap commits).
///
/// For dynamic content (animated stickers), use `viewProvider` instead:
/// it is called **on the main thread at every mount**, so the closure
/// decides the ownership policy — return a memoized instance to keep
/// animation state across cell reuse, or dequeue from an app-side pool
/// (with `onViewUnmounted` returning it) to keep live view count
/// O(visible) instead of O(messages). Both closures are `@MainActor`;
/// storing them in this Sendable type is safe because they only ever
/// run on the main thread via the label's mount/unmount paths.
public final class LoomTextAttachment: @unchecked Sendable {

    public let content: Any?
    public let verticalAlignment: LoomTextVerticalAlignment

    /// Textual stand-in for the copy pipeline (and VoiceOver fallback):
    /// what this attachment contributes to
    /// ``LoomTextLayout/plainText(in:)`` — e.g. `"[表情]"` or the emoji
    /// the sticker depicts. `nil` means the attachment copies as
    /// nothing (the placeholder is stripped).
    public let altText: String?

    #if canImport(UIKit)
    /// Called on the main thread each time the attachment mounts.
    /// Takes precedence over `content` for view mounting.
    public let viewProvider: (@MainActor () -> UIView)?

    /// Called on the main thread when a provided view unmounts, with
    /// the same instance `viewProvider` returned — the recycle hook.
    public let onViewUnmounted: (@MainActor (UIView) -> Void)?

    public init(
        content: Any,
        verticalAlignment: LoomTextVerticalAlignment = .center,
        altText: String? = nil
    ) {
        self.content = content
        self.verticalAlignment = verticalAlignment
        self.altText = altText
        self.viewProvider = nil
        self.onViewUnmounted = nil
    }

    public init(
        viewProvider: @escaping @MainActor () -> UIView,
        onViewUnmounted: (@MainActor (UIView) -> Void)? = nil,
        verticalAlignment: LoomTextVerticalAlignment = .center,
        altText: String? = nil
    ) {
        self.content = nil
        self.verticalAlignment = verticalAlignment
        self.altText = altText
        self.viewProvider = viewProvider
        self.onViewUnmounted = onViewUnmounted
    }
    #else
    public init(
        content: Any,
        verticalAlignment: LoomTextVerticalAlignment = .center,
        altText: String? = nil
    ) {
        self.content = content
        self.verticalAlignment = verticalAlignment
        self.altText = altText
    }
    #endif
}

// MARK: - Run delegate

private final class RunDelegateMetrics {
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat
    init(ascent: CGFloat, descent: CGFloat, width: CGFloat) {
        self.ascent = ascent
        self.descent = descent
        self.width = width
    }
}

func loomMakeRunDelegate(ascent: CGFloat, descent: CGFloat, width: CGFloat) -> CTRunDelegate? {
    var callbacks = CTRunDelegateCallbacks(
        version: kCTRunDelegateCurrentVersion,
        dealloc: { pointer in
            Unmanaged<RunDelegateMetrics>.fromOpaque(pointer).release()
        },
        getAscent: { pointer in
            Unmanaged<RunDelegateMetrics>.fromOpaque(pointer).takeUnretainedValue().ascent
        },
        getDescent: { pointer in
            Unmanaged<RunDelegateMetrics>.fromOpaque(pointer).takeUnretainedValue().descent
        },
        getWidth: { pointer in
            Unmanaged<RunDelegateMetrics>.fromOpaque(pointer).takeUnretainedValue().width
        }
    )
    let metrics = RunDelegateMetrics(ascent: ascent, descent: descent, width: width)
    return CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(metrics).toOpaque())
}

// MARK: - Attachment string

extension NSAttributedString {

    /// Builds a one-character (U+FFFC) attachment string whose run
    /// delegate reserves `contentSize`, vertically aligned to a font's
    /// ascent/descent (YYText's alignment math).
    public static func loom_attachmentString(
        content: Any,
        contentSize: CGSize,
        fontAscent: CGFloat,
        fontDescent: CGFloat,
        verticalAlignment: LoomTextVerticalAlignment = .center,
        altText: String? = nil
    ) -> NSAttributedString {
        loom_attachmentString(
            attachment: LoomTextAttachment(
                content: content, verticalAlignment: verticalAlignment, altText: altText
            ),
            contentSize: contentSize,
            fontAscent: fontAscent,
            fontDescent: fontDescent
        )
    }

    /// Core builder taking a preconstructed attachment (any ownership
    /// flavor: direct content or view provider).
    public static func loom_attachmentString(
        attachment: LoomTextAttachment,
        contentSize: CGSize,
        fontAscent: CGFloat,
        fontDescent: CGFloat
    ) -> NSAttributedString {
        let ascent: CGFloat
        let descent: CGFloat
        switch attachment.verticalAlignment {
        case .top:
            ascent = fontAscent
            descent = max(0, contentSize.height - fontAscent)
        case .center:
            let fontHeight = fontAscent + fontDescent
            let yOffset = fontAscent - fontHeight * 0.5
            ascent = contentSize.height * 0.5 + yOffset
            descent = max(0, contentSize.height - ascent)
        case .bottom:
            descent = fontDescent
            ascent = max(0, contentSize.height - fontDescent)
        }

        let string = NSMutableAttributedString(string: "\u{FFFC}")
        let fullRange = NSRange(location: 0, length: string.length)
        string.addAttribute(.loomTextAttachment, value: attachment, range: fullRange)
        if let delegate = loomMakeRunDelegate(ascent: ascent, descent: descent, width: contentSize.width) {
            string.addAttribute(
                NSAttributedString.Key(kCTRunDelegateAttributeName as String),
                value: delegate,
                range: fullRange
            )
        }
        return string
    }

    /// CTFont-flavored overload.
    public static func loom_attachmentString(
        content: Any,
        contentSize: CGSize,
        alignTo font: CTFont,
        verticalAlignment: LoomTextVerticalAlignment = .center,
        altText: String? = nil
    ) -> NSAttributedString {
        loom_attachmentString(
            content: content,
            contentSize: contentSize,
            fontAscent: CTFontGetAscent(font),
            fontDescent: CTFontGetDescent(font),
            verticalAlignment: verticalAlignment,
            altText: altText
        )
    }
}

#if canImport(UIKit)
extension NSAttributedString {
    /// UIFont-flavored overload.
    public static func loom_attachmentString(
        content: Any,
        contentSize: CGSize,
        alignTo font: UIFont,
        verticalAlignment: LoomTextVerticalAlignment = .center,
        altText: String? = nil
    ) -> NSAttributedString {
        loom_attachmentString(
            content: content,
            contentSize: contentSize,
            fontAscent: font.ascender,
            fontDescent: -font.descender,
            verticalAlignment: verticalAlignment,
            altText: altText
        )
    }

    /// Provider-flavored overload for dynamic content (animated
    /// stickers): the view is created/dequeued at mount time on the
    /// main thread and recycled through `onViewUnmounted`.
    public static func loom_attachmentString(
        viewProvider: @escaping @MainActor () -> UIView,
        onViewUnmounted: (@MainActor (UIView) -> Void)? = nil,
        contentSize: CGSize,
        alignTo font: UIFont,
        verticalAlignment: LoomTextVerticalAlignment = .center,
        altText: String? = nil
    ) -> NSAttributedString {
        let attachment = LoomTextAttachment(
            viewProvider: viewProvider,
            onViewUnmounted: onViewUnmounted,
            verticalAlignment: verticalAlignment,
            altText: altText
        )
        return loom_attachmentString(
            attachment: attachment,
            contentSize: contentSize,
            fontAscent: font.ascender,
            fontDescent: -font.descender
        )
    }
}
#endif

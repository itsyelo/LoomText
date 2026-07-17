//
//  LoomLabel+Accessibility.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//
//  UILabel gives VoiceOver support for free; a self-drawn label has to
//  earn it. Plain text exposes the label itself as one static-text
//  element. Text with highlights (or a tappable truncation token)
//  becomes an accessibility container: static segments and link
//  elements in reading order, each activatable.
//

#if canImport(UIKit)
import UIKit

/// An element whose activation runs a closure (link taps for VoiceOver).
final class LoomAccessibilityElement: UIAccessibilityElement {
    var activation: (() -> Bool)?

    override func accessibilityActivate() -> Bool {
        activation?() ?? false
    }
}

extension LoomLabel {

    // MARK: - UIAccessibility

    public override var isAccessibilityElement: Bool {
        get { textLayout != nil && !hasInteractiveContent }
        set {} // managed by content
    }

    public override var accessibilityLabel: String? {
        get { textLayout.map { Self.accessibleText(of: $0) } }
        set {}
    }

    public override var accessibilityTraits: UIAccessibilityTraits {
        get { .staticText }
        set {}
    }

    public override var accessibilityElements: [Any]? {
        get {
            guard hasInteractiveContent, let layout = textLayout else { return nil }
            if let cached = cachedAccessibilityElements { return cached }
            let elements = buildAccessibilityElements(for: layout)
            cachedAccessibilityElements = elements
            return elements
        }
        set {}
    }

    /// Selection-enabled labels offer "Copy" as a VoiceOver custom
    /// action — the whole selectable text, no visual selection needed.
    public override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { selectionCopyActions() }
        set {}
    }

    func selectionCopyActions() -> [UIAccessibilityCustomAction]? {
        guard #available(iOS 16.0, *), selectionController != nil,
              let layout = textLayout, layout.selectableRange.length > 0
        else { return nil }
        let action = UIAccessibilityCustomAction(name: "Copy") { [weak self] _ in
            guard #available(iOS 16.0, *), let self, let controller = self.selectionController,
                  let layout = self.textLayout
            else { return false }
            controller.copySink(layout.plainText(in: layout.selectableRange))
            return true
        }
        return [action]
    }

    /// Whether the layout carries tappable ranges (inline highlights in
    /// the visible range, or a highlighted truncation token).
    var hasInteractiveContent: Bool {
        guard let layout = textLayout else { return false }
        if layout.resolvedTruncationToken?.length ?? 0 > 0,
           layout.truncationTokenRect != nil,
           tokenHighlight(of: layout) != nil {
            return true
        }
        guard layout.visibleRange.length > 0 else { return false }
        var found = false
        layout.text.enumerateAttribute(.loomTextHighlight, in: layout.visibleRange) { value, _, stop in
            if value is LoomTextHighlight {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func invalidateAccessibilityElements() {
        cachedAccessibilityElements = nil
    }

    // MARK: - Element construction

    private func buildAccessibilityElements(for layout: LoomTextLayout) -> [Any] {
        var elements: [Any] = []
        let visible = layout.visibleRange
        if visible.length > 0 {
            layout.text.enumerateAttribute(.loomTextHighlight, in: visible) { value, range, _ in
                let element = LoomAccessibilityElement(accessibilityContainer: self)
                element.accessibilityLabel = Self.accessibleText(
                    of: layout, in: range
                )
                element.accessibilityFrameInContainerSpace = layout.rect(for: range).standardized
                if let highlight = value as? LoomTextHighlight {
                    element.accessibilityTraits = .link
                    element.activation = { [weak self] in
                        guard let self, let layout = self.textLayout else { return false }
                        self.highlightTapAction?(self, layout.text, range, layout.rect(for: range))
                        _ = highlight // routing payload lives in userInfo
                        return self.highlightTapAction != nil
                    }
                } else {
                    element.accessibilityTraits = .staticText
                }
                // Container mode hides the label element itself — expose
                // the copy action on every child element instead.
                element.accessibilityCustomActions = selectionCopyActions()
                elements.append(element)
            }
        }

        // The truncation token reads (and activates) as its own element.
        if let token = layout.resolvedTruncationToken, token.length > 0,
           let tokenRect = layout.truncationTokenRect {
            let element = LoomAccessibilityElement(accessibilityContainer: self)
            element.accessibilityLabel = token.string
            element.accessibilityFrameInContainerSpace = tokenRect.standardized
            if let highlight = tokenHighlight(of: layout) {
                element.accessibilityTraits = .link
                element.activation = { [weak self] in
                    guard let self, let layout = self.textLayout,
                          let token = layout.resolvedTruncationToken,
                          let rect = layout.truncationTokenRect
                    else { return false }
                    self.highlightTapAction?(self, token, highlight.range, rect)
                    return self.highlightTapAction != nil
                }
            } else {
                element.accessibilityTraits = .staticText
            }
            elements.append(element)
        }
        return elements
    }

    private func tokenHighlight(of layout: LoomTextLayout) -> (highlight: LoomTextHighlight, range: NSRange)? {
        guard let token = layout.resolvedTruncationToken, token.length > 0 else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard let value = token.attribute(
            .loomTextHighlight, at: 0, longestEffectiveRange: &range,
            in: NSRange(location: 0, length: token.length)
        ) as? LoomTextHighlight else { return nil }
        return (value, range)
    }

    // MARK: - Spoken text

    /// Plain text for VoiceOver: attachment placeholders (U+FFFC) speak
    /// their content's `accessibilityLabel`, falling back to `altText`.
    static func accessibleText(of layout: LoomTextLayout) -> String {
        accessibleText(of: layout, in: layout.visibleRange)
    }

    private static func accessibleText(of layout: LoomTextLayout, in range: NSRange) -> String {
        let substring = layout.text.attributedSubstring(from: range)
        guard substring.string.contains("\u{FFFC}") else { return substring.string }
        // Collect first, replace back to front — replacements of a
        // different length would shift the ranges mid-enumeration.
        var replacements: [(NSRange, String)] = []
        substring.enumerateAttribute(
            .loomTextAttachment, in: NSRange(location: 0, length: substring.length)
        ) { value, attachmentRange, _ in
            guard let attachment = value as? LoomTextAttachment else { return }
            let spoken = (attachment.content as? NSObject)?.accessibilityLabel
                ?? attachment.altText ?? ""
            replacements.append((attachmentRange, spoken))
        }
        let result = NSMutableString(string: substring.string)
        for (attachmentRange, spoken) in replacements.reversed() {
            result.replaceCharacters(in: attachmentRange, with: spoken)
        }
        return result as String
    }
}
#endif

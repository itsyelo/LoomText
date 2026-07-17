# LoomText

CoreText-powered text rendering for iOS — precomputed layout, async drawing, and the text features `UILabel` can't do.

Sister library of [Loom](https://github.com/itsyelo/Loom): Loom calculates layout on a background thread; LoomText typesets and renders text the same way. Typeset once — measurement and rendering share a single immutable `LoomTextLayout`, eliminating `UILabel`'s double typesetting and cross-engine alignment residuals.

## Features

- **`LoomTextLayout`** — immutable, thread-safe CoreText layout; build it on any thread, size cells from `textBoundingSize`, hand the same instance to the label
- **`LoomLabel`** — renders a precomputed layout with zero main-thread typesetting, synchronously or fully asynchronously (`displaysAsynchronously`)
- **Async rendering** — background rasterization with sentinel cancellation and run-loop-coalesced commits
- **Custom truncation token** — attributed, tappable "… more"; collapsed and expanded prefixes are pixel-identical
- **Highlights** — tappable / long-pressable ranges with a pressed state (`LoomTextHighlight`), including rounded capsule backgrounds and outlined tags (`LoomTextBackground`)
- **Decorations** — self-drawn underline and strikethrough honoring the standard attributes (`CTLineDraw` renders neither), single/thick/double
- **Text selection** (iOS 16+) — WeChat/Telegram-style read-only selection: long-press to select, draggable handles with grapheme snapping, system edit menu (Copy / Select All + custom items), loupe on iOS 17+ — all as an overlay, the async pipeline stays untouched
- **Attachments** — inline images, views, and layers via `CTRunDelegate`; mount/unmount hooks (`viewProvider` / `onViewUnmounted`) enable O(visible) view reuse pools for animated content
- **Dynamic colors** — async bitmaps re-render on trait changes; dark mode just works
- **Accessibility** — VoiceOver elements for text, links, and the truncation token

## Example App

`Example/LoomTextExample` is a tabbed demo (the project is checked in; run `xcodegen generate` only after editing `project.yml`):

| Tab | Demonstrates |
|-----|--------------|
| **Showcase** | Feature gallery — tappable truncation token (expand/collapse with a pixel-stable prefix), pressed highlight capsules, inline image/view attachments, animated GIF stickers, async & dark-mode toggles |
| **Loom Feed** | The Loom ↔ LoomText pipeline — 300 posts measured and typeset entirely off the main thread; measurement *is* rendering |
| **Chat** | 10,000 messages with inline animated stickers riding a view reuse pool — the HUD shows the live view count staying O(visible) |
| **Perf** | Side-by-side scroll comparison against a `UILabel` implementation of the same feed |

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/itsyelo/LoomText.git", from: "0.1.0")
]
```

Or in Xcode: **File → Add Package Dependencies** → paste the URL. Pre-1.0: minor versions may adjust APIs as feedback lands.

Requires iOS 14+. The package also builds on macOS 12+ for headless layout tests; the rendering surface (`LoomLabel`) is UIKit-only. Zero dependencies — just CoreText and UIKit.

## Quick Start

### Direct mode — typeset once (recommended)

Build the layout wherever you build view models — a background queue is fine — and give the label the exact instance you measured with:

```swift
import LoomText

// Off the main thread, in your view-model pipeline:
let container = LoomTextContainer(
    size: CGSize(width: cellWidth, height: 10_000),
    maximumNumberOfRows: 3,
    truncationToken: moreToken             // optional, attributed "… more"
)
guard let layout = LoomTextLayout(container: container, text: body) else { return }
let cellHeight = layout.textBoundingSize.height  // size the cell from the same data

// On the main thread:
label.textLayout = layout                  // zero typesetting here
label.displaysAsynchronously = true        // rasterize off-main too
```

### Convenience mode — like UILabel

```swift
let label = LoomLabel()
label.numberOfLines = 2
label.attributedText = body   // typesets internally on bounds changes
```

### Tappable highlights

```swift
let text = NSMutableAttributedString(string: "Ping @yelo about this")
let range = (text.string as NSString).range(of: "@yelo")
text.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
text.loom_setHighlight(
    range,
    pressedAttributes: [
        .loomTextBackground: LoomTextBackground(
            fillColor: UIColor.systemBlue.withAlphaComponent(0.18).cgColor,
            cornerRadius: 4
        )
    ],
    userInfo: ["mention": "@yelo"]
)

label.highlightTapAction = { label, text, range, rect in
    // Tapped range and its on-screen rect; identify the target via userInfo.
}
```

### Inline attachments

```swift
let text = NSMutableAttributedString(string: "GIF ")

// Image content draws into the text bitmap:
text.append(.loom_attachmentString(
    content: image,                         // UIImage / CGImage
    contentSize: CGSize(width: 20, height: 20),
    alignTo: font
))

// Animated content: provide the view at mount, recycle at unmount —
// thousands of messages can share a handful of live views.
text.append(.loom_attachmentString(
    viewProvider: { pool.dequeue() },
    onViewUnmounted: { pool.recycle($0) },
    contentSize: CGSize(width: 32, height: 32),
    alignTo: font
))
```

### Text selection (iOS 16+)

```swift
label.isTextSelectionEnabled = true    // long-press selects all (chat-bubble feel)
label.selectionInitialRange = .word    // …or the word under the finger
label.additionalEditMenuItems = { range in
    [UIAction(title: "Forward") { _ in /* … */ }]
}
label.selectionDidChange = { range in /* nil = dismissed */ }
```

Selection never touches the render pipeline: the tint and handles are
an overlay, dragging at 60 Hz costs two shape-layer updates. Copy
respects what is visible — text hidden behind a truncation token is
neither selectable nor copied, and attachments copy as their
`altText`. Selection chrome follows `tintColor` — set
`label.tintColor = .white` on saturated chat bubbles.

## Using with Loom

LoomText has no Loom dependency; the bridge is a dozen lines. From [`Example/LoomTextExample/LoomTextExample/LoomBridge.swift`](Example/LoomTextExample/LoomTextExample/LoomBridge.swift):

```swift
/// Loom measures through LoomText: measurement == rendering,
/// no cross-engine alignment residual.
struct LoomTextMeasurer: TextMeasuring {
    func measure(_ text: NSAttributedString, maxWidth: CGFloat,
                 maxHeight: CGFloat, maxLines: Int) -> CGSize {
        let container = LoomTextContainer(
            size: CGSize(width: maxWidth, height: maxHeight),
            maximumNumberOfRows: maxLines
        )
        return LoomTextLayout(container: container, text: text)?.textBoundingSize ?? .zero
    }
}

/// A Loom node sized by a prebuilt layout the label then renders as-is.
func LTText(_ layout: LoomTextLayout) -> LoomNode {
    Measured { _, _ in layout.textBoundingSize }
}
```

## Relationship to YYText

LoomText is a from-scratch Swift port of the *display side* of [YYText](https://github.com/ibireme/YYText) (MIT). The layout/render/highlight/attachment architecture, sentinel-based cancellation, and run-loop transaction batching all originate there — thank you, [@ibireme](https://github.com/ibireme). Editing (`YYTextView`), vertical text, and the parsers are deliberately out of scope. A few behaviors diverge on purpose and are pinned by tests, e.g. empty text measures `.zero` and the default ellipsis keeps the last run's typeface.

## License

MIT — see [LICENSE](LICENSE).

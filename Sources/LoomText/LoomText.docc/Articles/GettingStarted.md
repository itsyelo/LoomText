# Getting Started

Typeset once on a background queue, render the same data on the main thread.

## Direct mode

The core pattern: the view model owns the layout, the label renders it
verbatim.

```swift
// Background queue — view-model construction:
let container = LoomTextContainer(
    size: CGSize(width: cellWidth, height: 10_000),
    maximumNumberOfRows: 3,
    truncationToken: moreToken
)
let layout = LoomTextLayout(container: container, text: body)
let cellHeight = layout?.textBoundingSize.height ?? 0

// Main thread — cell configuration:
label.textLayout = layout
label.displaysAsynchronously = true
```

`LoomTextLayout` is immutable and safe to share across threads. Setting
`textLayout` never re-typesets; the label only rasterizes.

## Convenience mode

For non-performance-critical text, ``LoomLabel`` can behave like
`UILabel`: set `attributedText` and `numberOfLines`, and it typesets
internally whenever its bounds change.

## Truncation tokens

Pass an attributed `truncationToken` in the container to replace the
default ellipsis. Tokens participate in hit-testing: mark them with
`loom_setHighlight(_:pressedAttributes:userInfo:)` to build "… more"
expand affordances. The collapsed prefix is pixel-identical to the
expanded text — toggling layouts never shifts glyphs.

## Highlights

`loom_setHighlight` attaches a ``LoomTextHighlight`` to a range. While
pressed, the label re-typesets with the pressed attributes applied —
add a ``LoomTextBackground`` for a rounded capsule behind the range.
Handle taps via `LoomLabel/highlightTapAction` and long presses via
`LoomLabel/highlightLongPressAction`.

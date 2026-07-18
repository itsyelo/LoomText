# Text Selection

Read-only selection with handles, edit menu, and loupe — iOS 16+.

## Enabling

```swift
label.isTextSelectionEnabled = true
```

A long-press now selects. What it selects initially is configurable:

- `.all` (default) — the whole visible text, chat-bubble ergonomics.
- `.word` — the locale-aware word under the finger (CJK segments into
  words; ZWJ emoji are never split).

Drag either lollipop handle to adjust; endpoints snap to grapheme
clusters. The system edit menu appears on selection with Copy and
Select All (localized by UIKit), hides while a handle is dragged, and
returns on release. On iOS 17+ a loupe magnifies under the dragging
handle.

## Architecture

Selection chrome is a main-thread overlay above the rendered bitmap.
The async pipeline — background rasterization, sentinel cancellation,
run-loop commit batching — is never involved: dragging at 60 Hz costs
two shape-layer updates.

Selection respects visibility, including truncation holes: the tail
hidden behind an `.end` token, and the interior span a `.start` or
`.middle` token replaces, contribute no selection geometry and never
copy (`LoomTextLayout/selectableRanges`) — dragging across a hole
selects around it, and copy joins the visible head and tail.
Attachments copy as their ``LoomTextAttachment/altText`` (e.g.
`"[表情]"`) — or are stripped when they provide none
(`LoomTextLayout/plainText(in:)`). Selection rects are glyph-accurate
for bidirectional text: a range crossing an LTR↔RTL boundary
highlights exactly its visual segments.

## Theming

Selection chrome — the tinted fill (20% alpha) and both handles —
follows the label's standard `tintColor`. On saturated backgrounds
(e.g. the blue outgoing bubble of a chat) set a contrasting tint:

```swift
bubbleLabel.tintColor = .white   // iMessage-style chrome on blue
```

## Menu customization

```swift
label.additionalEditMenuItems = { range in
    [UIAction(title: "Forward") { _ in
        // range indexes into label.textLayout!.text
    }]
}
```

## Interplay with highlights

A long-press on a ``LoomTextHighlight`` range fires
`LoomLabel/highlightLongPressAction` when one is set; without one, the
long-press starts a selection. Taps on highlights keep working while
no selection is active.

## Dismissal

Tapping anywhere outside the selection, scrolling the enclosing scroll
view, swapping `textLayout`, or leaving the window all dismiss the
selection. Observe changes via `LoomLabel/selectionDidChange` (`nil`
means dismissed).

## VoiceOver

Selection-enabled labels expose a "Copy" custom action that copies the
whole visible text — no visual selection required.

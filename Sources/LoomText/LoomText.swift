//
//  LoomText.swift
//  LoomText
//
//  Copyright (c) 2026 itsyelo. Licensed under the MIT license.
//

/// Namespace for library-level metadata.
///
/// LoomText is a CoreText-based text rendering library for iOS —
/// the sister library of Loom. Loom computes layout off the main
/// thread; LoomText renders text from that same precomputed data,
/// so measurement and rendering share a single source of truth.
public enum LoomTextInfo {
    /// The library version. Pre-release until the first public tag.
    public static let version = "0.1.0-dev"
}

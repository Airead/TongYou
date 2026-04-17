import simd

/// GPU uniform data — the single point where integer sizes convert to float.
struct Uniforms {
    var projectionMatrix: simd_float4x4
    var screenSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var gridSize: SIMD2<UInt16>
    var gridPadding: SIMD4<Float>  // top, right, bottom, left
}

/// Per-instance data for cell background rendering.
/// Matches the Metal vertex buffer layout (stride = 8 bytes).
struct CellBgInstance {
    var gridPos: SIMD2<UInt16>     // (column, row)
    var color: SIMD4<UInt8>        // RGBA (0-255)
}

/// Per-instance data for cell text (glyph) rendering.
/// 32 bytes, matching the Metal vertex buffer layout.
struct CellTextInstance {
    var glyphPos: SIMD2<UInt32>    // atlas (x, y) in pixels          — 8 bytes
    var glyphSize: SIMD2<UInt32>   // atlas (w, h) in pixels          — 8 bytes
    var bearings: SIMD2<Int16>     // (bearingX, bearingY) in pixels  — 4 bytes
    var gridPos: SIMD2<UInt16>     // (column, row)                   — 4 bytes
    var color: SIMD4<UInt8>        // foreground RGBA (0-255)         — 4 bytes
    var offset: SIMD2<Int16> = .zero // (offsetX, offsetY) in pixels  — 4 bytes
}

/// Per-instance data for box-drawing segment rendering.
/// 16 bytes, matching the Metal vertex buffer layout.
struct BoxDrawSegmentInstance {
    var gridPos: SIMD2<UInt16>      // (column, row)                  — 4 bytes
    var color: SIMD4<UInt8>         // foreground RGBA (0-255)        — 4 bytes
    var cellOffset: SIMD2<UInt16>   // (x0, y0) pixel offset in cell  — 4 bytes
    var segmentSize: SIMD2<UInt16>  // (width, height) in pixels      — 4 bytes
}

/// Per-instance data for arc corner rendering (╭╮╯╰).
/// 12 bytes, matching the Metal vertex buffer layout.
struct ArcCornerInstance {
    var gridPos: SIMD2<UInt16>      // (column, row)                  — 4 bytes
    var color: SIMD4<UInt8>         // foreground RGBA (0-255)        — 4 bytes
    var cornerType: UInt16          // 0=╭, 1=╮, 2=╯, 3=╰            — 2 bytes
    var _pad: UInt16 = 0            //                                — 2 bytes
}

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
    var _pad: SIMD4<UInt8> = .zero // padding to 32 bytes             — 4 bytes
}

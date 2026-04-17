#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 projectionMatrix;
    float2 screenSize;
    float2 cellSize;
    ushort2 gridSize;
    float4 gridPadding;  // top, right, bottom, left
};

// Pixel-aligned cell origin from grid position (floor avoids subpixel gaps)
inline float2 cell_origin(ushort2 gridPos, constant Uniforms &uniforms) {
    return floor(float2(uniforms.gridPadding.w, uniforms.gridPadding.x)
                 + float2(gridPos) * uniforms.cellSize);
}

// MARK: - Cell Background

struct CellBgInstance {
    ushort2 gridPos [[attribute(0)]];
    uchar4 color    [[attribute(1)]];
};

struct CellBgVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex CellBgVertexOut cell_bg_vertex(
    uint vertex_id [[vertex_id]],
    CellBgInstance in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    float2 origin = cell_origin(in.gridPos, uniforms);
    float2 size = uniforms.cellSize;

    float2 positions[4] = {
        {0,      0},
        {size.x, 0},
        {0,      size.y},
        {size.x, size.y}
    };

    CellBgVertexOut out;
    out.position = uniforms.projectionMatrix * float4(origin + positions[vertex_id], 0.0, 1.0);
    out.color = float4(in.color) / 255.0;
    return out;
}

fragment float4 cell_bg_fragment(CellBgVertexOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Cell Underline (URL hover highlight)

vertex CellBgVertexOut underline_vertex(
    uint vertex_id [[vertex_id]],
    CellBgInstance in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    float2 origin = cell_origin(in.gridPos, uniforms);
    float2 size = uniforms.cellSize;
    float thickness = 2.0;

    float2 positions[4] = {
        {0,      size.y - thickness},
        {size.x, size.y - thickness},
        {0,      size.y},
        {size.x, size.y}
    };

    CellBgVertexOut out;
    out.position = uniforms.projectionMatrix * float4(origin + positions[vertex_id], 0.0, 1.0);
    out.color = float4(in.color) / 255.0;
    return out;
}

// MARK: - Cell Strikethrough

vertex CellBgVertexOut strikethrough_vertex(
    uint vertex_id [[vertex_id]],
    CellBgInstance in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    float2 origin = cell_origin(in.gridPos, uniforms);
    float2 size = uniforms.cellSize;
    float thickness = 2.0;
    float midY = floor(size.y * 0.5);

    float2 positions[4] = {
        {0,      midY - thickness * 0.5},
        {size.x, midY - thickness * 0.5},
        {0,      midY + thickness * 0.5},
        {size.x, midY + thickness * 0.5}
    };

    CellBgVertexOut out;
    out.position = uniforms.projectionMatrix * float4(origin + positions[vertex_id], 0.0, 1.0);
    out.color = float4(in.color) / 255.0;
    return out;
}

// MARK: - Cell Text (Glyph)

struct CellTextInstance {
    uint2  glyphPos  [[attribute(2)]];
    uint2  glyphSize [[attribute(3)]];
    short2 bearings  [[attribute(4)]];
    ushort2 gridPos  [[attribute(5)]];
    uchar4 color     [[attribute(6)]];
    short2 offset    [[attribute(7)]];
};

struct CellTextVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

vertex CellTextVertexOut cell_text_vertex(
    uint vertex_id [[vertex_id]],
    CellTextInstance in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    float2 glyphSize = float2(in.glyphSize);

    float2 corners[4] = {
        {0,            0},
        {glyphSize.x,  0},
        {0,            glyphSize.y},
        {glyphSize.x,  glyphSize.y}
    };

    float2 glyphOrigin = cell_origin(in.gridPos, uniforms) + float2(in.bearings) + float2(in.offset);
    float2 pos = glyphOrigin + corners[vertex_id];

    float2 atlasOrigin = float2(in.glyphPos);

    CellTextVertexOut out;
    out.position = uniforms.projectionMatrix * float4(pos, 0.0, 1.0);
    out.texCoord = atlasOrigin + corners[vertex_id];
    out.color = float4(in.color) / 255.0;
    return out;
}

fragment float4 cell_text_fragment(
    CellTextVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
    float alpha = atlas.sample(s, in.texCoord).r;
    return float4(in.color.rgb * alpha, alpha);
}

// MARK: - Cell Emoji (Color)

fragment float4 cell_emoji_fragment(
    CellTextVertexOut in [[stage_in]],
    texture2d<float> emojiAtlas [[texture(0)]]
) {
    constexpr sampler s(coord::pixel, filter::linear, address::clamp_to_edge);
    float4 color = emojiAtlas.sample(s, in.texCoord);
    return color;  // Pre-multiplied alpha from CGContext
}

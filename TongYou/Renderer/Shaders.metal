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

// MARK: - Box Drawing

struct BoxDrawSegmentInstance {
    ushort2 gridPos     [[attribute(0)]];
    uchar4  color       [[attribute(1)]];
    ushort2 cellOffset  [[attribute(2)]];
    ushort2 segmentSize [[attribute(3)]];
};

vertex CellBgVertexOut box_draw_vertex(
    uint vertex_id [[vertex_id]],
    BoxDrawSegmentInstance in [[stage_in]],
    constant Uniforms &uniforms [[buffer(0)]]
) {
    float2 origin = cell_origin(in.gridPos, uniforms) + float2(in.cellOffset);
    float2 size = float2(in.segmentSize);

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

// MARK: - Arc Corners (╭╮╯╰)

struct ArcCornerInstance {
    ushort2 gridPos    [[attribute(0)]];
    uchar4  color      [[attribute(1)]];
    ushort  cornerType [[attribute(2)]];
};

struct ArcCornerVertexOut {
    float4 position [[position]];
    float4 color;
    float2 cellUV;
    float2 cellSize [[flat]];
    uint cornerType [[flat]];
};

vertex ArcCornerVertexOut arc_corner_vertex(
    uint vertex_id [[vertex_id]],
    ArcCornerInstance in [[stage_in]],
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

    ArcCornerVertexOut out;
    out.position = uniforms.projectionMatrix * float4(origin + positions[vertex_id], 0.0, 1.0);
    out.color = float4(in.color) / 255.0;
    out.cellUV = positions[vertex_id];
    out.cellSize = size;
    out.cornerType = in.cornerType;
    return out;
}

// SDF to a line segment from a to b
inline float sdf_line_segment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

fragment float4 arc_corner_fragment(ArcCornerVertexOut in [[stage_in]]) {
    float2 size = in.cellSize;
    float2 uv = in.cellUV;

    float thickness = max(1.0, round(size.x / 8.0));
    float halfT = thickness * 0.5;
    float cx = floor(size.x * 0.5);
    float cy = floor(size.y * 0.5);
    float r = min(size.x, size.y) * 0.5;

    // Mirror coordinates so all corners look like ╭ (extends right + down).
    // qp: origin at cell center line crossing, positive toward the two edges.
    // edge: distance from center to the two cell edges.
    float2 qp;
    float2 edge;
    switch (in.cornerType) {
        case 0u: qp = float2(uv.x - cx, uv.y - cy); edge = float2(size.x - cx, size.y - cy); break;
        case 1u: qp = float2(cx - uv.x, uv.y - cy); edge = float2(cx,          size.y - cy); break;
        case 2u: qp = float2(cx - uv.x, cy - uv.y); edge = float2(cx,          cy);          break;
        default: qp = float2(uv.x - cx, cy - uv.y); edge = float2(size.x - cx, cy);          break;
    }

    // Canonical form (like Ghostty .br):
    //   Quarter circle: center at (r, r), radius r, arc from (0, r) to (r, 0)
    //   Vertical segment:   (0, r) → (0, edge.y)
    //   Horizontal segment: (r, 0) → (edge.x, 0)

    // SDF to vertical segment
    float distV = sdf_line_segment(qp, float2(0, r), float2(0, edge.y));

    // SDF to horizontal segment
    float distH = sdf_line_segment(qp, float2(r, 0), float2(edge.x, 0));

    // SDF to quarter-circle arc
    float2 d = qp - float2(r, r);
    float distArc;
    if (d.x <= 0.0 && d.y <= 0.0) {
        distArc = abs(length(d) - r);
    } else {
        // Outside arc quadrant — distance to nearest endpoint
        distArc = min(length(qp - float2(0, r)), length(qp - float2(r, 0)));
    }

    float dist = min(distArc, min(distV, distH));
    float alpha = smoothstep(halfT + 0.5, halfT - 0.5, dist);
    return float4(in.color.rgb * alpha, alpha);
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

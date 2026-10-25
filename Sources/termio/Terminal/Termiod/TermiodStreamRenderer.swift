import AppKit
import CoreText
import GhosttyVt
import Metal
import QuartzCore

/// Draws a `TermiodStreamTerminal` with Metal: cell backgrounds, decorations
/// and the cursor as solid rectangles, text as glyph sprites from one atlas.
///
/// libghostty-vt has no renderer of its own, so this is termio's, grown from
/// the phase 1 spike (`spike/vt-renderer`). Text is shaped per grapheme with
/// CoreText, which supplies font fallback for CJK and color emoji; runs across
/// cells, and with them ligatures, are not shaped.
@MainActor
final class TermiodStreamRenderer {
    struct Appearance: Equatable {
        var fontFamily: String
        /// Faces tried, in order, for a character the primary lacks, before
        /// CoreText's own fallback.
        var fallbackFamilies: [String]
        var fontSize: CGFloat
        var cursorStyle: CursorStyle
        var paddingX: CGFloat
        var paddingY: CGFloat
        var backgroundOpacity: CGFloat
    }

    enum CursorStyle: Equatable {
        case block, bar, underline, hollow
    }

    enum Failure: Error {
        case metal(String)
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let rectanglePipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    /// Only this renderer touches it; `nonisolated(unsafe)` lets `deinit` free it.
    nonisolated(unsafe) private let renderState: GhosttyRenderState
    private let builder: TermiodStreamFrameBuilder
    private(set) var atlas: TermiodGlyphAtlas
    private(set) var appearance: Appearance
    private var scale: CGFloat
    private let inFlight = DispatchSemaphore(value: 3)
    private var rectangles: [TermiodStreamRectangle] = []
    private var glyphs: [TermiodStreamGlyph] = []

    init(appearance: Appearance, scale: CGFloat) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.metal("no Metal device")
        }
        self.device = device
        self.queue = queue
        self.appearance = appearance
        self.scale = scale
        // Compiled from source at runtime: a SwiftPM resource bundle is the one
        // thing termio must never ship (AGENTS.md, "Dependencies").
        let library = try device.makeLibrary(source: streamShaderSource, options: nil)
        rectanglePipeline = try Self.pipeline(device, library, "rectangle_vertex", "rectangle_fragment")
        glyphPipeline = try Self.pipeline(device, library, "glyph_vertex", "glyph_fragment")
        var state: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &state) == GHOSTTY_SUCCESS, let state else {
            throw Failure.metal("ghostty_render_state_new failed")
        }
        renderState = state
        builder = try TermiodStreamFrameBuilder()
        atlas = try TermiodGlyphAtlas(device: device, appearance: appearance, scale: scale)
    }

    deinit {
        ghostty_render_state_free(renderState)
    }

    /// One cell in points, which is what a pane measures its viewport with.
    var cellSize: CGSize {
        CGSize(width: CGFloat(atlas.metrics.width) / scale, height: CGFloat(atlas.metrics.height) / scale)
    }

    /// Rebuilds the atlas when the font or the display's scale changed, and
    /// says whether the grid a pane holds may have changed — font or padding —
    /// so the caller can redeclare its viewport.
    func update(appearance: Appearance, scale: CGFloat) throws -> Bool {
        guard appearance != self.appearance || scale != self.scale else { return false }
        let paddingChanged = appearance.paddingX != self.appearance.paddingX
            || appearance.paddingY != self.appearance.paddingY
        let fontChanged = appearance.fontFamily != self.appearance.fontFamily
            || appearance.fallbackFamilies != self.appearance.fallbackFamilies
            || appearance.fontSize != self.appearance.fontSize
            || scale != self.scale
        self.appearance = appearance
        self.scale = scale
        if fontChanged {
            atlas = try TermiodGlyphAtlas(device: device, appearance: appearance, scale: scale)
            builder.invalidate()
        }
        return fontChanged || paddingChanged
    }

    /// Draws one frame into `layer` if the terminal changed since the last one,
    /// or `force` asks for it regardless (a resize, focus, or new appearance).
    func draw(_ terminal: TermiodStreamTerminal, into layer: CAMetalLayer, focused: Bool, force: Bool) throws {
        let changed = try prepare(terminal, focused: focused, force: force)
        guard changed || force else { return }
        // A frame the GPU cannot take yet is dropped, not queued: the next
        // tick draws the newer screen anyway.
        guard inFlight.wait(timeout: .now()) == .success else {
            builder.invalidate()
            return
        }
        guard let drawable = layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else {
            inFlight.signal()
            builder.invalidate()
            return
        }
        guard encode(into: buffer, texture: drawable.texture) else {
            inFlight.signal()
            return
        }
        buffer.present(drawable)
        let semaphore = inFlight
        buffer.addCompletedHandler { _ in semaphore.signal() }
        buffer.commit()
    }

    /// The whole screen drawn into an image of the given pixel size, for
    /// looking at a frame without a window — the renderer's own tests.
    func image(of terminal: TermiodStreamTerminal, width: Int, height: Int, focused: Bool = true) throws -> CGImage {
        _ = try prepare(terminal, focused: focused, force: true)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = queue.makeCommandBuffer(),
              encode(into: buffer, texture: texture)
        else { throw Failure.metal("offscreen frame") }
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { throw Failure.metal("offscreen image") }
        return image
    }

    private func prepare(_ terminal: TermiodStreamTerminal, focused: Bool, force: Bool) throws -> Bool {
        // Held by synchronized output: keep drawing what was built last.
        guard try terminal.capture(into: renderState) else { return false }
        // A forced frame may follow a terminal swap, after which no cached row
        // describes the screen.
        if force { builder.invalidate() }
        return try builder.build(
            from: renderState, atlas: atlas,
            cursorStyle: focused ? appearance.cursorStyle : .hollow
        )
    }

    private func encode(into buffer: MTLCommandBuffer, texture: MTLTexture) -> Bool {
        builder.flatten(rectangles: &rectangles, glyphs: &glyphs)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let background = builder.background
        let opacity = Double(appearance.backgroundOpacity)
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.r) / 255 * opacity, green: Double(background.g) / 255 * opacity,
            blue: Double(background.b) / 255 * opacity, alpha: opacity
        )
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = TermiodStreamUniforms(
            viewport: SIMD2(Float(texture.width), Float(texture.height)),
            cell: SIMD2(Float(atlas.metrics.width), Float(atlas.metrics.height)),
            atlas: SIMD2(Float(atlas.size), Float(atlas.size)),
            origin: SIMD2(Float(appearance.paddingX * scale).rounded(), Float(appearance.paddingY * scale).rounded())
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TermiodStreamUniforms>.stride, index: 1)
        // Rectangles carry their own pass order: backgrounds and the block
        // cursor go under the text, decorations and the thin cursors over it.
        drawRectangles(rectangles.filter { !$0.overText }, encoder: encoder)
        if !glyphs.isEmpty,
           let data = device.makeBuffer(bytes: glyphs, length: glyphs.count * MemoryLayout<TermiodStreamGlyph>.stride) {
            encoder.setRenderPipelineState(glyphPipeline)
            encoder.setVertexBuffer(data, offset: 0, index: 0)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }
        drawRectangles(rectangles.filter(\.overText), encoder: encoder)
        encoder.endEncoding()
        return true
    }

    private func drawRectangles(_ items: [TermiodStreamRectangle], encoder: MTLRenderCommandEncoder) {
        guard !items.isEmpty,
              let data = device.makeBuffer(bytes: items, length: items.count * MemoryLayout<TermiodStreamRectangle>.stride)
        else { return }
        encoder.setRenderPipelineState(rectanglePipeline)
        encoder.setVertexBuffer(data, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: items.count)
    }

    private static func pipeline(
        _ device: MTLDevice, _ library: MTLLibrary, _ vertex: String, _ fragment: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        guard let attachment = descriptor.colorAttachments[0] else { throw Failure.metal("no color attachment") }
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        // Every fragment is premultiplied.
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// Layouts shared with the shaders. Every field is 2 or 4 bytes wide and
/// 4-byte aligned in Metal, so Swift lays them out the same way.
struct TermiodStreamUniforms {
    var viewport: SIMD2<Float>
    var cell: SIMD2<Float>
    var atlas: SIMD2<Float>
    var origin: SIMD2<Float>
}

/// A solid rectangle inside a cell, in pixels from the cell's top-left.
struct TermiodStreamRectangle {
    var cellX: UInt16, cellY: UInt16
    var x: Int16, y: Int16
    var width: UInt16, height: UInt16
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    /// Not read by the shader.
    var overText: Bool = false
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

struct TermiodStreamGlyph {
    var cellX: UInt16, cellY: UInt16
    var atlasX: UInt16, atlasY: UInt16
    var atlasWidth: UInt16, atlasHeight: UInt16
    var offsetX: Int16, offsetY: Int16
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    /// 1 when the sprite carries its own color (emoji), so the shader keeps it.
    var colored: UInt32
}

private let streamShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float2 viewport; float2 cell; float2 atlas; float2 origin; };
struct Rectangle { ushort2 cell; short2 offset; ushort2 size; uchar4 color; uchar4 extra; };
struct Glyph { ushort2 cell; ushort2 atlasOrigin; ushort2 atlasSize; short2 offset; uchar4 color; uint colored; };
struct VertexOut { float4 position [[position]]; float2 uv; float4 color; uint colored [[flat]]; };

constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

static float4 clip(float2 pixel, float2 viewport) {
    return float4(pixel / viewport * float2(2, -2) + float2(-1, 1), 0, 1);
}

vertex VertexOut rectangle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  const device Rectangle* items [[buffer(0)]],
                                  constant Uniforms& u [[buffer(1)]]) {
    Rectangle r = items[iid];
    float2 pixel = u.origin + float2(r.cell) * u.cell + float2(r.offset) + corners[vid] * float2(r.size);
    VertexOut out;
    out.position = clip(pixel, u.viewport);
    out.uv = float2(0);
    out.color = float4(r.color) / 255.0;
    out.colored = 0;
    return out;
}

fragment float4 rectangle_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

vertex VertexOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Glyph* items [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
    Glyph g = items[iid];
    float2 size = float2(g.atlasSize);
    float2 pixel = u.origin + float2(g.cell) * u.cell + float2(g.offset) + corners[vid] * size;
    VertexOut out;
    out.position = clip(pixel, u.viewport);
    out.uv = (float2(g.atlasOrigin) + corners[vid] * size) / u.atlas;
    out.color = float4(g.color) / 255.0;
    out.colored = g.colored;
    return out;
}

fragment float4 glyph_fragment(VertexOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float4 texel = atlas.sample(s, in.uv);
    if (in.colored != 0) { return texel * in.color.a; }
    float coverage = texel.a * in.color.a;
    return float4(in.color.rgb * coverage, coverage);
}
"""

/// The pixel size of one cell and where the baseline and decorations sit in it.
struct TermiodCellMetrics: Equatable {
    var width: Int
    var height: Int
    var baseline: Int
    var underlinePosition: Int
    var underlineThickness: Int
    var strikethroughPosition: Int
}

/// Glyph sprites rasterized with CoreText into one premultiplied BGRA texture,
/// packed in shelves. A sprite is one grapheme in one face, so combining marks,
/// ZWJ emoji and fallback fonts all come out of CoreText's own line layout.
@MainActor
final class TermiodGlyphAtlas {
    struct Slot {
        var origin: SIMD2<UInt16>
        var size: SIMD2<UInt16>
        /// The sprite's top-left from the cell's top-left, in pixels.
        var offset: SIMD2<Int16>
        var colored: Bool
    }

    private struct Key: Hashable {
        var graphemes: [UInt32]
        var bold: Bool
        var italic: Bool
    }

    let texture: MTLTexture
    let metrics: TermiodCellMetrics
    let size: Int
    private let fonts: [CTFont]
    private var slots: [Key: Slot?] = [:]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private var exhausted = false
    /// Bumped each time the atlas is emptied to make room, which moves every
    /// sprite: anything built from an older generation must be rebuilt.
    private(set) var generation = 0

    init(device: MTLDevice, appearance: TermiodStreamRenderer.Appearance, scale: CGFloat, size: Int = 4096) throws {
        let pointSize = appearance.fontSize * scale
        let primary = Self.font(family: appearance.fontFamily, size: pointSize)
        let cascade = appearance.fallbackFamilies.map { family in
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        }
        let base = CTFontCreateCopyWithAttributes(
            primary, pointSize, nil,
            CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: cascade] as CFDictionary)
        )
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        }
        fonts = [base, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]

        var glyph = CGGlyph(0)
        var character: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(base, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(base)
        let descent = CTFontGetDescent(base)
        let leading = CTFontGetLeading(base)
        let height = Int((ascent + descent + leading).rounded(.up))
        let baseline = Int((ascent + leading / 2).rounded(.up))
        let thickness = max(1, Int(CTFontGetUnderlineThickness(base).rounded()))
        metrics = TermiodCellMetrics(
            width: max(1, Int(advance.width.rounded())),
            height: max(1, height),
            baseline: baseline,
            underlinePosition: min(height - thickness, baseline - Int(CTFontGetUnderlinePosition(base).rounded())),
            underlineThickness: thickness,
            strikethroughPosition: baseline - Int((CTFontGetXHeight(base) / 2).rounded())
        )
        self.size = size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TermiodStreamRenderer.Failure.metal("atlas texture")
        }
        self.texture = texture
    }

    private static func font(family: String, size: CGFloat) -> CTFont {
        if !family.isEmpty {
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            // CoreText answers an unknown family with its default face rather
            // than nil, which is not monospaced.
            if (CTFontCopyFamilyName(font) as String) == family { return font }
        }
        return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
    }

    /// The sprite for a grapheme, rasterized on first use. Nil for a grapheme
    /// with nothing to draw, or once the atlas is full.
    func slot(graphemes: [UInt32], bold: Bool, italic: Bool, cells: Int) -> Slot? {
        let key = Key(graphemes: graphemes, bold: bold, italic: italic)
        if let cached = slots[key] { return cached }
        var slot = rasterize(key, cells: cells)
        if slot == nil, exhausted {
            // Full: start over rather than stop drawing new characters. The
            // screen's own glyphs come back on the rebuild this triggers.
            slots.removeAll(keepingCapacity: true)
            shelfX = 0
            shelfY = 0
            shelfHeight = 0
            exhausted = false
            generation += 1
            slot = rasterize(key, cells: cells)
        }
        slots[key] = slot
        return slot
    }

    private func rasterize(_ key: Key, cells: Int) -> Slot? {
        var text = String.UnicodeScalarView()
        for codepoint in key.graphemes {
            guard let scalar = Unicode.Scalar(codepoint) else { return nil }
            text.append(scalar)
        }
        let font = fonts[(key.bold ? 1 : 0) + (key.italic ? 2 : 0)]
        let attributed = CFAttributedStringCreate(
            nil, String(text) as CFString,
            [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
        )
        guard let attributed else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let colored = Self.usesColorFont(line)
        let padding = 1
        let width = Int(bounds.width.rounded(.up)) + 2 * padding
        let height = Int(bounds.height.rounded(.up)) + 2 * padding
        guard let origin = allocate(width: width, height: height) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            context.textPosition = CGPoint(x: CGFloat(padding) - bounds.minX, y: CGFloat(padding) - bounds.minY)
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4
        )
        // CoreGraphics counts up from the bottom: the bitmap's top edge sits
        // maxY + padding above the baseline.
        var top = metrics.baseline - Int(bounds.maxY.rounded(.up)) - padding
        var left = Int(bounds.minX.rounded(.down)) - padding
        if colored {
            // An emoji is drawn at the font's size, which is taller than a cell
            // on most fonts; centring it in its cells keeps it off the rows
            // above and below.
            let span = metrics.width * max(1, cells)
            left = (span - width) / 2
            top = (metrics.height - height) / 2
        }
        return Slot(
            origin: SIMD2(UInt16(origin.x), UInt16(origin.y)),
            size: SIMD2(UInt16(width), UInt16(height)),
            offset: SIMD2(Int16(clamping: left), Int16(clamping: top)),
            colored: colored
        )
    }

    private static func usesColorFont(_ line: CTLine) -> Bool {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        return runs.contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else {
                return false
            }
            // Checked just above, so this cast cannot fail.
            let font = unsafeBitCast(value as CFTypeRef, to: CTFont.self)
            return CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        }
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        guard width <= size else { return nil }
        if shelfX + width > size {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        guard shelfY + height <= size else {
            exhausted = true
            return nil
        }
        let origin = (shelfX, shelfY)
        shelfX += width
        shelfHeight = max(shelfHeight, height)
        return origin
    }
}

/// Turns the render state into rectangles and glyphs, rebuilding only the rows
/// libghostty marked dirty.
@MainActor
final class TermiodStreamFrameBuilder {
    private(set) var background = GhosttyColorRgb(r: 0, g: 0, b: 0)
    private var rowRectangles: [[TermiodStreamRectangle]] = []
    private var rowGlyphs: [[TermiodStreamGlyph]] = []
    private var cursor: [TermiodStreamRectangle] = []
    private var cursorGlyph: TermiodStreamGlyph?
    private var cursorCell: (x: UInt16, y: UInt16)?
    nonisolated(unsafe) private var rowIterator: GhosttyRenderStateRowIterator?
    nonisolated(unsafe) private var cells: GhosttyRenderStateRowCells?
    private var codepoints = [UInt32](repeating: 0, count: 32)
    private var stale = true

    init() throws {
        guard ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS
        else { throw TermiodStreamRenderer.Failure.metal("render state iterators") }
    }

    deinit {
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_row_cells_free(cells)
    }

    /// The next build rebuilds every row: the atlas changed, or a frame built
    /// from the render state was never drawn and its dirt was already consumed.
    func invalidate() {
        stale = true
    }

    /// Returns false when nothing changed since the last build.
    func build(
        from state: GhosttyRenderState, atlas: TermiodGlyphAtlas,
        cursorStyle: TermiodStreamRenderer.CursorStyle
    ) throws -> Bool {
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var rows: UInt16 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        let full = stale || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || rowRectangles.count != Int(rows)
        var changed = false
        if full || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE {
            stale = false
            changed = true
            background = colors.background
            if rowRectangles.count != Int(rows) {
                rowRectangles = Array(repeating: [], count: Int(rows))
                rowGlyphs = Array(repeating: [], count: Int(rows))
            }
            let generation = atlas.generation
            rebuildRows(state, full: full, colors: colors, atlas: atlas)
            // The atlas was emptied to make room partway through, so rows
            // built before that point name sprites that are gone.
            if atlas.generation != generation {
                rebuildRows(state, full: true, colors: colors, atlas: atlas)
            }
            var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
            _ = ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)
        }
        // The cursor moves without dirtying any cell, so it is compared on
        // its own every frame.
        let cursorState = CursorState(state, colors: colors, style: cursorStyle)
        if changed || cursorState != lastCursorState {
            lastCursorState = cursorState
            buildCursor(cursorState, colors: colors, atlas: atlas)
            changed = true
        }
        return changed
    }

    private func rebuildRows(
        _ state: GhosttyRenderState, full: Bool, colors: GhosttyRenderStateColors, atlas: TermiodGlyphAtlas
    ) {
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        var y = 0
        while ghostty_render_state_row_iterator_next(rowIterator) {
            defer { y += 1 }
            guard y < rowRectangles.count else { break }
            var rowDirty = false
            _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
            guard full || rowDirty else { continue }
            rebuildRow(y, colors: colors, atlas: atlas)
            var clean = false
            _ = ghostty_render_state_row_set(rowIterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
        }
    }

    /// Everything the cursor's drawing depends on.
    private struct CursorState: Equatable {
        var x: UInt16 = 0
        var y: UInt16 = 0
        var shape: TermiodStreamRenderer.CursorStyle?
        var red: UInt8 = 0
        var green: UInt8 = 0
        var blue: UInt8 = 0

        init(_ state: GhosttyRenderState, colors: GhosttyRenderStateColors, style: TermiodStreamRenderer.CursorStyle) {
            var visible = false
            var hasValue = false
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &hasValue)
            guard visible, hasValue else { return }
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
            // The program's own choice (DECSCUSR) wins over the setting, as in
            // the embedded surface; an unfocused pane always shows the outline.
            var visual = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &visual)
            switch (style, visual) {
            case (.hollow, _): shape = .hollow
            case (_, GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR): shape = .bar
            case (_, GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE): shape = .underline
            case (_, GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW): shape = .hollow
            default: shape = style
            }
            let color = colors.cursor_has_value ? colors.cursor : colors.foreground
            red = color.r
            green = color.g
            blue = color.b
        }
    }

    private var lastCursorState: CursorState?

    private func rebuildRow(_ y: Int, colors: GhosttyRenderStateColors, atlas: TermiodGlyphAtlas) {
        var rectangles: [TermiodStreamRectangle] = []
        var glyphs: [TermiodStreamGlyph] = []
        let metrics = atlas.metrics
        _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
        var x: UInt16 = 0
        while ghostty_render_state_row_cells_next(cells) {
            defer { x &+= 1 }
            var raw: GhosttyCell = 0
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
            let span: UInt16 = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1

            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            var hasStyling = false
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
            if hasStyling {
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
            }
            var foreground = colors.foreground
            var background = colors.background
            var paintsBackground = false
            var resolved = GhosttyColorRgb()
            if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &resolved) == GHOSTTY_SUCCESS {
                foreground = resolved
            }
            if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &resolved) == GHOSTTY_SUCCESS {
                background = resolved
                paintsBackground = true
            }
            if style.inverse {
                swap(&foreground, &background)
                paintsBackground = true
            }
            if paintsBackground {
                rectangles.append(TermiodStreamRectangle(
                    cellX: x, cellY: UInt16(y), x: 0, y: 0,
                    width: UInt16(metrics.width) * span, height: UInt16(metrics.height),
                    r: background.r, g: background.g, b: background.b, a: 255
                ))
            }
            let alpha: UInt8 = style.faint ? 128 : 255
            if !style.invisible {
                appendDecorations(style, x: x, y: y, span: span, foreground: foreground, alpha: alpha,
                                  metrics: metrics, into: &rectangles)
            }

            var length: UInt32 = 0
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
            guard length > 0, !style.invisible else { continue }
            if Int(length) > codepoints.count {
                codepoints = [UInt32](repeating: 0, count: Int(length))
            }
            codepoints.withUnsafeMutableBufferPointer { buffer in
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buffer.baseAddress)
            }
            let grapheme = Array(codepoints.prefix(Int(length)))
            if grapheme == [0x20] { continue }
            guard let slot = atlas.slot(graphemes: grapheme, bold: style.bold, italic: style.italic, cells: Int(span)) else {
                continue
            }
            glyphs.append(TermiodStreamGlyph(
                cellX: x, cellY: UInt16(y),
                atlasX: slot.origin.x, atlasY: slot.origin.y,
                atlasWidth: slot.size.x, atlasHeight: slot.size.y,
                offsetX: slot.offset.x, offsetY: slot.offset.y,
                r: foreground.r, g: foreground.g, b: foreground.b, a: alpha,
                colored: slot.colored ? 1 : 0
            ))
        }
        rowRectangles[y] = rectangles
        rowGlyphs[y] = glyphs
    }

    private func appendDecorations(
        _ style: GhosttyStyle, x: UInt16, y: Int, span: UInt16,
        foreground: GhosttyColorRgb, alpha: UInt8, metrics: TermiodCellMetrics,
        into rectangles: inout [TermiodStreamRectangle]
    ) {
        let width = metrics.width * Int(span)
        let thickness = metrics.underlineThickness
        func line(_ top: Int, _ start: Int = 0, _ length: Int? = nil, color: GhosttyColorRgb = foreground) {
            rectangles.append(TermiodStreamRectangle(
                cellX: x, cellY: UInt16(y), x: Int16(clamping: start), y: Int16(clamping: top),
                width: UInt16(clamping: length ?? width), height: UInt16(clamping: thickness),
                r: color.r, g: color.g, b: color.b, a: alpha, overText: true
            ))
        }
        var underlineColor = foreground
        if style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB {
            underlineColor = style.underline_color.value.rgb
        }
        let position = metrics.underlinePosition
        switch Int32(style.underline) {
        case GHOSTTY_SGR_UNDERLINE_SINGLE.rawValue:
            line(position, color: underlineColor)
        case GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue:
            line(position, color: underlineColor)
            line(position - 2 * thickness, color: underlineColor)
        case GHOSTTY_SGR_UNDERLINE_CURLY.rawValue:
            // A square wave of half-cell steps, close enough at text size to
            // read as the squiggle an editor's diagnostics use.
            let step = max(1, metrics.width / 2)
            var start = 0
            var up = false
            while start < width {
                line(position - (up ? 2 * thickness : 0), start, min(step, width - start), color: underlineColor)
                start += step
                up.toggle()
            }
        case GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue:
            var start = 0
            while start < width {
                line(position, start, thickness, color: underlineColor)
                start += 2 * thickness
            }
        case GHOSTTY_SGR_UNDERLINE_DASHED.rawValue:
            let dash = max(2, metrics.width / 3)
            var start = 0
            while start < width {
                line(position, start, min(dash, width - start), color: underlineColor)
                start += 2 * dash
            }
        default:
            break
        }
        if style.strikethrough { line(metrics.strikethroughPosition) }
        if style.overline { line(0) }
    }

    private func buildCursor(_ state: CursorState, colors: GhosttyRenderStateColors, atlas: TermiodGlyphAtlas) {
        cursor = []
        cursorCell = nil
        guard let shape = state.shape else { return }
        let metrics = atlas.metrics
        let thickness = max(2, metrics.underlineThickness)
        func rectangle(_ left: Int, _ top: Int, _ width: Int, _ height: Int, overText: Bool) -> TermiodStreamRectangle {
            TermiodStreamRectangle(
                cellX: state.x, cellY: state.y, x: Int16(clamping: left), y: Int16(clamping: top),
                width: UInt16(clamping: width), height: UInt16(clamping: height),
                r: state.red, g: state.green, b: state.blue, a: 255, overText: overText
            )
        }
        let width = metrics.width
        let height = metrics.height
        switch shape {
        case .block:
            cursor = [rectangle(0, 0, width, height, overText: false)]
            cursorCell = (state.x, state.y)
        case .bar:
            cursor = [rectangle(0, 0, thickness, height, overText: true)]
        case .underline:
            cursor = [rectangle(0, height - thickness, width, thickness, overText: true)]
        case .hollow:
            cursor = [
                rectangle(0, 0, width, thickness, overText: true),
                rectangle(0, height - thickness, width, thickness, overText: true),
                rectangle(0, 0, thickness, height, overText: true),
                rectangle(width - thickness, 0, thickness, height, overText: true),
            ]
        }
        cursorBackground = colors.background
    }

    private var cursorBackground = GhosttyColorRgb(r: 0, g: 0, b: 0)

    func flatten(rectangles: inout [TermiodStreamRectangle], glyphs: inout [TermiodStreamGlyph]) {
        rectangles.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        for row in rowRectangles { rectangles.append(contentsOf: row) }
        rectangles.append(contentsOf: cursor)
        for (index, row) in rowGlyphs.enumerated() {
            for glyph in row {
                var glyph = glyph
                // Text under a block cursor is drawn in the background color,
                // so the character stays readable through it.
                if let cell = cursorCell, Int(cell.y) == index, glyph.cellX == cell.x, glyph.colored == 0 {
                    glyph.r = cursorBackground.r
                    glyph.g = cursorBackground.g
                    glyph.b = cursorBackground.b
                }
                glyphs.append(glyph)
            }
        }
    }
}

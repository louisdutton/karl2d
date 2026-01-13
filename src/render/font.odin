package render

import "core:os"
import "core:slice"
import fs "vendor:fontstash"

import vk "vulkan"

Font :: distinct int
Font_Data :: struct {
	atlas:            Texture,

	// internal
	fontstash_handle: int,
}

FONT_NONE :: Font{}
FONT_DEFAULT_ATLAS_SIZE :: 1024

// Loads a font from disk and returns a handle that represents it.
load_font_from_file :: proc(filename: string, allocator := context.allocator) -> Font {
	when !FILESYSTEM_SUPPORTED {
		log.errorf(
			"load_font_from_file failed: OS %v has no filesystem support! Tip: Use load_font_from_bytes(#load(\"the_font.ttf\")) instead.",
			ODIN_OS,
		)
		return {}
	}

	if data, data_ok := os.read_entire_file(filename, allocator); data_ok {
		return load_font_from_bytes(data)
	}

	return FONT_NONE
}

// Loads a font from a block of memory and returns a handle that represents it.
load_font_from_bytes :: proc(data: []u8) -> Font {
	font := fs.AddFontMem(&s.fs, "", data, false)
	h := Font(len(s.fonts))

	append(
		&s.fonts,
		Font_Data {
			fontstash_handle = font,
			atlas = {
				handle = vk.create_texture(
					FONT_DEFAULT_ATLAS_SIZE,
					FONT_DEFAULT_ATLAS_SIZE,
					.RGBA_8_Norm,
				),
				width = FONT_DEFAULT_ATLAS_SIZE,
				height = FONT_DEFAULT_ATLAS_SIZE,
			},
		},
	)

	return h
}

// Destroy a font previously loaded using `load_font_from_file` or `load_font_from_bytes`.
destroy_font :: proc(font: Font) {
	if int(font) >= len(s.fonts) {
		return
	}

	f := &s.fonts[font]
	vk.destroy_texture(f.atlas.handle)

	// TODO fontstash has no "destroy font" proc... I should make my own version of fontstash
	delete(s.fs.fonts[f.fontstash_handle].glyphs)
	s.fs.fonts[f.fontstash_handle].glyphs = {}
}

// Returns the built-in font of Karl2D (the font is known as "roboto")
get_default_font :: proc() -> Font {
	return s.default_font
}


// Tells you how much space some text of a certain size will use on the screen. The font used is the
// default font. The return value contains the width and height of the text.
measure_text :: proc(text: string, font_size: f32) -> Vec2 {
	return measure_text_ex(s.default_font, text, font_size)
}

// Tells you how much space some text of a certain size will use on the screen, using a custom font.
// The return value contains the width and height of the text.
measure_text_ex :: proc(font_handle: Font, text: string, font_size: f32) -> Vec2 {
	if font_handle < 0 || int(font_handle) >= len(s.fonts) {
		return {}
	}

	font := s.fonts[font_handle]

	// Temporary until I rewrite the font caching system.
	_set_font(font_handle)

	// TextBounds from fontstash, but fixed and simplified for my purposes.
	// The version in there is broken.
	TextBounds :: proc(ctx: ^fs.FontContext, font_idx: int, size: f32, text: string) -> Vec2 {
		font := fs.__getFont(ctx, font_idx)
		isize := i16(size * 10)

		x, y: f32
		max_x := x

		scale := fs.__getPixelHeightScale(font, f32(isize) / 10)
		previousGlyphIndex: fs.Glyph_Index = -1
		quad: fs.Quad
		lines := 1

		for codepoint in text {
			if codepoint == '\n' {
				x = 0
				lines += 1
				continue
			}

			if glyph, ok := fs.__getGlyph(ctx, font, codepoint, isize); ok {
				if glyph.xadvance > 0 {
					x += f32(int(f32(glyph.xadvance) / 10 + 0.5))
				} else {
					// updates x
					fs.__getQuad(ctx, font, previousGlyphIndex, glyph, scale, 0, &x, &y, &quad)
				}

				if x > max_x {
					max_x = x
				}

				previousGlyphIndex = glyph.index
			} else {
				previousGlyphIndex = -1
			}

		}
		return {max_x, f32(lines) * size}
	}

	return TextBounds(&s.fs, font.fontstash_handle, font_size, text)
}

// Draw text at a position with a size. This uses the default font. `pos` will be equal to the
// top-left position of the text.
draw_text :: proc(text: string, pos: Vec2, font_size: f32, color := BLACK) {
	draw_text_ex(s.default_font, text, pos, font_size, color)
}

// Draw text at a position with a size, using a custom font. `pos` will be equal to the  top-left
// position of the text.
draw_text_ex :: proc(font_handle: Font, text: string, pos: Vec2, font_size: f32, color := BLACK) {
	if int(font_handle) >= len(s.fonts) {
		return
	}

	_set_font(font_handle)
	font := &s.fonts[font_handle]
	fs.SetSize(&s.fs, font_size)
	iter := fs.TextIterInit(&s.fs, pos.x, pos.y, text)

	q: fs.Quad
	for fs.TextIterNext(&s.fs, &iter, &q) {
		if iter.codepoint == '\n' {
			iter.nexty += font_size
			iter.nextx = pos.x
			continue
		}

		if iter.codepoint == '\t' {
			// This is not really correct, but I'll replace it later when I redo the font stuff.
			iter.nextx += 2 * font_size
			continue
		}

		src := Rect{q.s0, q.t0, q.s1 - q.s0, q.t1 - q.t0}

		w := f32(FONT_DEFAULT_ATLAS_SIZE)
		h := f32(FONT_DEFAULT_ATLAS_SIZE)

		src.x *= w
		src.y *= h
		src.w *= w
		src.h *= h

		dst := Rect{q.x0, q.y0, q.x1 - q.x0, q.y1 - q.y0}

		draw_texture_ex(font.atlas, src, dst, {}, 0, color)
	}
}

_update_font :: proc(fh: Font, allocator := context.allocator) {
	font := &s.fonts[fh]
	font_dirty_rect: [4]f32

	tw := FONT_DEFAULT_ATLAS_SIZE

	if fs.ValidateTexture(&s.fs, &font_dirty_rect) {
		fdr := font_dirty_rect

		r := Rect{fdr[0], fdr[1], fdr[2] - fdr[0], fdr[3] - fdr[1]}

		x := int(r.x)
		y := int(r.y)
		w := int(fdr[2]) - int(fdr[0])
		h := int(fdr[3]) - int(fdr[1])

		expanded_pixels := make([]Color, w * h, allocator)
		start := x + tw * y

		for i in 0 ..< w * h {
			px := i % w
			py := i / w

			dst_pixel_idx := (px) + (py * w)
			src_pixel_idx := start + (px) + (py * tw)

			src := s.fs.textureData[src_pixel_idx]
			expanded_pixels[dst_pixel_idx] = {255, 255, 255, src}
		}

		vk.update_texture(font.atlas.handle, slice.reinterpret([]u8, expanded_pixels), r)
	}
}

// Not for direct use. Specify font to `draw_text_ex`
_set_font :: proc(fh: Font) {
	fh := fh

	if s.batch_font == fh {
		return
	}

	draw_current_batch()

	s.batch_font = fh

	if s.batch_font != FONT_NONE {
		_update_font(s.batch_font)
	}

	if fh == 0 {
		fh = s.default_font
	}

	font := &s.fonts[fh]
	fs.SetFont(&s.fs, font.fontstash_handle)
}

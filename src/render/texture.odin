package render

import hm "../handle_map"
import "../window"
import "core:image"
import "core:log"

// statically register image loaders by importing them
import "core:image/jpeg"
import "core:image/png"
_ :: png
_ :: jpeg

Texture_Handle :: distinct hm.Handle
TEXTURE_NONE :: Texture_Handle{}

// Create an empty texture.
create_texture :: proc(width: int, height: int, format: Pixel_Format) -> Texture {
	h := s.rb.create_texture(width, height, format)

	return {handle = h, width = width, height = height}
}

// Load a texture from disk and upload it to the GPU so you can draw it to the screen.
// Supports PNG, BMP, TGA and baseline PNG. Note that progressive PNG files are not supported!
//
// The `options` parameter can be used to specify things things such as premultiplication of alpha.
load_texture_from_file :: proc(
	filename: string,
	options: Load_Texture_Options = {},
	allocator := context.allocator,
) -> Texture {
	when FILESYSTEM_SUPPORTED {
		load_options := image.Options{.alpha_add_if_missing}

		if .Premultiply_Alpha in options {
			load_options += {.alpha_premultiply}
		}

		img, img_err := image.load_from_file(filename, load_options, allocator)
		if img_err != nil {
			log.errorf("Error loading texture '%v': %v", filename, img_err)
			return {}
		}

		return load_texture_from_bytes_raw(img.pixels.buf[:], img.width, img.height, .RGBA_8_Norm)
	} else {
		log.errorf(
			"load_texture_from_file failed: OS %v has no filesystem support! Tip: Use load_texture_from_bytes(#load(\"the_texture.png\")) instead.",
			ODIN_OS,
		)
		return {}
	}
}

// Load a texture from a byte slice and upload it to the GPU so you can draw it to the screen.
// Supports PNG, BMP, TGA and baseline PNG. Note that progressive PNG files are not supported!
//
// The `options` parameter can be used to specify things things such as premultiplication of alpha.
load_texture_from_bytes :: proc(
	bytes: []u8,
	options: Load_Texture_Options = {},
	allocator := context.allocator,
) -> Texture {
	load_options := image.Options{.alpha_add_if_missing}

	if .Premultiply_Alpha in options {
		load_options += {.alpha_premultiply}
	}

	img, img_err := image.load_from_bytes(bytes, load_options, allocator)
	if img_err != nil {
		log.errorf("Error loading texture: %v", img_err)
		return {}
	}

	return load_texture_from_bytes_raw(img.pixels.buf[:], img.width, img.height, .RGBA_8_Norm)
}

// Load raw texture data. You need to specify the data, size and format of the texture yourself.
// This assumes that there is no header in the data. If your data has a header (you read the data
// from a file on disk), then please use `load_texture_from_bytes` instead.
load_texture_from_bytes_raw :: proc(
	bytes: []u8,
	width: int,
	height: int,
	format: Pixel_Format,
) -> Texture {
	backend_tex := s.rb.load_texture(bytes[:], width, height, format)

	if backend_tex == TEXTURE_NONE {
		return {}
	}

	return {handle = backend_tex, width = width, height = height}
}

// Get a rectangle that spans the whole texture. Coordinates will be (x, y) = (0, 0) and size
// (w, h) = (texture_width, texture_height)
get_texture_rect :: proc(t: Texture) -> Rect {
	return {0, 0, f32(t.width), f32(t.height)}
}

// Update a texture with new pixels. `bytes` is the new pixel data. `rect` is the rectangle in
// `tex` where the new pixels should end up.
update_texture :: proc(tex: Texture, bytes: []u8, rect: Rect) -> bool {
	return s.rb.update_texture(tex.handle, bytes, rect)
}

// Destroy a texture, freeing up any memory it has used on the GPU.
destroy_texture :: proc(tex: Texture) {
	s.rb.destroy_texture(tex.handle)
}

// Controls how a texture should be filtered. You can choose "point" or "linear" filtering. Which
// means "pixly" or "smooth". This filter will be used for up and down-scaling as well as for
// mipmap sampling. Use `set_texture_filter_ex` if you need to control these settings separately.
set_texture_filter :: proc(t: Texture, filter: Texture_Filter) {
	set_texture_filter_ex(t, filter, filter, filter)
}

// Controls how a texture should be filtered. `scale_down_filter` and `scale_up_filter` controls how
// the texture is filtered when we render the texture at a smaller or larger size.
// `mip_filter` controls how the texture is filtered when it is sampled using _mipmapping_.
//
// TODO: Add mipmapping generation controls for texture and refer to it from here.
set_texture_filter_ex :: proc(
	t: Texture,
	scale_down_filter: Texture_Filter,
	scale_up_filter: Texture_Filter,
	mip_filter: Texture_Filter,
) {
	s.rb.set_texture_filter(t.handle, scale_down_filter, scale_up_filter, mip_filter)
}

//-----------------//
// RENDER TEXTURES //
//-----------------//

// Create a texture that you can render into. Meaning that you can draw into it instead of drawing
// onto the screen. Use `set_render_texture` to enable this Render Texture for drawing.
create_render_texture :: proc(width: int, height: int) -> Render_Texture {
	texture, render_target := s.rb.create_render_texture(width, height)

	return {
		texture = {handle = texture, width = width, height = height},
		render_target = render_target,
	}
}

// Destroy a Render_Texture previously created using `create_render_texture`.
destroy_render_texture :: proc(render_texture: Render_Texture) {
	s.rb.destroy_texture(render_texture.texture.handle)
	s.rb.destroy_render_target(render_texture.render_target)
}

// Make all rendering go into a texture instead of onto the screen. Create the render texture using
// `create_render_texture`. Pass `nil` to resume drawing onto the screen.
set_render_texture :: proc(render_texture: Maybe(Render_Texture), win: ^window.Interface) {
	if rt, rt_ok := render_texture.?; rt_ok {
		if s.batch_render_target == rt.render_target {
			return
		}

		draw_current_batch()
		s.batch_render_target = rt.render_target
		s.proj_matrix = make_default_projection(rt.texture.width, rt.texture.height)
	} else {
		if s.batch_render_target == RENDER_TARGET_NONE {
			return
		}

		draw_current_batch()
		s.batch_render_target = RENDER_TARGET_NONE
		s.proj_matrix = make_default_projection(win.get_width(), win.get_height())
	}
}

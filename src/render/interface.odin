package render

import hm "../handle_map"
import "../window"
import "base:runtime"

Render_Target_Handle :: distinct hm.Handle

RENDER_TARGET_NONE :: Render_Target_Handle{}
FILESYSTEM_SUPPORTED :: ODIN_OS != .JS && ODIN_OS != .Freestanding

Render_Backend_Interface :: struct {
	state_size:                     proc() -> int,
	init:                           proc(
		state: rawptr,
		window_handle: window.Handle,
		swapchain_width, swapchain_height: int,
		allocator := context.allocator,
	),
	shutdown:                       proc(),
	clear:                          proc(render_target: Render_Target_Handle, color: Color),
	present:                        proc(),
	draw:                           proc(
		shader: Shader,
		render_target: Render_Target_Handle,
		bound_textures: []Texture_Handle,
		scissor: Maybe(Rect),
		blend: Blend_Mode,
		vertex_buffer: []u8,
	),
	set_internal_state:             proc(state: rawptr),
	create_texture:                 proc(
		width: int,
		height: int,
		format: Pixel_Format,
	) -> Texture_Handle,
	load_texture:                   proc(
		data: []u8,
		width: int,
		height: int,
		format: Pixel_Format,
	) -> Texture_Handle,
	update_texture:                 proc(handle: Texture_Handle, data: []u8, rect: Rect) -> bool,
	destroy_texture:                proc(handle: Texture_Handle),
	texture_needs_vertical_flip:    proc(handle: Texture_Handle) -> bool,
	create_render_texture:          proc(
		width: int,
		height: int,
	) -> (
		Texture_Handle,
		Render_Target_Handle,
	),
	destroy_render_target:          proc(render_texture: Render_Target_Handle),
	set_texture_filter:             proc(
		handle: Texture_Handle,
		scale_down_filter: Texture_Filter,
		scale_up_filter: Texture_Filter,
		mip_filter: Texture_Filter,
	),
	load_shader:                    proc(
		vertex_shader_data: []byte,
		pixel_shader_data: []byte,
		desc_allocator: runtime.Allocator,
		layout_formats: []Pixel_Format = {},
	) -> (
		handle: Shader_Handle,
		desc: Shader_Desc,
	),
	destroy_shader:                 proc(shader: Shader_Handle),
	resize_swapchain:               proc(width, height: int),
	get_swapchain_width:            proc() -> int,
	get_swapchain_height:           proc() -> int,
	default_shader_vertex_source:   proc() -> []byte,
	default_shader_fragment_source: proc() -> []byte,
}

Texture :: struct {
	// The render-backend specific texture identifier.
	handle: Texture_Handle,

	// The horizontal size of the texture, measured in pixels.
	width:  int,

	// The vertical size of the texture, measure in pixels.
	height: int,
}

Load_Texture_Option :: enum {
	// Will multiply the alpha value of the each pixel into the its RGB values. Useful if you want
	// to use `set_blend_mode(.Premultiplied_Alpha)`
	Premultiply_Alpha,
}

Load_Texture_Options :: bit_set[Load_Texture_Option]

Blend_Mode :: enum {
	Alpha,

	// Requires the alpha-channel to be multiplied into texture RGB channels. You can automatically
	// do this using the `Premultiply_Alpha` option when loading a texture.
	Premultiplied_Alpha,
}

// A render texture is a texture that you can draw into, instead of drawing to the screen. Create
// one using `create_render_texture`.
Render_Texture :: struct {
	// The texture that the things will be drawn into. You can use this as a normal texture, for
	// example, you can pass it to `draw_texture`.
	texture:       Texture,

	// The render backend's internal identifier. It describes how to use the texture as something
	// the render backend can draw into.
	render_target: Render_Target_Handle,
}

Texture_Filter :: enum {
	Point, // Similar to "nearest neighbor". Pixly texture scaling.
	Linear, // Smoothed texture scaling.
}

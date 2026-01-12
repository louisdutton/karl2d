package render

import "../window"
import "base:runtime"
import "core:log"
import "core:mem"
import "core:slice"
import fs "vendor:fontstash"

VERTEX_BUFFER_MAX :: 1_000_000

State :: struct {
	shape_drawing_texture:  Texture_Handle,
	batch_camera:           Maybe(Camera),
	batch_shader:           Shader,
	batch_scissor:          Maybe(Rect),
	batch_texture:          Texture_Handle,
	batch_render_target:    Render_Target_Handle,
	batch_blend_mode:       Blend_Mode,
	view_matrix:            Mat4,
	proj_matrix:            Mat4,
	vertex_buffer_cpu:      []u8,
	vertex_buffer_cpu_used: int,
	default_shader:         Shader,

	// backend
	rb:                     Render_Backend_Interface,
	rb_state:               rawptr,

	// fonts
	fs:                     fs.FontContext,
	default_font:           Font,
	batch_font:             Font,
	fonts:                  [dynamic]Font_Data,
}

@(private)
s: State

// Choose how the alpha channel is used when mixing half-transparent color with what is already
// drawn. The default is the .Alpha mode, but you also have the option of using .Premultiply_Alpha.
set_blend_mode :: proc(mode: Blend_Mode) {
	if s.batch_blend_mode == mode {
		return
	}

	draw_current_batch()
	s.batch_blend_mode = mode
}

init :: proc(win: ^window.Interface, allocator := context.allocator, loc := #caller_location) {
	// camera
	s.proj_matrix = make_default_projection(win.get_width(), win.get_height())
	s.view_matrix = 1

	// backend
	s.rb = RENDER_BACKEND_GL
	rb_alloc_error: runtime.Allocator_Error
	s.rb_state, rb_alloc_error = mem.alloc(s.rb.state_size(), allocator = allocator)
	log.assertf(
		rb_alloc_error == nil, // .NONE ???
		"Failed allocating memory for rendering backend: %v",
		rb_alloc_error,
	)
	s.rb.init(s.rb_state, win.window_handle(), win.get_width(), win.get_height(), allocator)

	// The vertex buffer is created in a render backend-independent way. It is passed to the
	// render backend each frame as part of `draw_current_batch()`
	s.vertex_buffer_cpu = make([]u8, VERTEX_BUFFER_MAX, allocator, loc)

	// The shapes drawing texture is sampled when any shape is drawn. This way we can use the same
	// shader for textured drawing and shape drawing. It's just a white box.
	white_rect: [16 * 16 * 4]u8
	slice.fill(white_rect[:], 255)
	s.shape_drawing_texture = s.rb.load_texture(white_rect[:], 16, 16, .RGBA_8_Norm)

	// The default shader will arrive in a different format depending on backend. GLSL for GL,
	// HLSL for d3d etc.
	s.default_shader = load_shader_from_bytes(
		s.rb.default_shader_vertex_source(),
		s.rb.default_shader_fragment_source(),
	)
	s.batch_shader = s.default_shader

	// FontStash enables us to bake fonts from TTF files on-the-fly.
	fs.Init(&s.fs, FONT_DEFAULT_ATLAS_SIZE, FONT_DEFAULT_ATLAS_SIZE, .TOPLEFT)
	fs.SetAlignVertical(&s.fs, .TOP)

	// Dummy element so font with index 0 means 'no font'.
	append_nothing(&s.fonts)

	s.default_font = load_font_from_bytes(#load("fonts/roboto.ttf"))
	_set_font(s.default_font)
}


fini :: proc(allocator := context.allocator) {
	destroy_font(s.default_font)
	s.rb.destroy_texture(s.shape_drawing_texture)
	destroy_shader(s.default_shader)
	s.rb.shutdown()
	delete(s.vertex_buffer_cpu, allocator)
	free(s.rb_state, allocator)
	fs.Destroy(&s.fs)
	delete(s.fonts)
}

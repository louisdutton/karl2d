package render

import p "../primatives"

Vec2 :: p.Vec2
Vec3 :: p.Vec3
Vec4 :: p.Vec4
Rect :: p.Rect
Mat4 :: p.Mat4

// Make everything outside of the screen-space rectangle `scissor_rect` not render. Disable the
// scissor rectangle by running `set_scissor_rect(nil)`.
set_scissor_rect :: proc(scissor_rect: Maybe(Rect)) {
	draw_current_batch()
	s.batch_scissor = scissor_rect
}

// Clear the "screen" with the supplied color. By default this will clear your window. But if you
// have set a Render Texture using the `set_render_texture` procedure, then that Render Texture will
// be cleared instead.
clear :: proc(color := LIGHT_BLUE) {
	draw_current_batch()
	s.rb.clear(s.batch_render_target, color)
}


// Present the drawn stuff to the player. Also known as "flipping the backbuffer": Call at end of
// frame to make everything you've drawn appear on the screen.
//
// When you draw using for example `draw_texture`, then that stuff is drawn to an invisible texture
// called a "backbuffer". This makes sure that we don't see half-drawn frames. So when you are happy
// with a frame and want to show it to the player, call this procedure.
//
// WebGL note: WebGL does the backbuffer flipping automatically. But you should still call this to
// make sure that all rendering has been sent off to the GPU (as it calls `draw_current_batch()`).
present :: proc() {
	draw_current_batch()
	s.rb.present()
}

// TODO: doc
resize :: proc(width, height: int) {
	s.rb.resize_swapchain(width, height)
	s.proj_matrix = make_default_projection(width, height)
}

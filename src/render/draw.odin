package render

import "core:math"
import "core:math/linalg"

// Draw a colored rectangle. The rectangles have their (x, y) position in the top-left corner of the
// rectangle.
draw_rect :: proc(r: Rect, c: Color) {
	if s.vertex_buffer_cpu_used + s.batch_shader.vertex_size * 6 > len(s.vertex_buffer_cpu) {
		draw_current_batch()
	}

	if s.batch_texture != s.shape_drawing_texture {
		draw_current_batch()
	}

	s.batch_texture = s.shape_drawing_texture

	z := f32(0)

	batch_vertex({r.x, r.y}, {0, 0}, c)
	batch_vertex({r.x + r.w, r.y}, {1, 0}, c)
	batch_vertex({r.x + r.w, r.y + r.h}, {1, 1}, c)
	batch_vertex({r.x, r.y}, {0, 0}, c)
	batch_vertex({r.x + r.w, r.y + r.h}, {1, 1}, c)
	batch_vertex({r.x, r.y + r.h}, {0, 1}, c)
}

// Creates a rectangle from a position and a size and draws it.
draw_rect_vec :: proc(pos: Vec2, size: Vec2, c: Color) {
	draw_rect({pos.x, pos.y, size.x, size.y}, c)
}

// Draw a rectangle with a custom origin and rotation.
//
// The origin says which point the rotation rotates around. If the origin is `(0, 0)`, then the
// rectangle rotates around the top-left corner of the rectangle. If it is `(rect.w/2, rect.h/2)`
// then the rectangle rotates around its center.
//
// Rotation unit: Radians.
draw_rect_ex :: proc(r: Rect, origin: Vec2, rot: f32, c: Color) {
	if s.vertex_buffer_cpu_used + s.batch_shader.vertex_size * 6 > len(s.vertex_buffer_cpu) {
		draw_current_batch()
	}

	if s.batch_texture != s.shape_drawing_texture {
		draw_current_batch()
	}

	s.batch_texture = s.shape_drawing_texture
	tl, tr, bl, br: Vec2

	// Rotation adapted from Raylib's "DrawTexturePro"
	if rot == 0 {
		x := r.x - origin.x
		y := r.y - origin.y
		tl = {x, y}
		tr = {x + r.w, y}
		bl = {x, y + r.h}
		br = {x + r.w, y + r.h}
	} else {
		sin_rot := math.sin(rot)
		cos_rot := math.cos(rot)
		x := r.x
		y := r.y
		dx := -origin.x
		dy := -origin.y

		tl = {x + dx * cos_rot - dy * sin_rot, y + dx * sin_rot + dy * cos_rot}

		tr = {x + (dx + r.w) * cos_rot - dy * sin_rot, y + (dx + r.w) * sin_rot + dy * cos_rot}

		bl = {x + dx * cos_rot - (dy + r.h) * sin_rot, y + dx * sin_rot + (dy + r.h) * cos_rot}

		br = {
			x + (dx + r.w) * cos_rot - (dy + r.h) * sin_rot,
			y + (dx + r.w) * sin_rot + (dy + r.h) * cos_rot,
		}
	}

	batch_vertex(tl, {0, 0}, c)
	batch_vertex(tr, {1, 0}, c)
	batch_vertex(br, {1, 1}, c)
	batch_vertex(tl, {0, 0}, c)
	batch_vertex(br, {1, 1}, c)
	batch_vertex(bl, {0, 1}, c)
}

// Draw the outline of a rectangle with a specific thickness. The outline is drawn using four
// rectangles.
draw_rect_outline :: proc(r: Rect, thickness: f32, color: Color) {
	t := thickness

	// Based on DrawRectangleLinesEx from Raylib

	top := Rect{r.x, r.y, r.w, t}

	bottom := Rect{r.x, r.y + r.h - t, r.w, t}

	left := Rect{r.x, r.y + t, t, r.h - t * 2}

	right := Rect{r.x + r.w - t, r.y + t, t, r.h - t * 2}

	draw_rect(top, color)
	draw_rect(bottom, color)
	draw_rect(left, color)
	draw_rect(right, color)
}

// Draw a circle with a certain center and radius. Note the `segments` parameter: This circle is not
// perfect! It is drawn using a number of "cake segments".
draw_circle :: proc(center: Vec2, radius: f32, color: Color, segments := 16) {
	if s.vertex_buffer_cpu_used + s.batch_shader.vertex_size * 3 * segments >
	   len(s.vertex_buffer_cpu) {
		draw_current_batch()
	}

	if s.batch_texture != s.shape_drawing_texture {
		draw_current_batch()
	}

	s.batch_texture = s.shape_drawing_texture

	prev := center + {radius, 0}
	for s in 1 ..= segments {
		sr := (f32(s) / f32(segments)) * 2 * math.PI
		rot := linalg.matrix2_rotate(sr)
		p := center + rot * Vec2{radius, 0}

		batch_vertex(prev, {0, 0}, color)
		batch_vertex(p, {1, 0}, color)
		batch_vertex(center, {1, 1}, color)

		prev = p
	}
}

// Like `draw_circle` but only draws the outer edge of the circle.
draw_circle_outline :: proc(
	center: Vec2,
	radius: f32,
	thickness: f32,
	color: Color,
	segments := 16,
) {
	prev := center + {radius, 0}
	for s in 1 ..= segments {
		sr := (f32(s) / f32(segments)) * 2 * math.PI
		rot := linalg.matrix2_rotate(sr)
		p := center + rot * Vec2{radius, 0}
		draw_line(prev, p, thickness, color)
		prev = p
	}
}

// Draws a line from `start` to `end` of a certain thickness.
draw_line :: proc(start: Vec2, end: Vec2, thickness: f32, color: Color) {
	p := Vec2{start.x, start.y}
	s := Vec2{linalg.length(end - start), thickness}

	origin := Vec2{0, thickness * 0.5}
	r := Rect{p.x, p.y, s.x, s.y}

	rot := math.atan2(end.y - start.y, end.x - start.x)

	draw_rect_ex(r, origin, rot, color)
}

// Draw a texture at a specific position. The texture will be drawn with its top-left corner at
// position `pos`.
//
// Load textures using `load_texture_from_file` or `load_texture_from_bytes`.
draw_texture :: proc(tex: Texture, pos: Vec2, tint := WHITE) {
	draw_texture_ex(
		tex,
		{0, 0, f32(tex.width), f32(tex.height)},
		{pos.x, pos.y, f32(tex.width), f32(tex.height)},
		{},
		0,
		tint,
	)
}

// Draw a section of a texture at a specific position. `rect` is a rectangle measured in pixels. It
// tells the procedure which part of the texture to display. The texture will be drawn with its
// top-left corner at position `pos`.
draw_texture_rect :: proc(tex: Texture, rect: Rect, pos: Vec2, tint := WHITE) {
	draw_texture_ex(tex, rect, {pos.x, pos.y, rect.w, rect.h}, {}, 0, tint)
}

// Draw a texture by taking a section of the texture specified by `src` and draw it into the area of
// the screen specified by `dst`. You can also rotate the texture around an origin point of your
// choice.
//
// Tip: Use `k2.get_texture_rect(tex)` for `src` if you want to draw the whole texture.
//
// Rotation unit: Radians.
draw_texture_ex :: proc(
	tex: Texture,
	src: Rect,
	dst: Rect,
	origin: Vec2,
	rotation: f32,
	tint := WHITE,
) {
	if tex.width == 0 || tex.height == 0 {
		return
	}

	if s.vertex_buffer_cpu_used + s.batch_shader.vertex_size * 6 > len(s.vertex_buffer_cpu) {
		draw_current_batch()
	}

	if s.batch_texture != tex.handle {
		draw_current_batch()
	}

	s.batch_texture = tex.handle

	flip_x, flip_y: bool
	src := src
	dst := dst

	if src.w < 0 {
		flip_x = true
		src.w = -src.w
	}

	if src.h < 0 {
		flip_y = true
		src.h = -src.h
	}

	if dst.w < 0 {
		dst.w *= -1
	}

	if dst.h < 0 {
		dst.h *= -1
	}

	tl, tr, bl, br: Vec2

	// Rotation adapted from Raylib's "DrawTexturePro"
	if rotation == 0 {
		x := dst.x - origin.x
		y := dst.y - origin.y
		tl = {x, y}
		tr = {x + dst.w, y}
		bl = {x, y + dst.h}
		br = {x + dst.w, y + dst.h}
	} else {
		sin_rot := math.sin(rotation)
		cos_rot := math.cos(rotation)
		x := dst.x
		y := dst.y
		dx := -origin.x
		dy := -origin.y

		tl = {x + dx * cos_rot - dy * sin_rot, y + dx * sin_rot + dy * cos_rot}

		tr = {x + (dx + dst.w) * cos_rot - dy * sin_rot, y + (dx + dst.w) * sin_rot + dy * cos_rot}

		bl = {x + dx * cos_rot - (dy + dst.h) * sin_rot, y + dx * sin_rot + (dy + dst.h) * cos_rot}

		br = {
			x + (dx + dst.w) * cos_rot - (dy + dst.h) * sin_rot,
			y + (dx + dst.w) * sin_rot + (dy + dst.h) * cos_rot,
		}
	}

	ts := Vec2{f32(tex.width), f32(tex.height)}
	up := Vec2{src.x, src.y} / ts
	us := Vec2{src.w, src.h} / ts
	c := tint

	uv0 := up
	uv1 := up + {us.x, 0}
	uv2 := up + us
	uv3 := up
	uv4 := up + us
	uv5 := up + {0, us.y}

	if flip_x {
		uv0.x += us.x
		uv1.x -= us.x
		uv2.x -= us.x
		uv3.x += us.x
		uv4.x -= us.x
		uv5.x += us.x
	}

	// HACK: We ask the render backend if this texture needs flipping. The idea is that GL will
	// flip render textures, so we need to automatically unflip them.
	//
	// Could we do something with the projection matrix while drawing into those render textures
	// instead? I tried that, but couldn't get it to work.
	if s.rb.texture_needs_vertical_flip(tex.handle) {
		flip_y = !flip_y
	}

	if flip_y {
		uv0.y += us.y
		uv1.y += us.y
		uv2.y -= us.y
		uv3.y += us.y
		uv4.y -= us.y
		uv5.y -= us.y
	}

	batch_vertex(tl, uv0, c)
	batch_vertex(tr, uv1, c)
	batch_vertex(br, uv2, c)
	batch_vertex(tl, uv3, c)
	batch_vertex(br, uv4, c)
	batch_vertex(bl, uv5, c)
}

// Flushes the current batch. This sends off everything to the GPU that has been queued in the
// current batch. Normally, you do not need to do this manually. It is done automatically when these
// procedures run:
//
// - present
// - set_camera
// - set_shader
// - set_shader_constant
// - set_scissor_rect
// - set_blend_mode
// - set_render_texture
// - clear
// - draw_texture_* IF previous draw did not use the same texture (1)
// - draw_rect_*, draw_circle_*, draw_line IF previous draw did not use the shapes drawing texture (2)
//
// (1) When drawing textures, the current texture is fed into the active shader. Everything within
//     the same batch must use the same texture. So drawing with a new texture forces the current to
//     be drawn. You can combine several textures into an atlas to get bigger batches.
//
// (2) In order to use the same shader for shapes drawing and textured drawing, the shapes drawing
//     uses a blank, white texture. For the same reasons as (1), drawing something else than shapes
//     before drawing a shape will break up the batches. In a future update I'll add so that you can
//     set your own shapes drawing texture, making it possible to combine it with a bigger atlas.
//
// The batch has maximum size of VERTEX_BUFFER_MAX bytes. The shader dictates how big a vertex is
// so the maximum number of vertices that can be drawn in each batch is
// VERTEX_BUFFER_MAX / shader.vertex_size
draw_current_batch :: proc() {
	if s.vertex_buffer_cpu_used == 0 {
		return
	}

	_update_font(s.batch_font)

	shader := s.batch_shader

	view_projection := s.proj_matrix * s.view_matrix
	for mloc, builtin in shader.constant_builtin_locations {
		constant, constant_ok := mloc.?

		if !constant_ok {
			continue
		}

		switch builtin {
		case .View_Projection_Matrix:
			if constant.size == size_of(view_projection) {
				dst := (^matrix[4, 4]f32)(&shader.constants_data[constant.offset])
				dst^ = view_projection
			}
		}
	}

	if def_tex_idx, has_def_tex_idx := shader.default_texture_index.?; has_def_tex_idx {
		shader.texture_bindpoints[def_tex_idx] = s.batch_texture
	}

	s.rb.draw(
		shader,
		s.batch_render_target,
		shader.texture_bindpoints,
		s.batch_scissor,
		s.batch_blend_mode,
		s.vertex_buffer_cpu[:s.vertex_buffer_cpu_used],
	)
	s.vertex_buffer_cpu_used = 0
}

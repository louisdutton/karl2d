package render

import "../window"
import "core:math/linalg"

Camera :: struct {
	// Where the camera looks.
	target:   Vec2,

	// By default `target` will be the position of the upper-left corner of the camera. Use this
	// offset to change that. If you set the offset to half the size of the camera view, then the
	// target position will end up in the middle of the scren.
	offset:   Vec2,

	// Rotate the camera (unit: radians)
	rotation: f32,

	// Zoom the camera. A bigger value means "more zoom".
	//
	// To make a certain amount of pixels always occupy the height of the camera, set the zoom to:
	//
	//     k2.get_screen_height()/wanted_pixel_height
	zoom:     f32,
}


// Make Karl2D use a camera. Return to the "default camera" by passing `nil`. All drawing operations
// will use this camera until you again change it.
set_camera :: proc(camera: Maybe(Camera), win: window.Interface) {
	if camera == s.batch_camera {
		return
	}

	draw_current_batch()
	s.batch_camera = camera
	s.proj_matrix = make_default_projection(win.get_width(), win.get_height())

	if c, c_ok := camera.?; c_ok {
		s.view_matrix = get_camera_view_matrix(c)
	} else {
		s.view_matrix = 1
	}
}

// Transform a point `pos` that lives on the screen to a point in the world. This can be useful for
// bringing (for example) mouse positions (k2.get_mouse_position()) into world-space.
screen_to_world :: proc(pos: Vec2, camera: Camera) -> Vec2 {
	return (get_camera_world_matrix(camera) * Vec4{pos.x, pos.y, 0, 1}).xy
}

// Transform a point `pos` that lices in the world to a point on the screen. This can be useful when
// you need to take a position in the world and compare it to a screen-space point.
world_to_screen :: proc(pos: Vec2, camera: Camera) -> Vec2 {
	return (get_camera_view_matrix(camera) * Vec4{pos.x, pos.y, 0, 1}).xy
}

// Get the matrix that `screen_to_world` and `world_to_screen` uses to do their transformations.
//
// A view matrix is essentially the world transform matrix of the camera, but inverted. In other
// words, instead of bringing the camera in front of things in the world, we bring everything in the
// world "in front of the camera".
//
// Instead of constructing the camera matrix and doing a matrix inverse, here we just do the
// maths in "backwards order". I.e. a camera transform matrix would be:
//
//    target_translate * rot * scale * offset_translate
//
// but we do
//
//    inv_offset_translate * inv_scale * inv_rot * inv_target_translate
//
// This is faster, since matrix inverses are expensive.
//
// The view matrix is a Mat4 because its easier to upload a Mat4 to the GPU. But only the upper-left
// 3x3 matrix is actually used.
get_camera_view_matrix :: proc(c: Camera) -> Mat4 {
	inv_target_translate := linalg.matrix4_translate(vec3_from_vec2(-c.target))
	inv_rot := linalg.matrix4_rotate_f32(c.rotation, {0, 0, 1})
	inv_scale := linalg.matrix4_scale(Vec3{c.zoom, c.zoom, 1})
	inv_offset_translate := linalg.matrix4_translate(vec3_from_vec2(c.offset))

	return inv_offset_translate * inv_scale * inv_rot * inv_target_translate
}

// Get the matrix that brings something in front of the camera.
get_camera_world_matrix :: proc(c: Camera) -> Mat4 {
	offset_translate := linalg.matrix4_translate(vec3_from_vec2(-c.offset))
	rot := linalg.matrix4_rotate_f32(-c.rotation, {0, 0, 1})
	scale := linalg.matrix4_scale(Vec3{1 / c.zoom, 1 / c.zoom, 1})
	target_translate := linalg.matrix4_translate(vec3_from_vec2(c.target))

	return target_translate * rot * scale * offset_translate
}


@(require_results)
matrix_ortho3d_f32 :: proc "contextless" (
	left, right, bottom, top, near, far: f32,
) -> Mat4 #no_bounds_check {
	m: Mat4

	m[0, 0] = +2 / (right - left)
	m[1, 1] = +2 / (top - bottom)
	m[2, 2] = +1
	m[0, 3] = -(right + left) / (right - left)
	m[1, 3] = -(top + bottom) / (top - bottom)
	m[2, 3] = 0
	m[3, 3] = 1

	return m
}

make_default_projection :: proc(w, h: int) -> matrix[4, 4]f32 {
	return matrix_ortho3d_f32(0, f32(w), f32(h), 0, 0.001, 2)
}

vec3_from_vec2 :: proc(v: Vec2) -> Vec3 {
	return {v.x, v.y, 0}
}

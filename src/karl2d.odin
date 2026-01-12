#+vet explicit-allocators

package karl2d

import "base:runtime"
import "core:log"
import "core:mem"
import "core:time"
import "primatives"
import "render"
import "window"

//-----------------------------------------------//
// SETUP, WINDOW MANAGEMENT AND FRAME MANAGEMENT //
//-----------------------------------------------//

// Opens a window and initializes some internal state. The internal state will use `allocator` for
// all dynamically allocated memory. The return value can be ignored unless you need to later call
// `set_internal_state`.
//
// `screen_width` and `screen_height` refer to the the resolution of the drawable area of the
// window. The window might be slightly larger due borders and headers.
init :: proc(
	screen_width: int,
	screen_height: int,
	window_title: string,
	options := window.Init_Options{},
	allocator := context.allocator,
	loc := #caller_location,
) -> ^State {
	assert(s == nil, "Don't call 'init' twice.")
	context.allocator = allocator

	s = new(State, allocator, loc)
	s.allocator = allocator
	s.win = window.WINDOW_INTERFACE_X11

	// We alloc memory for the windowing backend and pass the blob of memory to it.
	window_state_alloc_error: runtime.Allocator_Error
	s.window_state, window_state_alloc_error = mem.alloc(s.win.state_size(), allocator = allocator)
	log.assertf(
		window_state_alloc_error == nil,
		"Failed allocating memory for window state: %v",
		window_state_alloc_error,
	)

	s.win.init(s.window_state, screen_width, screen_height, window_title, options, allocator)
	s.window = s.win.window_handle()

	render.init(&s.win, context.allocator)

	return s
}

// Updates the internal state of the library. Call this early in the frame to make sure inputs and
// frame times are up-to-date.
//
// Returns a bool that says if the player has attempted to close the window. It's up to the
// application to decide if it wants to shut down or if it (for example) wants to show a
// confirmation dialogue.
//
// Commonly used for creating the "main loop" of a game: `for k2.update() {}`
//
// To get more control over how the frame is set up, you can skip calling this proc and instead use
// the procs it calls directly:
//
//// for {
////     k2.reset_frame_allocator()
////     k2.calculate_frame_time()
////     k2.process_events()
////
////     k2.clear(k2.BLUE)
////     k2.present()
////
////     if k2.close_window_requested() {
////         break
////     }
//// }
update :: proc() -> bool {
	calculate_frame_time()
	process_events()
	return !close_window_requested()
}

// Returns true the user has pressed the close button on the window, or used a key stroke such as
// ALT+F4 on Windows. The application can decide if it wants to shut down or if it wants to show
// some kind of confirmation dialogue.
//
// Called by `update`, but can be called manually if you need more control.
close_window_requested :: proc() -> bool {
	return s.close_window_requested
}

// Closes the window and cleans up Karl2D's internal state.
fini :: proc() {
	assert(s != nil, "You've called 'shutdown' without calling 'init' first")
	context.allocator = s.allocator

	render.fini(context.allocator)

	s.win.shutdown()

	a := s.allocator
	free(s.window_state, a)
	free(s, a)
	s = nil
}

// Calculates how long the previous frame took and how it has been since the application started.
// You can fetch the calculated values using `get_frame_time` and `get_time`.
//
// Called as part of `update`, but can be called manually if you need more control.
calculate_frame_time :: proc() {
	now := time.now()

	if s.prev_frame_time != {} {
		since := time.diff(s.prev_frame_time, now)
		s.frame_time = f32(time.duration_seconds(since))
	}

	s.prev_frame_time = now

	if s.start_time == {} {
		s.start_time = time.now()
	}

	s.time = time.duration_seconds(time.since(s.start_time))
}

// Returns how many seconds the previous frame took. Often a tiny number such as 0.016 s.
//
// This value is updated when `calculate_frame_time()` runs (which is also called by `update()`).
get_frame_time :: proc() -> f32 {
	return s.frame_time
}

// Returns how many seconds has elapsed since the game started. This is a `f64` number, giving good
// precision when the application runs for a long time.
//
// This value is updated when `calculate_frame_time()` runs (which is also called by `update()`).
get_time :: proc() -> f64 {
	return s.time
}

// Gets the width of the drawing area within the window.
get_screen_width :: proc() -> int {
	return s.win.get_width()
}

// Gets the height of the drawing area within the window.
get_screen_height :: proc() -> int {
	return s.win.get_height()
}

// Moves the window.
//
// This does nothing for web builds.
set_window_position :: proc(x: int, y: int) {
	s.win.set_position(x, y)
}

// Resize the window to a new size. While the user cannot resize windows with
// `window_mode == .Windowed_Resizable`, this procedure will resize them.
set_window_size :: proc(width: int, height: int) {
	// TODO not sure if we should resize swapchain here. On windows the WM_SIZE event fires and
	// it all works out. But perhaps not on all platforms?
	s.win.set_size(width, height)
}

// Fetch the scale of the window. This usually comes from some DPI scaling setting in the OS.
// 1 means 100% scale, 1.5 means 150% etc.
get_window_scale :: proc() -> f32 {
	return s.win.get_window_scale()
}

// Use to change between windowed mode, resizable windowed mode and fullscreen
set_window_mode :: proc(window_mode: window.Mode) {
	s.win.set_window_mode(window_mode)
}

//-------//
// INPUT //
//-------//

// Returns true if a keyboard key went down between the current and the previous frame. Set when
// 'process_events' runs.
key_went_down :: proc(key: window.Keyboard_Key) -> bool {
	return s.key_went_down[key]
}

// Returns true if a keyboard key went up (was released) between the current and the previous frame.
// Set when 'process_events' runs.
key_went_up :: proc(key: window.Keyboard_Key) -> bool {
	return s.key_went_up[key]
}

// Returns true if a keyboard is currently being held down. Set when 'process_events' runs.
key_is_held :: proc(key: window.Keyboard_Key) -> bool {
	return s.key_is_held[key]
}

// Returns true if a mouse button went down between the current and the previous frame. Specify
// which mouse button using the `button` parameter.
//
// Set when 'process_events' runs.
mouse_button_went_down :: proc(button: window.Mouse_Button) -> bool {
	return s.mouse_button_went_down[button]
}

// Returns true if a mouse button went up (was released) between the current and the previous frame.
// Specify which mouse button using the `button` parameter.
//
// Set when 'process_events' runs.
mouse_button_went_up :: proc(button: window.Mouse_Button) -> bool {
	return s.mouse_button_went_up[button]
}

// Returns true if a mouse button is currently being held down. Specify which mouse button using the
// `button` parameter. Set when 'process_events' runs.
mouse_button_is_held :: proc(button: window.Mouse_Button) -> bool {
	return s.mouse_button_is_held[button]
}

// Returns how many clicks the mouse wheel has scrolled between the previous and current frame.
get_mouse_wheel_delta :: proc() -> f32 {
	return s.mouse_wheel_delta
}

// Returns the mouse position, measured from the top-left corner of the window.
get_mouse_position :: proc() -> Vec2 {
	return s.mouse_position
}

// Returns how many pixels the mouse moved between the previous and the current frame.
get_mouse_delta :: proc() -> Vec2 {
	return s.mouse_delta
}

// Returns true if a gamepad with the supplied index is connected. The parameter should be a value
// between 0 and MAX_GAMEPADS.
is_gamepad_active :: proc(gamepad: window.Gamepad_Index) -> bool {
	return s.win.is_gamepad_active(gamepad)
}

// Returns true if a gamepad button went down between the previous and the current frame.
gamepad_button_went_down :: proc(
	gamepad: window.Gamepad_Index,
	button: window.Gamepad_Button,
) -> bool {
	if gamepad < 0 || gamepad >= window.MAX_GAMEPADS {
		return false
	}

	return s.gamepad_button_went_down[gamepad][button]
}

// Returns true if a gamepad button went up (was released) between the previous and the current
// frame.
gamepad_button_went_up :: proc(
	gamepad: window.Gamepad_Index,
	button: window.Gamepad_Button,
) -> bool {
	if gamepad < 0 || gamepad >= window.MAX_GAMEPADS {
		return false
	}

	return s.gamepad_button_went_up[gamepad][button]
}

// Returns true if a gamepad button is currently held down.
//
// The "trigger buttons" on some gamepads also have an analogue "axis value" associated with them.
// Fetch that value using `get_gamepad_axis()`.
gamepad_button_is_held :: proc(
	gamepad: window.Gamepad_Index,
	button: window.Gamepad_Button,
) -> bool {
	if gamepad < 0 || gamepad >= window.MAX_GAMEPADS {
		return false
	}

	return s.gamepad_button_is_held[gamepad][button]
}

// Returns the value of analogue gamepad axes such as the thumbsticks and trigger buttons. The value
// is in the range -1 to 1 for sticks and 0 to 1 for trigger buttons.
get_gamepad_axis :: proc(gamepad: window.Gamepad_Index, axis: window.Gamepad_Axis) -> f32 {
	return s.win.get_gamepad_axis(gamepad, axis)
}

// Set the left and right vibration motor speed. The range of left and right is 0 to 1. Note that on
// most gamepads, the left motor is "low frequency" and the right motor is "high frequency". They do
// not vibrate with the same speed.
set_gamepad_vibration :: proc(gamepad: window.Gamepad_Index, left: f32, right: f32) {
	s.win.set_gamepad_vibration(gamepad, left, right)
}


//------//
// MISC //
//------//

// Restore the internal state using the pointer returned by `init`. Useful after reloading the
// library (for example, when doing code hot reload).
// set_internal_state :: proc(state: ^State) {
// 	s = state
// 	rb = s.rb
// 	win = s.win
// 	rb.set_internal_state(s.rb_state)
// 	win.set_internal_state(s.window_state)
// }

////////////////////////////////////////////////////////////////////////////////////////////////

// render

draw_texture :: render.draw_texture
draw_texture_ex :: render.draw_texture_ex
draw_text :: render.draw_text
draw_rect :: render.draw_rect

set_camera :: proc(camera: Maybe(render.Camera)) {render.set_camera(camera, s.win)}

texture_from_bytes :: render.load_texture_from_bytes
texture_fini :: render.destroy_texture

// lifecyle

clear :: render.clear
present :: render.present

// types

Camera :: render.Camera
Texture :: render.Texture
Font :: render.Font
Vec2 :: primatives.Vec2
Vec3 :: primatives.Vec3
Vec4 :: primatives.Vec4
Mat4 :: primatives.Mat4
Rect :: primatives.Rect // A rectangle that sits at position (x, y) and has size (w, h)
Color :: render.Color

// colors

RED :: render.RED
BLACK :: render.BLACK
GRAY :: render.GRAY

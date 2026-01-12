package karl2d

import "base:runtime"
import "core:time"
import "window"

// This keeps track of the internal state of the library. Usually, you do not need to poke at it.
// It is created and kept as a global variable when 'init' is called. However, 'init' also returns
// the pointer to it, so you can later use 'set_internal_state' to restore it (after for example hot
// reload).
State :: struct {
	allocator:                runtime.Allocator,

	// input
	mouse_position:           Vec2,
	mouse_delta:              Vec2,
	mouse_wheel_delta:        f32,
	key_went_down:            #sparse[window.Keyboard_Key]bool,
	key_went_up:              #sparse[window.Keyboard_Key]bool,
	key_is_held:              #sparse[window.Keyboard_Key]bool,
	mouse_button_went_down:   #sparse[window.Mouse_Button]bool,
	mouse_button_went_up:     #sparse[window.Mouse_Button]bool,
	mouse_button_is_held:     #sparse[window.Mouse_Button]bool,
	gamepad_button_went_down: [window.MAX_GAMEPADS]#sparse[window.Gamepad_Button]bool,
	gamepad_button_went_up:   [window.MAX_GAMEPADS]#sparse[window.Gamepad_Button]bool,
	gamepad_button_is_held:   [window.MAX_GAMEPADS]#sparse[window.Gamepad_Button]bool,

	// window
	win:                      window.Interface,
	window_state:             rawptr,
	close_window_requested:   bool,
	// An OS-independent handle that we can pass to any rendering backend.
	window:                   window.Handle,

	// Time when the first call to `new_frame` happened
	start_time:               time.Time,
	prev_frame_time:          time.Time,

	// "dt"
	frame_time:               f32,
	time:                     f64,
}

@(private)
s: ^State

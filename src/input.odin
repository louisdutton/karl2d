package karl2d

import "render"
import "window"

// Process all events that have arrived from the platform APIs. This includes keyboard, mouse,
// gamepad and window events. This procedure processes and stores the information that procs like
// `key_went_down` need.
//
// Called by `update`, but can be called manually if you need more control.
process_events :: proc() {
	s.key_went_up = {}
	s.key_went_down = {}
	s.mouse_button_went_up = {}
	s.mouse_button_went_down = {}
	s.gamepad_button_went_up = {}
	s.gamepad_button_went_down = {}
	s.mouse_delta = {}
	s.mouse_wheel_delta = 0

	s.win.process_events()

	events := s.win.get_events()

	for &event in events {
		switch &e in event {
		case window.Event_Close_Wanted:
			s.close_window_requested = true

		case window.Event_Key_Went_Down:
			s.key_went_down[e.key] = true
			s.key_is_held[e.key] = true

		case window.Event_Key_Went_Up:
			s.key_went_up[e.key] = true
			s.key_is_held[e.key] = false

		case window.Event_Mouse_Button_Went_Down:
			s.mouse_button_went_down[e.button] = true
			s.mouse_button_is_held[e.button] = true

		case window.Event_Mouse_Button_Went_Up:
			s.mouse_button_went_up[e.button] = true
			s.mouse_button_is_held[e.button] = false

		case window.Event_Mouse_Move:
			prev_pos := s.mouse_position

			s.mouse_position.x = e.position.x
			s.mouse_position.y = e.position.y

			s.mouse_delta = s.mouse_position - prev_pos

		case window.Event_Mouse_Wheel:
			s.mouse_wheel_delta = e.delta

		case window.Event_Gamepad_Button_Went_Down:
			if e.gamepad < window.MAX_GAMEPADS {
				s.gamepad_button_went_down[e.gamepad][e.button] = true
				s.gamepad_button_is_held[e.gamepad][e.button] = true
			}

		case window.Event_Gamepad_Button_Went_Up:
			if e.gamepad < window.MAX_GAMEPADS {
				s.gamepad_button_went_up[e.gamepad][e.button] = true
				s.gamepad_button_is_held[e.gamepad][e.button] = false
			}

		case window.Event_Resize:
			render.resize(e.width, e.height)

		case window.Event_Focused:

		case window.Event_Unfocused:
			for k in window.Keyboard_Key {
				if s.key_is_held[k] {
					s.key_is_held[k] = false
					s.key_went_up[k] = true
				}
			}

			for b in window.Mouse_Button {
				if s.mouse_button_is_held[b] {
					s.mouse_button_is_held[b] = false
					s.mouse_button_went_up[b] = true
				}
			}

			for gp in 0 ..< window.MAX_GAMEPADS {
				for b in window.Gamepad_Button {
					if s.gamepad_button_is_held[gp][b] {
						s.gamepad_button_is_held[gp][b] = false
						s.gamepad_button_went_up[gp][b] = true
					}
				}
			}
		}
	}

	s.win.clear_events()
}

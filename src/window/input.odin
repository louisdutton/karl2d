package window

import "../primatives"

Vec2 :: primatives.Vec2

// Support for up to 255 mouse buttons. Cast an int to type `Mouse_Button` to use things outside the
// options presented here.
Mouse_Button :: enum {
	Left,
	Right,
	Middle,
	Max = 255,
}

// Based on Raylib / GLFW
Keyboard_Key :: enum {
	None          = 0,

	// Numeric keys (top row)
	N0            = 48,
	N1            = 49,
	N2            = 50,
	N3            = 51,
	N4            = 52,
	N5            = 53,
	N6            = 54,
	N7            = 55,
	N8            = 56,
	N9            = 57,

	// Letter keys
	A             = 65,
	B             = 66,
	C             = 67,
	D             = 68,
	E             = 69,
	F             = 70,
	G             = 71,
	H             = 72,
	I             = 73,
	J             = 74,
	K             = 75,
	L             = 76,
	M             = 77,
	N             = 78,
	O             = 79,
	P             = 80,
	Q             = 81,
	R             = 82,
	S             = 83,
	T             = 84,
	U             = 85,
	V             = 86,
	W             = 87,
	X             = 88,
	Y             = 89,
	Z             = 90,

	// Special characters
	Apostrophe    = 39,
	Comma         = 44,
	Minus         = 45,
	Period        = 46,
	Slash         = 47,
	Semicolon     = 59,
	Equal         = 61,
	Left_Bracket  = 91,
	Backslash     = 92,
	Right_Bracket = 93,
	Backtick      = 96,

	// Function keys, modifiers, caret control etc
	Space         = 32,
	Escape        = 256,
	Enter         = 257,
	Tab           = 258,
	Backspace     = 259,
	Insert        = 260,
	Delete        = 261,
	Right         = 262,
	Left          = 263,
	Down          = 264,
	Up            = 265,
	Page_Up       = 266,
	Page_Down     = 267,
	Home          = 268,
	End           = 269,
	Caps_Lock     = 280,
	Scroll_Lock   = 281,
	Num_Lock      = 282,
	Print_Screen  = 283,
	Pause         = 284,
	F1            = 290,
	F2            = 291,
	F3            = 292,
	F4            = 293,
	F5            = 294,
	F6            = 295,
	F7            = 296,
	F8            = 297,
	F9            = 298,
	F10           = 299,
	F11           = 300,
	F12           = 301,
	Left_Shift    = 340,
	Left_Control  = 341,
	Left_Alt      = 342,
	Left_Super    = 343,
	Right_Shift   = 344,
	Right_Control = 345,
	Right_Alt     = 346,
	Right_Super   = 347,
	Menu          = 348,

	// Numpad keys
	NP_0          = 320,
	NP_1          = 321,
	NP_2          = 322,
	NP_3          = 323,
	NP_4          = 324,
	NP_5          = 325,
	NP_6          = 326,
	NP_7          = 327,
	NP_8          = 328,
	NP_9          = 329,
	NP_Decimal    = 330,
	NP_Divide     = 331,
	NP_Multiply   = 332,
	NP_Subtract   = 333,
	NP_Add        = 334,
	NP_Enter      = 335,
	NP_Equal      = 336,
}

MAX_GAMEPADS :: 4

// A value between 0 and MAX_GAMEPADS - 1
Gamepad_Index :: int

Gamepad_Axis :: enum {
	Left_Stick_X,
	Left_Stick_Y,
	Right_Stick_X,
	Right_Stick_Y,
	Left_Trigger,
	Right_Trigger,
}

Gamepad_Button :: enum {
	// DPAD buttons
	Left_Face_Up,
	Left_Face_Down,
	Left_Face_Left,
	Left_Face_Right,
	Right_Face_Up, // XBOX: Y, PS: Triangle
	Right_Face_Down, // XBOX: A, PS: X
	Right_Face_Left, // XBOX: X, PS: Square
	Right_Face_Right, // XBOX: B, PS: Circle
	Left_Shoulder,
	Left_Trigger,
	Right_Shoulder,
	Right_Trigger,
	Left_Stick_Press, // Clicking the left analogue stick
	Right_Stick_Press, // Clicking the right analogue stick
	Middle_Face_Left, // Select / back / options button
	Middle_Face_Middle, // PS button (not available on XBox)
	Middle_Face_Right, // Start
}

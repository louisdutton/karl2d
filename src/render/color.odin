package render

// An RGBA (Red, Green, Blue, Alpha) color. Each channel can have a value between 0 and 255.
Color :: [4]u8
Color_F32 :: [4]f32

// See the folder examples/palette for a demo that shows all colors
BLACK :: Color{0, 0, 0, 255}
WHITE :: Color{255, 255, 255, 255}
BLANK :: Color{0, 0, 0, 0}
GRAY :: Color{183, 183, 183, 255}
DARK_GRAY :: Color{66, 66, 66, 255}
BLUE :: Color{25, 198, 236, 255}
DARK_BLUE :: Color{7, 47, 88, 255}
LIGHT_BLUE :: Color{200, 230, 255, 255}
GREEN :: Color{16, 130, 11, 255}
DARK_GREEN :: Color{6, 53, 34, 255}
LIGHT_GREEN :: Color{175, 246, 184, 255}
ORANGE :: Color{255, 114, 0, 255}
RED :: Color{239, 53, 53, 255}
DARK_RED :: Color{127, 10, 10, 255}
LIGHT_RED :: Color{248, 183, 183, 255}
BROWN :: Color{115, 78, 74, 255}
DARK_BROWN :: Color{50, 36, 32, 255}
LIGHT_BROWN :: Color{146, 119, 119, 255}
PURPLE :: Color{155, 31, 232, 255}
LIGHT_PURPLE :: Color{217, 172, 248, 255}
MAGENTA :: Color{209, 17, 209, 255}
YELLOW :: Color{250, 250, 129, 255}
LIGHT_YELLOW :: Color{253, 250, 222, 255}

color_alpha :: proc(c: Color, a: u8) -> Color {
	return {c.r, c.g, c.b, a}
}

f32_color_from_color :: proc(color: Color) -> Color_F32 {
	return {f32(color.r) / 255, f32(color.g) / 255, f32(color.b) / 255, f32(color.a) / 255}
}

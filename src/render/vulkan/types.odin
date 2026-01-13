package vulkan_backend

import p "../../primatives"

// Handle type matching the handle_map package
Handle :: struct {
	idx: u32,
	gen: u32,
}

// Backend handle types
Texture_Handle :: distinct Handle
Shader_Handle :: distinct Handle
Render_Target_Handle :: distinct Handle

TEXTURE_NONE :: Texture_Handle{}
SHADER_NONE :: Shader_Handle{}
RENDER_TARGET_NONE :: Render_Target_Handle{}

// Basic types - aliased from primatives to avoid type mismatches
Color :: [4]u8
Rect :: p.Rect

// Enums
Blend_Mode :: enum {
	Alpha,
	Premultiplied_Alpha,
}

Texture_Filter :: enum {
	Point,
	Linear,
}

Pixel_Format :: enum {
	Unknown,
	RGBA_32_Float,
	RGB_32_Float,
	RG_32_Float,
	R_32_Float,
	RGBA_8_Norm,
	RG_8_Norm,
	R_8_Norm,
	R_8_UInt,
}

// Shader description types (returned from load_shader)
Shader_Constant_Desc :: struct {
	name: string,
	size: int,
}

Shader_Texture_Bindpoint_Desc :: struct {
	name: string,
}

Shader_Input_Type :: enum {
	F32,
	Vec2,
	Vec3,
	Vec4,
}

Shader_Input :: struct {
	name:     string,
	register: int,
	type:     Shader_Input_Type,
	format:   Pixel_Format,
}

Shader_Desc :: struct {
	constants:          []Shader_Constant_Desc,
	texture_bindpoints: []Shader_Texture_Bindpoint_Desc,
	inputs:             []Shader_Input,
}

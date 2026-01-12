package render

import hm "../handle_map"
import "core:log"
import "core:mem"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"

Shader_Handle :: distinct hm.Handle

SHADER_NONE :: Shader_Handle{}

Shader_Constant_Location :: struct {
	offset: int,
	size:   int,
}

Shader :: struct {
	// The render backend's internal identifier.
	handle:                     Shader_Handle,

	// We store the CPU-side value of all constants in a single buffer to have less allocations.
	// The 'constants' array says where in this buffer each constant is, and 'constant_lookup'
	// maps a name to a constant location.
	constants_data:             []u8,
	constants:                  []Shader_Constant_Location,

	// Look up named constants. If you have a constant (uniform) in the shader called "bob", then
	// you can find its location by running `shader.constant_lookup["bob"]`. You can then use that
	// location in combination with `set_shader_constant`
	constant_lookup:            map[string]Shader_Constant_Location,

	// Maps built in constant types such as "model view projection matrix" to a location.
	constant_builtin_locations: [Shader_Builtin_Constant]Maybe(Shader_Constant_Location),
	texture_bindpoints:         []Texture_Handle,

	// Used to lookup bindpoints of textures. You can then set the texture by overriding
	// `shader.texture_bindpoints[shader.texture_lookup["some_tex"]] = some_texture.handle`
	texture_lookup:             map[string]int,
	default_texture_index:      Maybe(int),
	inputs:                     []Shader_Input,

	// Overrides the value of a specific vertex input.
	//
	// It's recommended you use `override_shader_input` to modify these overrides.
	input_overrides:            []Shader_Input_Value_Override,
	default_input_offsets:      [Shader_Default_Inputs]int,

	// How many bytes a vertex uses gives the input of the shader.
	vertex_size:                int,
}

SHADER_INPUT_VALUE_MAX_SIZE :: 256

Shader_Input_Value_Override :: struct {
	val:  [SHADER_INPUT_VALUE_MAX_SIZE]u8,
	used: int,
}

Shader_Input_Type :: enum {
	F32,
	Vec2,
	Vec3,
	Vec4,
}

Shader_Builtin_Constant :: enum {
	View_Projection_Matrix,
}

Shader_Default_Inputs :: enum {
	Unknown,
	Position,
	UV,
	Color,
}

Shader_Input :: struct {
	name:     string,
	register: int,
	type:     Shader_Input_Type,
	format:   Pixel_Format,
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

Shader_Constant_Desc :: struct {
	name: string,
	size: int,
}

Shader_Texture_Bindpoint_Desc :: struct {
	name: string,
}

Shader_Desc :: struct {
	constants:          []Shader_Constant_Desc,
	texture_bindpoints: []Shader_Texture_Bindpoint_Desc,
	inputs:             []Shader_Input,
}

// Load a shader from a vertex and fragment shader file. If the vertex and fragment shaders live in
// the same file, then pass it twice.
//
// `layout_formats` can in many cases be left default initialized. It is used to specify the format
// of the vertex shader inputs. By formats this means the format that you pass on the CPU side.
load_shader_from_file :: proc(
	vertex_filename: string,
	fragment_filename: string,
	layout_formats: []Pixel_Format = {},
	allocator := context.allocator,
) -> Shader {
	vertex_source, vertex_source_ok := os.read_entire_file(vertex_filename, allocator)

	if !vertex_source_ok {
		log.errorf("Failed loading shader %s", vertex_filename)
		return {}
	}

	fragment_source: []byte

	if fragment_filename == vertex_filename {
		fragment_source = vertex_source
	} else {
		fragment_source_ok: bool
		fragment_source, fragment_source_ok = os.read_entire_file(
			fragment_filename,
			context.temp_allocator,
		)

		if !fragment_source_ok {
			log.errorf("Failed loading shader %s", fragment_filename)
			return {}
		}
	}

	return load_shader_from_bytes(vertex_source, fragment_source, layout_formats)
}

// Load a vertex and fragment shader from a block of memory. See `load_shader_from_file` for what
// `layout_formats` means.
load_shader_from_bytes :: proc(
	vertex_shader_bytes: []byte,
	fragment_shader_bytes: []byte,
	layout_formats: []Pixel_Format = {},
	allocator := context.allocator,
) -> Shader {
	handle, desc := s.rb.load_shader(
		vertex_shader_bytes,
		fragment_shader_bytes,
		context.temp_allocator,
		layout_formats,
	)

	if handle == SHADER_NONE {
		log.error("Failed loading shader")
		return {}
	}

	constants_size: int

	for c in desc.constants {
		constants_size += c.size
	}

	shd := Shader {
		handle             = handle,
		constants_data     = make([]u8, constants_size, allocator),
		constants          = make([]Shader_Constant_Location, len(desc.constants), allocator),
		constant_lookup    = make(map[string]Shader_Constant_Location, allocator),
		inputs             = slice.clone(desc.inputs, allocator),
		input_overrides    = make([]Shader_Input_Value_Override, len(desc.inputs), allocator),
		texture_bindpoints = make([]Texture_Handle, len(desc.texture_bindpoints), allocator),
		texture_lookup     = make(map[string]int, allocator),
	}

	for &input in shd.inputs {
		input.name = strings.clone(input.name, allocator)
	}

	constant_offset: int

	for cidx in 0 ..< len(desc.constants) {
		constant_desc := &desc.constants[cidx]

		loc := Shader_Constant_Location {
			offset = constant_offset,
			size   = constant_desc.size,
		}

		shd.constants[cidx] = loc
		constant_offset += constant_desc.size

		if constant_desc.name != "" {
			shd.constant_lookup[strings.clone(constant_desc.name, allocator)] = loc

			switch constant_desc.name {
			case "view_projection":
				shd.constant_builtin_locations[.View_Projection_Matrix] = loc
			}
		}
	}

	for tbp, tbp_idx in desc.texture_bindpoints {
		shd.texture_lookup[tbp.name] = tbp_idx

		if tbp.name == "tex" {
			shd.default_texture_index = tbp_idx
		}
	}

	for &d in shd.default_input_offsets {
		d = -1
	}

	input_offset: int

	for &input in shd.inputs {
		default_format := get_shader_input_default_type(input.name, input.type)

		if default_format != .Unknown {
			shd.default_input_offsets[default_format] = input_offset
		}

		input_offset += pixel_format_size(input.format)
	}

	shd.vertex_size = input_offset
	return shd
}

// Destroy a shader previously loaded using `load_shader_from_file` or `load_shader_from_bytes`
destroy_shader :: proc(shader: Shader, allocator := context.allocator) {
	s.rb.destroy_shader(shader.handle)

	delete(shader.constants_data, allocator)
	delete(shader.constants, allocator)
	delete(shader.texture_lookup)
	delete(shader.texture_bindpoints, allocator)

	for k, _ in shader.constant_lookup {
		delete(k, allocator)
	}

	delete(shader.constant_lookup)
	for i in shader.inputs {
		delete(i.name, allocator)
	}
	delete(shader.inputs, allocator)
	delete(shader.input_overrides, allocator)
}

// Fetches the shader that Karl2D uses by default.
get_default_shader :: proc() -> Shader {
	return s.default_shader
}

// The supplied shader will be used for subsequent drawing. Return to the default shader by calling
// `set_shader(nil)`.
set_shader :: proc(shader: Maybe(Shader)) {
	if shd, shd_ok := shader.?; shd_ok {
		if shd.handle == s.batch_shader.handle {
			return
		}
	} else {
		if s.batch_shader.handle == s.default_shader.handle {
			return
		}
	}

	draw_current_batch()
	s.batch_shader = shader.? or_else s.default_shader
}

// Set the value of a constant (also known as uniform in OpenGL). Look up shader constant locations
// (the kind of value needed for `loc`) by running `loc := shader.constant_lookup["constant_name"]`.
set_shader_constant :: proc(shd: Shader, loc: Shader_Constant_Location, val: any) {
	if shd.handle == SHADER_NONE {
		log.error("Invalid shader")
		return
	}

	if loc.size == 0 {
		log.error("Could not find shader constant")
		return
	}

	draw_current_batch()

	if loc.offset + loc.size > len(shd.constants_data) {
		log.errorf(
			"Constant with offset %v and size %v is out of bounds. Buffer ends at %v",
			loc.offset,
			loc.size,
			len(shd.constants_data),
		)
		return
	}

	sz := reflect.size_of_typeid(val.id)

	if sz != loc.size {
		log.errorf(
			"Trying to set constant of type %v, but it is not of correct size %v",
			val.id,
			loc.size,
		)
		return
	}

	mem.copy(&shd.constants_data[loc.offset], val.data, sz)
}

// Sets the value of a shader input (also known as a shader attribute). There are three default
// shader inputs known as position, texcoord and color. If you have shader with additional inputs,
// then you can use this procedure to set their values. This is a way to feed per-object data into
// your shader.
//
// `input` should be the index of the input and `val` should be a value of the correct size.
//
// You can modify which type that is expected for `val` by passing a custom `layout_formats` when
// you load the shader.
override_shader_input :: proc(shader: Shader, input: int, val: any) {
	sz := reflect.size_of_typeid(val.id)
	assert(sz < SHADER_INPUT_VALUE_MAX_SIZE)
	if input >= len(shader.input_overrides) {
		log.errorf(
			"Input override out of range. Wanted to override input %v, but shader only has %v inputs",
			input,
			len(shader.input_overrides),
		)
		return
	}

	o := &shader.input_overrides[input]

	o.val = {}

	if sz > 0 {
		mem.copy(raw_data(&o.val), val.data, sz)
	}

	o.used = sz
}

// Returns the number of bytes that a pixel in a texture uses.
pixel_format_size :: proc(f: Pixel_Format) -> int {
	switch f {
	case .Unknown:
		return 0

	case .RGBA_32_Float:
		return 32
	case .RGB_32_Float:
		return 12
	case .RG_32_Float:
		return 8
	case .R_32_Float:
		return 4

	case .RGBA_8_Norm:
		return 4
	case .RG_8_Norm:
		return 2
	case .R_8_Norm:
		return 1

	case .R_8_UInt:
		return 1
	}

	return 0
}

batch_vertex :: proc(v: Vec2, uv: Vec2, color: Color) {
	v := v

	if s.vertex_buffer_cpu_used == len(s.vertex_buffer_cpu) {
		draw_current_batch()
	}

	shd := s.batch_shader

	base_offset := s.vertex_buffer_cpu_used
	pos_offset := shd.default_input_offsets[.Position]
	uv_offset := shd.default_input_offsets[.UV]
	color_offset := shd.default_input_offsets[.Color]

	mem.set(&s.vertex_buffer_cpu[base_offset], 0, shd.vertex_size)

	if pos_offset != -1 {
		(^Vec2)(&s.vertex_buffer_cpu[base_offset + pos_offset])^ = v
	}

	if uv_offset != -1 {
		(^Vec2)(&s.vertex_buffer_cpu[base_offset + uv_offset])^ = uv
	}

	if color_offset != -1 {
		(^Color)(&s.vertex_buffer_cpu[base_offset + color_offset])^ = color
	}

	override_offset: int
	for &o, idx in shd.input_overrides {
		input := &shd.inputs[idx]
		sz := pixel_format_size(input.format)

		if o.used != 0 {
			mem.copy(&s.vertex_buffer_cpu[base_offset + override_offset], raw_data(&o.val), o.used)
		}

		override_offset += sz
	}

	s.vertex_buffer_cpu_used += shd.vertex_size
}

get_shader_input_default_type :: proc(
	name: string,
	type: Shader_Input_Type,
) -> Shader_Default_Inputs {
	if name == "position" && type == .Vec2 {
		return .Position
	} else if name == "texcoord" && type == .Vec2 {
		return .UV
	} else if name == "color" && type == .Vec4 {
		return .Color
	}

	return .Unknown
}

get_shader_format_num_components :: proc(format: Pixel_Format) -> int {
	switch format {
	case .Unknown:
		return 0
	case .RGBA_32_Float:
		return 4
	case .RGB_32_Float:
		return 3
	case .RG_32_Float:
		return 2
	case .R_32_Float:
		return 1
	case .RGBA_8_Norm:
		return 4
	case .RG_8_Norm:
		return 2
	case .R_8_Norm:
		return 1
	case .R_8_UInt:
		return 1
	}

	return 0
}

get_shader_input_format :: proc(name: string, type: Shader_Input_Type) -> Pixel_Format {
	default_type := get_shader_input_default_type(name, type)

	if default_type != .Unknown {
		switch default_type {
		case .Position:
			return .RG_32_Float
		case .UV:
			return .RG_32_Float
		case .Color:
			return .RGBA_8_Norm
		case .Unknown:
			unreachable()
		}
	}

	switch type {
	case .F32:
		return .R_32_Float
	case .Vec2:
		return .RG_32_Float
	case .Vec3:
		return .RGB_32_Float
	case .Vec4:
		return .RGBA_32_Float
	}

	return .Unknown
}

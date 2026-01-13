package vulkan_backend

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:slice"
import vk "vendor:vulkan"


import "../../window"

MAX_TEXTURES :: 1024
MAX_FRAMES_IN_FLIGHT :: 2
VERTEX_BUFFER_SIZE :: 1024 * 1024 // 1MB vertex buffer

Texture_Data :: struct {
	image:      vk.Image,
	memory:     vk.DeviceMemory,
	view:       vk.ImageView,
	sampler:    vk.Sampler,
	width:      int,
	height:     int,
	descriptor: vk.DescriptorSet,
}

State :: struct {
	allocator:              runtime.Allocator,
	window_handle:          window.Handle,

	// Vulkan core
	instance:               vk.Instance,
	surface:                vk.SurfaceKHR,
	device:                 vk.Device,
	physical_device:        vk.PhysicalDevice,
	physical_device_props:  vk.PhysicalDeviceProperties,
	queue_family_index:     u32,
	queue:                  vk.Queue,
	swapchain:              vk.SwapchainKHR,
	swapchain_images:       []vk.Image,
	swapchain_views:        []vk.ImageView,
	swapchain_format:       vk.Format,
	swapchain_extent:       vk.Extent2D,
	render_pass:            vk.RenderPass,
	descriptor_set_layout:  vk.DescriptorSetLayout,
	pipeline_layout:        vk.PipelineLayout,
	pipeline:               vk.Pipeline,
	pipeline_blend:         vk.Pipeline,
	framebuffers:           []vk.Framebuffer,
	command_pool:           vk.CommandPool,
	command_buffers:        []vk.CommandBuffer,
	descriptor_pool:        vk.DescriptorPool,

	// Vertex buffer (per frame)
	vertex_buffers:         [MAX_FRAMES_IN_FLIGHT]vk.Buffer,
	vertex_buffer_memories: [MAX_FRAMES_IN_FLIGHT]vk.DeviceMemory,
	vertex_buffer_mapped:   [MAX_FRAMES_IN_FLIGHT]rawptr,

	// Textures
	textures:               [MAX_TEXTURES]Texture_Data,
	texture_count:          u32,
	texture_free_list:      [dynamic]u32,

	// Current frame state
	clear_color:            Color,
	current_texture:        Texture_Handle,
	vertex_buffer_offset:   int, // Current offset in vertex buffer for this frame

	// synchronization
	image_available:        []vk.Semaphore,
	render_finished:        []vk.Semaphore,
	in_flight:              []vk.Fence,
	current_frame:          u32,
	current_image_index:    u32,
	frame_started:          bool,

	// resize handling
	framebuffer_resized:    bool,

	// extensions
	debug:                  vk.DebugUtilsMessengerEXT,
}

ctx: runtime.Context

@(private)
s: State

// =============================================================================
// Public API
// =============================================================================

init :: proc(
	win_handle: window.Handle,
	swapchain_width, swapchain_height: int,
	allocator := context.allocator,
) {
	s.allocator = allocator
	s.window_handle = win_handle
	ctx = context
	s.clear_color = {0, 0, 0, 255}

	// Load Vulkan functions
	vk.load_proc_addresses_global(rawptr(get_proc_addr))
	log.assert(vk.CreateInstance != nil, "Failed to load Vulkan")

	instance_init()
	surface_init()
	device_init()
	swapchain_init(swapchain_width, swapchain_height)
	render_pass_init()
	descriptor_init()
	pipeline_init()
	framebuffers_init()
	command_init()
	vertex_buffer_init()
	sync_init()
}

shutdown :: proc() {
	vk.DeviceWaitIdle(s.device)

	// Destroy all textures
	for i in 0 ..< s.texture_count {
		if s.textures[i].image != 0 {
			destroy_texture_internal(u32(i))
		}
	}
	delete(s.texture_free_list)

	sync_fini()
	vertex_buffer_fini()
	command_fini()
	framebuffers_fini()
	pipeline_fini()
	descriptor_fini()
	render_pass_fini()
	swapchain_fini()
	device_fini()
	surface_fini()
	instance_fini()
}

clear :: proc(render_target: Render_Target_Handle, color: Color) {
	s.clear_color = color
}

present :: proc() {
	draw_frame()
}

draw :: proc(
	shader: Shader_Handle,
	render_target: Render_Target_Handle,
	bound_textures: []Texture_Handle,
	scissor: Maybe(Rect),
	blend: Blend_Mode,
	vertex_buffer: []u8,
	constants_data: []u8 = nil,
) {
	if len(vertex_buffer) == 0 {
		return
	}

	if !s.frame_started {
		begin_frame()
	}

	cmd := s.command_buffers[s.current_frame]

	// Copy vertex data to GPU buffer at current offset
	vertex_size := len(vertex_buffer)
	dst := rawptr(
		uintptr(s.vertex_buffer_mapped[s.current_frame]) + uintptr(s.vertex_buffer_offset),
	)
	mem.copy(dst, raw_data(vertex_buffer), vertex_size)

	// Bind pipeline based on blend mode
	if blend == .Premultiplied_Alpha {
		vk.CmdBindPipeline(cmd, .GRAPHICS, s.pipeline_blend)
	} else {
		vk.CmdBindPipeline(cmd, .GRAPHICS, s.pipeline)
	}

	// Set viewport - use negative height to flip Y axis (Vulkan 1.1+ feature)
	// This makes Vulkan coordinate system match OpenGL: Y goes up, origin at bottom-left
	viewport := vk.Viewport {
		x        = 0,
		y        = f32(s.swapchain_extent.height),
		width    = f32(s.swapchain_extent.width),
		height   = -f32(s.swapchain_extent.height),
		minDepth = 0,
		maxDepth = 1,
	}
	vk.CmdSetViewport(cmd, 0, 1, &viewport)

	// Set scissor
	scissor_rect: vk.Rect2D
	if sc, has_scissor := scissor.?; has_scissor {
		scissor_rect = {
			offset = {i32(sc.x), i32(sc.y)},
			extent = {u32(sc.w), u32(sc.h)},
		}
	} else {
		scissor_rect = {
			offset = {0, 0},
			extent = s.swapchain_extent,
		}
	}
	vk.CmdSetScissor(cmd, 0, 1, &scissor_rect)

	// Push view-projection matrix from constants_data (first 64 bytes = 4x4 float matrix)
	if len(constants_data) >= size_of(matrix[4, 4]f32) {
		vk.CmdPushConstants(
			cmd,
			s.pipeline_layout,
			{.VERTEX},
			0,
			size_of(matrix[4, 4]f32),
			raw_data(constants_data),
		)
	} else {
		// Default to identity matrix
		identity: matrix[4, 4]f32 = 1
		vk.CmdPushConstants(
			cmd,
			s.pipeline_layout,
			{.VERTEX},
			0,
			size_of(matrix[4, 4]f32),
			&identity,
		)
	}

	// Bind vertex buffer at current offset
	offsets := [1]vk.DeviceSize{vk.DeviceSize(s.vertex_buffer_offset)}
	vk.CmdBindVertexBuffers(cmd, 0, 1, &s.vertex_buffers[s.current_frame], &offsets[0])

	// Bind texture descriptor if we have textures
	if len(bound_textures) > 0 && bound_textures[0] != TEXTURE_NONE {
		tex_idx := bound_textures[0].idx
		if tex_idx < MAX_TEXTURES && s.textures[tex_idx].descriptor != 0 {
			vk.CmdBindDescriptorSets(
				cmd,
				.GRAPHICS,
				s.pipeline_layout,
				0,
				1,
				&s.textures[tex_idx].descriptor,
				0,
				nil,
			)
		}
	}

	// Draw - vertex_size / 20 = number of vertices (pos:8 + uv:8 + color:4 = 20 bytes per vertex)
	vertex_count := u32(vertex_size / 20)
	vk.CmdDraw(cmd, vertex_count, 1, 0, 0)

	// Advance offset for next batch
	s.vertex_buffer_offset += vertex_size
}


create_texture :: proc(width, height: int, format: Pixel_Format) -> Texture_Handle {
	return create_texture_internal(width, height, nil)
}

load_texture :: proc(data: []u8, width, height: int, format: Pixel_Format) -> Texture_Handle {
	return create_texture_internal(width, height, data)
}

update_texture :: proc(handle: Texture_Handle, data: []u8, rect: Rect) -> bool {
	if handle == TEXTURE_NONE {
		return false
	}

	tex_idx := handle.idx
	if tex_idx >= MAX_TEXTURES || s.textures[tex_idx].image == 0 {
		return false
	}

	tex := &s.textures[tex_idx]
	x := u32(rect.x)
	y := u32(rect.y)
	w := u32(rect.w)
	h := u32(rect.h)

	if w == 0 || h == 0 {
		return false
	}

	// Create staging buffer
	image_size := vk.DeviceSize(len(data))
	staging_buffer, staging_memory := create_buffer(
		image_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer vk.DestroyBuffer(s.device, staging_buffer, nil)
	defer vk.FreeMemory(s.device, staging_memory, nil)

	// Copy data to staging buffer
	staging_data: rawptr
	check(vk.MapMemory(s.device, staging_memory, 0, image_size, {}, &staging_data))
	mem.copy(staging_data, raw_data(data), len(data))
	vk.UnmapMemory(s.device, staging_memory)

	// Transition to transfer dst, copy, transition back to shader read
	transition_image_layout(tex.image, .SHADER_READ_ONLY_OPTIMAL, .TRANSFER_DST_OPTIMAL)

	// Copy buffer to image region
	cmd := begin_single_time_commands()

	region := vk.BufferImageCopy {
		bufferOffset = 0,
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = {i32(x), i32(y), 0},
		imageExtent = {w, h, 1},
	}

	vk.CmdCopyBufferToImage(cmd, staging_buffer, tex.image, .TRANSFER_DST_OPTIMAL, 1, &region)

	end_single_time_commands(cmd)

	transition_image_layout(tex.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)

	return true
}

destroy_texture :: proc(handle: Texture_Handle) {
	if handle == TEXTURE_NONE {
		return
	}
	destroy_texture_internal(handle.idx)
}

texture_needs_vertical_flip :: proc(handle: Texture_Handle) -> bool {
	return false
}

create_render_texture :: proc(width, height: int) -> (Texture_Handle, Render_Target_Handle) {
	// TODO: implement render textures
	return {}, {}
}

destroy_render_target :: proc(render_target: Render_Target_Handle) {
	// TODO: implement
}

set_texture_filter :: proc(
	handle: Texture_Handle,
	scale_down_filter, scale_up_filter, mip_filter: Texture_Filter,
) {
	// TODO: implement - would need to recreate sampler
}

load_shader :: proc(
	vertex_shader_data, pixel_shader_data: []byte,
	desc_allocator: runtime.Allocator,
	layout_formats: []Pixel_Format = {},
) -> (
	Shader_Handle,
	Shader_Desc,
) {
	// For now, return a dummy shader handle and a description that matches our fixed pipeline
	desc := Shader_Desc {
		constants          = make([]Shader_Constant_Desc, 1, desc_allocator),
		texture_bindpoints = make([]Shader_Texture_Bindpoint_Desc, 1, desc_allocator),
		inputs             = make([]Shader_Input, 3, desc_allocator),
	}

	desc.constants[0] = {
		name = "view_projection",
		size = size_of(matrix[4, 4]f32),
	}
	desc.texture_bindpoints[0] = {
		name = "tex",
	}
	desc.inputs[0] = {
		name   = "position",
		type   = .Vec2,
		format = .RG_32_Float,
	}
	desc.inputs[1] = {
		name   = "texcoord",
		type   = .Vec2,
		format = .RG_32_Float,
	}
	desc.inputs[2] = {
		name   = "color",
		type   = .Vec4,
		format = .RGBA_8_Norm,
	}

	return {idx = 1, gen = 1}, desc
}

destroy_shader :: proc(shader: Shader_Handle) {
	// No-op for now since we use a fixed pipeline
}

resize_swapchain :: proc(width, height: int) {
	s.framebuffer_resized = true
}

get_swapchain_width :: proc() -> int {
	return int(s.swapchain_extent.width)
}

get_swapchain_height :: proc() -> int {
	return int(s.swapchain_extent.height)
}

@(rodata)
VERT_SHADER_DATA := VERT_SHADER_SPV

@(rodata)
FRAG_SHADER_DATA := FRAG_SHADER_SPV

default_shader_vertex_source :: proc() -> []byte {
	return VERT_SHADER_DATA[:]
}

default_shader_fragment_source :: proc() -> []byte {
	return FRAG_SHADER_DATA[:]
}

// =============================================================================
// Internal helpers
// =============================================================================

@(private)
check :: proc(result: vk.Result, loc := #caller_location) {
	assert(result == .SUCCESS, fmt.tprint(result), loc)
}

find_memory_type :: proc(type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
	mem_props: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(s.physical_device, &mem_props)

	for i in 0 ..< mem_props.memoryTypeCount {
		if (type_filter & (1 << i)) != 0 &&
		   (mem_props.memoryTypes[i].propertyFlags & properties) == properties {
			return i
		}
	}

	log.error("Failed to find suitable memory type")
	return 0
}

create_buffer :: proc(
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (
	vk.Buffer,
	vk.DeviceMemory,
) {
	buffer_ci := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	buffer: vk.Buffer
	check(vk.CreateBuffer(s.device, &buffer_ci, nil, &buffer))

	mem_reqs: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(s.device, buffer, &mem_reqs)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = find_memory_type(mem_reqs.memoryTypeBits, properties),
	}

	memory: vk.DeviceMemory
	check(vk.AllocateMemory(s.device, &alloc_info, nil, &memory))
	check(vk.BindBufferMemory(s.device, buffer, memory, 0))

	return buffer, memory
}

begin_single_time_commands :: proc() -> vk.CommandBuffer {
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		level              = .PRIMARY,
		commandPool        = s.command_pool,
		commandBufferCount = 1,
	}

	cmd: vk.CommandBuffer
	check(vk.AllocateCommandBuffers(s.device, &alloc_info, &cmd))

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}
	check(vk.BeginCommandBuffer(cmd, &begin_info))

	return cmd
}

end_single_time_commands :: proc(cmd: vk.CommandBuffer) {
	check(vk.EndCommandBuffer(cmd))

	cmd_copy := cmd
	submit_info := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd_copy,
	}

	check(vk.QueueSubmit(s.queue, 1, &submit_info, 0))
	check(vk.QueueWaitIdle(s.queue))

	vk.FreeCommandBuffers(s.device, s.command_pool, 1, &cmd_copy)
}

transition_image_layout :: proc(
	image: vk.Image,
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
) {
	cmd := begin_single_time_commands()

	barrier := vk.ImageMemoryBarrier {
		sType = .IMAGE_MEMORY_BARRIER,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	src_stage, dst_stage: vk.PipelineStageFlags

	if old_layout == .UNDEFINED && new_layout == .TRANSFER_DST_OPTIMAL {
		barrier.srcAccessMask = {}
		barrier.dstAccessMask = {.TRANSFER_WRITE}
		src_stage = {.TOP_OF_PIPE}
		dst_stage = {.TRANSFER}
	} else if old_layout == .TRANSFER_DST_OPTIMAL && new_layout == .SHADER_READ_ONLY_OPTIMAL {
		barrier.srcAccessMask = {.TRANSFER_WRITE}
		barrier.dstAccessMask = {.SHADER_READ}
		src_stage = {.TRANSFER}
		dst_stage = {.FRAGMENT_SHADER}
	} else {
		log.error("Unsupported layout transition")
	}

	vk.CmdPipelineBarrier(cmd, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier)

	end_single_time_commands(cmd)
}

copy_buffer_to_image :: proc(buffer: vk.Buffer, image: vk.Image, width, height: u32) {
	cmd := begin_single_time_commands()

	region := vk.BufferImageCopy {
		bufferOffset = 0,
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = {0, 0, 0},
		imageExtent = {width, height, 1},
	}

	vk.CmdCopyBufferToImage(cmd, buffer, image, .TRANSFER_DST_OPTIMAL, 1, &region)

	end_single_time_commands(cmd)
}

create_texture_internal :: proc(width, height: int, data: []u8) -> Texture_Handle {
	// Get free slot
	tex_idx: u32
	if len(s.texture_free_list) > 0 {
		tex_idx = pop(&s.texture_free_list)
	} else {
		tex_idx = s.texture_count
		s.texture_count += 1
	}

	if tex_idx >= MAX_TEXTURES {
		log.error("Max textures reached")
		return TEXTURE_NONE
	}

	tex := &s.textures[tex_idx]
	tex.width = width
	tex.height = height

	image_size := vk.DeviceSize(width * height * 4)

	// Create staging buffer
	staging_buffer, staging_memory := create_buffer(
		image_size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)
	defer vk.DestroyBuffer(s.device, staging_buffer, nil)
	defer vk.FreeMemory(s.device, staging_memory, nil)

	// Copy data to staging buffer
	mapped: rawptr
	check(vk.MapMemory(s.device, staging_memory, 0, image_size, {}, &mapped))
	if data != nil {
		mem.copy(mapped, raw_data(data), int(image_size))
	} else {
		mem.set(mapped, 255, int(image_size)) // White texture
	}
	vk.UnmapMemory(s.device, staging_memory)

	// Create image
	image_ci := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		extent        = {u32(width), u32(height), 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		format        = .R8G8B8A8_UNORM,
		tiling        = .OPTIMAL,
		initialLayout = .UNDEFINED,
		usage         = {.TRANSFER_DST, .SAMPLED},
		sharingMode   = .EXCLUSIVE,
		samples       = {._1},
	}
	check(vk.CreateImage(s.device, &image_ci, nil, &tex.image))

	// Allocate and bind image memory
	mem_reqs: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(s.device, tex.image, &mem_reqs)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_reqs.size,
		memoryTypeIndex = find_memory_type(mem_reqs.memoryTypeBits, {.DEVICE_LOCAL}),
	}
	check(vk.AllocateMemory(s.device, &alloc_info, nil, &tex.memory))
	check(vk.BindImageMemory(s.device, tex.image, tex.memory, 0))

	// Transition and copy
	transition_image_layout(tex.image, .UNDEFINED, .TRANSFER_DST_OPTIMAL)
	copy_buffer_to_image(staging_buffer, tex.image, u32(width), u32(height))
	transition_image_layout(tex.image, .TRANSFER_DST_OPTIMAL, .SHADER_READ_ONLY_OPTIMAL)

	// Create image view
	view_ci := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = tex.image,
		viewType = .D2,
		format = .R8G8B8A8_UNORM,
		components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
		subresourceRange = {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	check(vk.CreateImageView(s.device, &view_ci, nil, &tex.view))

	// Create sampler
	sampler_ci := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = .NEAREST,
		minFilter               = .NEAREST,
		addressModeU            = .CLAMP_TO_EDGE,
		addressModeV            = .CLAMP_TO_EDGE,
		addressModeW            = .CLAMP_TO_EDGE,
		anisotropyEnable        = false,
		maxAnisotropy           = 1,
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		mipmapMode              = .NEAREST,
		mipLodBias              = 0,
		minLod                  = 0,
		maxLod                  = 0,
	}
	check(vk.CreateSampler(s.device, &sampler_ci, nil, &tex.sampler))

	// Allocate descriptor set
	alloc_info_ds := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = s.descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &s.descriptor_set_layout,
	}
	check(vk.AllocateDescriptorSets(s.device, &alloc_info_ds, &tex.descriptor))

	// Update descriptor set
	image_info := vk.DescriptorImageInfo {
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
		imageView   = tex.view,
		sampler     = tex.sampler,
	}

	write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = tex.descriptor,
		dstBinding      = 0,
		dstArrayElement = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		pImageInfo      = &image_info,
	}
	vk.UpdateDescriptorSets(s.device, 1, &write, 0, nil)

	return Texture_Handle{idx = tex_idx, gen = 1}
}

destroy_texture_internal :: proc(idx: u32) {
	if idx >= MAX_TEXTURES {
		return
	}

	tex := &s.textures[idx]
	if tex.image == 0 {
		return
	}

	vk.DeviceWaitIdle(s.device)

	if tex.sampler != 0 {
		vk.DestroySampler(s.device, tex.sampler, nil)
	}
	if tex.view != 0 {
		vk.DestroyImageView(s.device, tex.view, nil)
	}
	if tex.image != 0 {
		vk.DestroyImage(s.device, tex.image, nil)
	}
	if tex.memory != 0 {
		vk.FreeMemory(s.device, tex.memory, nil)
	}

	tex^ = {}
	append(&s.texture_free_list, idx)
}

// =============================================================================
// Vulkan Initialization
// =============================================================================

instance_init :: proc() {
	layers := []cstring{"VK_LAYER_KHRONOS_validation"}

	// Platform-specific extensions
	base_extensions := []cstring{vk.EXT_DEBUG_UTILS_EXTENSION_NAME}

	when ODIN_OS == .Darwin {
		platform_extensions := []cstring {
			vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
			vk.EXT_METAL_SURFACE_EXTENSION_NAME,
			vk.KHR_SURFACE_EXTENSION_NAME,
		}
		instance_flags := vk.InstanceCreateFlags{.ENUMERATE_PORTABILITY_KHR}
	} else when ODIN_OS == .Linux {
		platform_extensions := []cstring {
			vk.KHR_XLIB_SURFACE_EXTENSION_NAME,
			vk.KHR_SURFACE_EXTENSION_NAME,
		}
		instance_flags := vk.InstanceCreateFlags{}
	} else {
		platform_extensions := []cstring{vk.KHR_SURFACE_EXTENSION_NAME}
		instance_flags := vk.InstanceCreateFlags{}
	}

	extensions := slice.concatenate([][]cstring{base_extensions, platform_extensions})
	defer delete(extensions)

	debug_ci := vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR},
		messageType = {.VALIDATION, .PERFORMANCE},
		pfnUserCallback = proc "system" (
			messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
			messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
			pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
			pUserData: rawptr,
		) -> b32 {
			level: log.Level
			if .ERROR in messageSeverity do level = .Error
			else if .WARNING in messageSeverity do level = .Warning
			else if .INFO in messageSeverity do level = .Info
			else do level = .Debug

			context = ctx
			context.logger.options = {.Level, .Terminal_Color}
			log.log(level, pCallbackData.pMessage)

			return false
		},
	}

	instance_ci := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		flags                   = instance_flags,
		pApplicationInfo        = &{sType = .APPLICATION_INFO, apiVersion = vk.API_VERSION_1_2},
		enabledLayerCount       = u32(len(layers)),
		ppEnabledLayerNames     = raw_data(layers),
		enabledExtensionCount   = u32(len(extensions)),
		ppEnabledExtensionNames = raw_data(extensions),
		pNext                   = &debug_ci,
	}
	check(vk.CreateInstance(&instance_ci, nil, &s.instance))

	vk.load_proc_addresses_instance(s.instance)
	log.assert(vk.DestroyInstance != nil)

	check(vk.CreateDebugUtilsMessengerEXT(s.instance, &debug_ci, nil, &s.debug))
}

instance_fini :: proc() {
	vk.DestroyDebugUtilsMessengerEXT(s.instance, s.debug, nil)
	vk.DestroyInstance(s.instance, nil)
}

surface_init :: proc() {
	when ODIN_OS == .Darwin {
		// Create Metal surface from NSWindow
		surface_ci := vk.MetalSurfaceCreateInfoEXT {
			sType  = .METAL_SURFACE_CREATE_INFO_EXT,
			pLayer = (^vk.CAMetalLayer)(get_metal_layer(s.window_handle)),
		}
		check(vk.CreateMetalSurfaceEXT(s.instance, &surface_ci, nil, &s.surface))
	} else when ODIN_OS == .Linux {
		// Create Xlib surface from X11 window
		display, x_window := get_x11_handles(s.window_handle)
		surface_ci := vk.XlibSurfaceCreateInfoKHR {
			sType  = .XLIB_SURFACE_CREATE_INFO_KHR,
			dpy    = display,
			window = x_window,
		}
		check(vk.CreateXlibSurfaceKHR(s.instance, &surface_ci, nil, &s.surface))
	}
}

surface_fini :: proc() {
	vk.DestroySurfaceKHR(s.instance, s.surface, nil)
}

device_init :: proc() {
	physical_count: u32
	check(vk.EnumeratePhysicalDevices(s.instance, &physical_count, nil))
	log.assert(physical_count > 0)
	physical_devices := make([]vk.PhysicalDevice, physical_count, context.temp_allocator)
	check(vk.EnumeratePhysicalDevices(s.instance, &physical_count, raw_data(physical_devices)))

	device_loop: for device in physical_devices {
		family_count: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, nil)
		families := make([]vk.QueueFamilyProperties, family_count, context.temp_allocator)
		vk.GetPhysicalDeviceQueueFamilyProperties(device, &family_count, raw_data(families))

		for family, idx in families {
			if .GRAPHICS not_in family.queueFlags do continue
			has_present: b32
			check(vk.GetPhysicalDeviceSurfaceSupportKHR(device, u32(idx), s.surface, &has_present))
			if !has_present do continue

			s.physical_device = device
			s.queue_family_index = u32(idx)
			break device_loop
		}
	}
	log.assert(s.physical_device != nil, "no viable physical device could be found")

	vk.GetPhysicalDeviceProperties(s.physical_device, &s.physical_device_props)

	queue_priority: f32 = 1
	queue_ci := []vk.DeviceQueueCreateInfo {
		{
			sType = .DEVICE_QUEUE_CREATE_INFO,
			queueFamilyIndex = s.queue_family_index,
			queueCount = 1,
			pQueuePriorities = &queue_priority,
		},
	}

	when ODIN_OS == .Darwin {
		device_extensions := []cstring {
			vk.KHR_SWAPCHAIN_EXTENSION_NAME,
			"VK_KHR_portability_subset",
		}
	} else {
		device_extensions := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
	}

	device_ci := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		queueCreateInfoCount    = u32(len(queue_ci)),
		pQueueCreateInfos       = raw_data(queue_ci),
		enabledExtensionCount   = u32(len(device_extensions)),
		ppEnabledExtensionNames = raw_data(device_extensions),
	}
	check(vk.CreateDevice(s.physical_device, &device_ci, nil, &s.device))

	vk.load_proc_addresses_device(s.device)
	log.assert(vk.BeginCommandBuffer != nil)

	vk.GetDeviceQueue(s.device, s.queue_family_index, 0, &s.queue)
}

device_fini :: proc() {
	vk.DestroyDevice(s.device, nil)
}

swapchain_init :: proc(width, height: int) {
	surface_caps: vk.SurfaceCapabilitiesKHR
	check(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(s.physical_device, s.surface, &surface_caps))

	// prefer triple buffering
	image_count: u32 = 3
	if surface_caps.maxImageCount != 0 {
		image_count = min(image_count, surface_caps.maxImageCount)
	}
	image_count = max(image_count, surface_caps.minImageCount)

	surface_format_count: u32
	check(
		vk.GetPhysicalDeviceSurfaceFormatsKHR(
			s.physical_device,
			s.surface,
			&surface_format_count,
			nil,
		),
	)

	surface_formats := make([]vk.SurfaceFormatKHR, surface_format_count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		s.physical_device,
		s.surface,
		&surface_format_count,
		raw_data(surface_formats),
	)

	surface_format := surface_formats[0]
	for sf in surface_formats {
		// Use UNORM format to avoid double sRGB conversion
		// (our textures and colors are already in sRGB space)
		if sf.format == .B8G8R8A8_UNORM && sf.colorSpace == .SRGB_NONLINEAR {
			surface_format = sf
			break
		}
	}

	s.swapchain_format = surface_format.format
	s.swapchain_extent = {u32(width), u32(height)}

	// Clamp extent to surface capabilities
	s.swapchain_extent.width = clamp(
		s.swapchain_extent.width,
		surface_caps.minImageExtent.width,
		surface_caps.maxImageExtent.width,
	)
	s.swapchain_extent.height = clamp(
		s.swapchain_extent.height,
		surface_caps.minImageExtent.height,
		surface_caps.maxImageExtent.height,
	)

	// Check present mode support
	present_mode_count: u32
	check(
		vk.GetPhysicalDeviceSurfacePresentModesKHR(
			s.physical_device,
			s.surface,
			&present_mode_count,
			nil,
		),
	)
	present_modes := make([]vk.PresentModeKHR, present_mode_count, context.temp_allocator)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(
		s.physical_device,
		s.surface,
		&present_mode_count,
		raw_data(present_modes),
	)

	present_mode: vk.PresentModeKHR = .FIFO // guaranteed to be supported
	for pm in present_modes {
		if pm == .MAILBOX {
			present_mode = .MAILBOX
			break
		}
	}

	chain_ci := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = s.surface,
		minImageCount    = image_count,
		imageFormat      = surface_format.format,
		imageColorSpace  = surface_format.colorSpace,
		imageExtent      = s.swapchain_extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = surface_caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		clipped          = true,
	}
	check(vk.CreateSwapchainKHR(s.device, &chain_ci, nil, &s.swapchain))

	// Get swapchain images
	swapchain_image_count: u32
	check(vk.GetSwapchainImagesKHR(s.device, s.swapchain, &swapchain_image_count, nil))
	s.swapchain_images = make([]vk.Image, swapchain_image_count, s.allocator)
	check(
		vk.GetSwapchainImagesKHR(
			s.device,
			s.swapchain,
			&swapchain_image_count,
			raw_data(s.swapchain_images),
		),
	)

	// Create image views
	s.swapchain_views = make([]vk.ImageView, swapchain_image_count, s.allocator)
	for img, i in s.swapchain_images {
		view_ci := vk.ImageViewCreateInfo {
			sType = .IMAGE_VIEW_CREATE_INFO,
			image = img,
			viewType = .D2,
			format = s.swapchain_format,
			components = {.IDENTITY, .IDENTITY, .IDENTITY, .IDENTITY},
			subresourceRange = {
				aspectMask = {.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
		}
		check(vk.CreateImageView(s.device, &view_ci, nil, &s.swapchain_views[i]))
	}

	log.info("Swapchain created with", swapchain_image_count, "images")
}

swapchain_fini :: proc() {
	for view in s.swapchain_views {
		vk.DestroyImageView(s.device, view, nil)
	}
	delete(s.swapchain_views, s.allocator)
	delete(s.swapchain_images, s.allocator)
	vk.DestroySwapchainKHR(s.device, s.swapchain, nil)
}

recreate_swapchain :: proc() {
	vk.DeviceWaitIdle(s.device)

	framebuffers_fini()
	swapchain_fini()

	swapchain_init(int(s.swapchain_extent.width), int(s.swapchain_extent.height))
	framebuffers_init()

	s.framebuffer_resized = false
}

render_pass_init :: proc() {
	color_attachment := vk.AttachmentDescription {
		format         = s.swapchain_format,
		samples        = {._1},
		loadOp         = .CLEAR,
		storeOp        = .STORE,
		stencilLoadOp  = .DONT_CARE,
		stencilStoreOp = .DONT_CARE,
		initialLayout  = .UNDEFINED,
		finalLayout    = .PRESENT_SRC_KHR,
	}

	color_attachment_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = .COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pipelineBindPoint    = .GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &color_attachment_ref,
	}

	dependency := vk.SubpassDependency {
		srcSubpass    = vk.SUBPASS_EXTERNAL,
		dstSubpass    = 0,
		srcStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		srcAccessMask = {},
		dstStageMask  = {.COLOR_ATTACHMENT_OUTPUT},
		dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
	}

	render_pass_ci := vk.RenderPassCreateInfo {
		sType           = .RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
		dependencyCount = 1,
		pDependencies   = &dependency,
	}

	check(vk.CreateRenderPass(s.device, &render_pass_ci, nil, &s.render_pass))
}

render_pass_fini :: proc() {
	vk.DestroyRenderPass(s.device, s.render_pass, nil)
}

descriptor_init :: proc() {
	// Descriptor set layout for texture sampler
	binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = 1,
		stageFlags      = {.FRAGMENT},
	}

	layout_ci := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &binding,
	}
	check(vk.CreateDescriptorSetLayout(s.device, &layout_ci, nil, &s.descriptor_set_layout))

	// Descriptor pool
	pool_size := vk.DescriptorPoolSize {
		type            = .COMBINED_IMAGE_SAMPLER,
		descriptorCount = MAX_TEXTURES,
	}

	pool_ci := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = MAX_TEXTURES,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
	}
	check(vk.CreateDescriptorPool(s.device, &pool_ci, nil, &s.descriptor_pool))
}

descriptor_fini :: proc() {
	vk.DestroyDescriptorPool(s.device, s.descriptor_pool, nil)
	vk.DestroyDescriptorSetLayout(s.device, s.descriptor_set_layout, nil)
}

// Embedded SPIR-V shaders
VERT_SHADER_SPV :: #load("sprite.vert.spv")
FRAG_SHADER_SPV :: #load("sprite.frag.spv")

create_shader_module :: proc(code: []u8) -> vk.ShaderModule {
	ci := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(code),
		pCode    = cast(^u32)raw_data(code),
	}
	module: vk.ShaderModule
	check(vk.CreateShaderModule(s.device, &ci, nil, &module))
	return module
}

pipeline_init :: proc() {
	vert_module := create_shader_module(VERT_SHADER_SPV)
	defer vk.DestroyShaderModule(s.device, vert_module, nil)

	frag_module := create_shader_module(FRAG_SHADER_SPV)
	defer vk.DestroyShaderModule(s.device, frag_module, nil)

	shader_stages := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = vert_module,
			pName = "main",
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = frag_module,
			pName = "main",
		},
	}

	// Vertex input: position (vec2), texcoord (vec2), color (vec4 as u8x4)
	binding_desc := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = 20, // 8 + 8 + 4 bytes
		inputRate = .VERTEX,
	}

	attr_descs := []vk.VertexInputAttributeDescription {
		{binding = 0, location = 0, format = .R32G32_SFLOAT, offset = 0}, // position
		{binding = 0, location = 1, format = .R32G32_SFLOAT, offset = 8}, // texcoord
		{binding = 0, location = 2, format = .R8G8B8A8_UNORM, offset = 16}, // color
	}

	vertex_input_ci := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &binding_desc,
		vertexAttributeDescriptionCount = u32(len(attr_descs)),
		pVertexAttributeDescriptions    = raw_data(attr_descs),
	}

	input_assembly_ci := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = .TRIANGLE_LIST,
	}

	// Dynamic viewport and scissor for resize support
	viewport_ci := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_ci := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	rasterizer_ci := vk.PipelineRasterizationStateCreateInfo {
		sType       = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = .FILL,
		lineWidth   = 1,
		cullMode    = {},
		frontFace   = .COUNTER_CLOCKWISE,
	}

	multisample_ci := vk.PipelineMultisampleStateCreateInfo {
		sType                = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {._1},
	}

	// Alpha blending
	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
	}

	color_blend_ci := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	// Push constant for view-projection matrix
	push_constant_range := vk.PushConstantRange {
		stageFlags = {.VERTEX},
		offset     = 0,
		size       = size_of(matrix[4, 4]f32),
	}

	layout_ci := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &s.descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges    = &push_constant_range,
	}
	check(vk.CreatePipelineLayout(s.device, &layout_ci, nil, &s.pipeline_layout))

	pipeline_ci := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = u32(len(shader_stages)),
		pStages             = raw_data(shader_stages),
		pVertexInputState   = &vertex_input_ci,
		pInputAssemblyState = &input_assembly_ci,
		pViewportState      = &viewport_ci,
		pRasterizationState = &rasterizer_ci,
		pMultisampleState   = &multisample_ci,
		pColorBlendState    = &color_blend_ci,
		pDynamicState       = &dynamic_state_ci,
		layout              = s.pipeline_layout,
		renderPass          = s.render_pass,
		subpass             = 0,
	}

	check(vk.CreateGraphicsPipelines(s.device, 0, 1, &pipeline_ci, nil, &s.pipeline))

	// Create premultiplied alpha pipeline
	color_blend_attachment_premul := vk.PipelineColorBlendAttachmentState {
		colorWriteMask      = {.R, .G, .B, .A},
		blendEnable         = true,
		srcColorBlendFactor = .ONE,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ONE_MINUS_SRC_ALPHA,
		alphaBlendOp        = .ADD,
	}

	color_blend_ci_premul := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment_premul,
	}

	pipeline_ci.pColorBlendState = &color_blend_ci_premul
	check(vk.CreateGraphicsPipelines(s.device, 0, 1, &pipeline_ci, nil, &s.pipeline_blend))
}

pipeline_fini :: proc() {
	vk.DestroyPipeline(s.device, s.pipeline, nil)
	vk.DestroyPipeline(s.device, s.pipeline_blend, nil)
	vk.DestroyPipelineLayout(s.device, s.pipeline_layout, nil)
}

framebuffers_init :: proc() {
	s.framebuffers = make([]vk.Framebuffer, len(s.swapchain_views), s.allocator)

	for view, i in s.swapchain_views {
		attachments := []vk.ImageView{view}

		fb_ci := vk.FramebufferCreateInfo {
			sType           = .FRAMEBUFFER_CREATE_INFO,
			renderPass      = s.render_pass,
			attachmentCount = 1,
			pAttachments    = raw_data(attachments),
			width           = s.swapchain_extent.width,
			height          = s.swapchain_extent.height,
			layers          = 1,
		}
		check(vk.CreateFramebuffer(s.device, &fb_ci, nil, &s.framebuffers[i]))
	}
}

framebuffers_fini :: proc() {
	for fb in s.framebuffers {
		vk.DestroyFramebuffer(s.device, fb, nil)
	}
	delete(s.framebuffers, s.allocator)
}

command_init :: proc() {
	pool_ci := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = s.queue_family_index,
	}
	check(vk.CreateCommandPool(s.device, &pool_ci, nil, &s.command_pool))

	s.command_buffers = make([]vk.CommandBuffer, MAX_FRAMES_IN_FLIGHT, s.allocator)
	alloc_ci := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = s.command_pool,
		level              = .PRIMARY,
		commandBufferCount = MAX_FRAMES_IN_FLIGHT,
	}
	check(vk.AllocateCommandBuffers(s.device, &alloc_ci, raw_data(s.command_buffers)))
}

command_fini :: proc() {
	delete(s.command_buffers, s.allocator)
	vk.DestroyCommandPool(s.device, s.command_pool, nil)
}

vertex_buffer_init :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		s.vertex_buffers[i], s.vertex_buffer_memories[i] = create_buffer(
			VERTEX_BUFFER_SIZE,
			{.VERTEX_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)
		check(
			vk.MapMemory(
				s.device,
				s.vertex_buffer_memories[i],
				0,
				VERTEX_BUFFER_SIZE,
				{},
				&s.vertex_buffer_mapped[i],
			),
		)
	}
}

vertex_buffer_fini :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(s.device, s.vertex_buffer_memories[i])
		vk.DestroyBuffer(s.device, s.vertex_buffers[i], nil)
		vk.FreeMemory(s.device, s.vertex_buffer_memories[i], nil)
	}
}

sync_init :: proc() {
	s.image_available = make([]vk.Semaphore, MAX_FRAMES_IN_FLIGHT, s.allocator)
	s.render_finished = make([]vk.Semaphore, MAX_FRAMES_IN_FLIGHT, s.allocator)
	s.in_flight = make([]vk.Fence, MAX_FRAMES_IN_FLIGHT, s.allocator)

	sem_ci := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}

	fence_ci := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		check(vk.CreateSemaphore(s.device, &sem_ci, nil, &s.image_available[i]))
		check(vk.CreateSemaphore(s.device, &sem_ci, nil, &s.render_finished[i]))
		check(vk.CreateFence(s.device, &fence_ci, nil, &s.in_flight[i]))
	}
}

sync_fini :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.DestroySemaphore(s.device, s.image_available[i], nil)
		vk.DestroySemaphore(s.device, s.render_finished[i], nil)
		vk.DestroyFence(s.device, s.in_flight[i], nil)
	}
	delete(s.image_available, s.allocator)
	delete(s.render_finished, s.allocator)
	delete(s.in_flight, s.allocator)
}

begin_frame :: proc() {
	frame := s.current_frame
	check(vk.WaitForFences(s.device, 1, &s.in_flight[frame], true, max(u64)))

	result := vk.AcquireNextImageKHR(
		s.device,
		s.swapchain,
		max(u64),
		s.image_available[frame],
		0,
		&s.current_image_index,
	)

	if result == .ERROR_OUT_OF_DATE_KHR {
		recreate_swapchain()
		return
	} else if result != .SUCCESS && result != .SUBOPTIMAL_KHR {
		log.error("Failed to acquire swapchain image:", result)
		return
	}

	check(vk.ResetFences(s.device, 1, &s.in_flight[frame]))
	check(vk.ResetCommandBuffer(s.command_buffers[frame], {}))

	cmd := s.command_buffers[frame]

	begin_ci := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
	}
	check(vk.BeginCommandBuffer(cmd, &begin_ci))

	clear_color := vk.ClearValue {
		color = {
			float32 = {
				f32(s.clear_color[0]) / 255.0,
				f32(s.clear_color[1]) / 255.0,
				f32(s.clear_color[2]) / 255.0,
				f32(s.clear_color[3]) / 255.0,
			},
		},
	}

	render_pass_bi := vk.RenderPassBeginInfo {
		sType           = .RENDER_PASS_BEGIN_INFO,
		renderPass      = s.render_pass,
		framebuffer     = s.framebuffers[s.current_image_index],
		renderArea      = {{0, 0}, s.swapchain_extent},
		clearValueCount = 1,
		pClearValues    = &clear_color,
	}

	vk.CmdBeginRenderPass(cmd, &render_pass_bi, .INLINE)

	s.frame_started = true
	s.vertex_buffer_offset = 0 // Reset vertex buffer offset for new frame
}

draw_frame :: proc() {
	if !s.frame_started {
		begin_frame()
	}

	frame := s.current_frame
	cmd := s.command_buffers[frame]

	vk.CmdEndRenderPass(cmd)
	check(vk.EndCommandBuffer(cmd))

	wait_stages := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &s.image_available[frame],
		pWaitDstStageMask    = &wait_stages,
		commandBufferCount   = 1,
		pCommandBuffers      = &s.command_buffers[frame],
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &s.render_finished[frame],
	}

	check(vk.QueueSubmit(s.queue, 1, &submit_info, s.in_flight[frame]))

	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &s.render_finished[frame],
		swapchainCount     = 1,
		pSwapchains        = &s.swapchain,
		pImageIndices      = &s.current_image_index,
	}

	present_result := vk.QueuePresentKHR(s.queue, &present_info)

	if present_result == .ERROR_OUT_OF_DATE_KHR ||
	   present_result == .SUBOPTIMAL_KHR ||
	   s.framebuffer_resized {
		recreate_swapchain()
	}

	s.current_frame = (s.current_frame + 1) % MAX_FRAMES_IN_FLIGHT
	s.frame_started = false
}

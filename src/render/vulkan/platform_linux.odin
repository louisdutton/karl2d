#+build linux

package vulkan_backend

import vk "vendor:vulkan"

import "../../window"

// Load Vulkan function pointers from libvulkan
get_proc_addr :: proc "c" (instance: vk.Instance, name: cstring) -> vk.ProcVoidFunction {
	foreign import vulkan "system:vulkan"

	foreign vulkan {
		vkGetInstanceProcAddr :: proc "c" (instance: vk.Instance, name: cstring) -> vk.ProcVoidFunction ---
	}

	return vkGetInstanceProcAddr(instance, name)
}

// X11 types
Display :: rawptr
X11_Window :: u64

// Get X11 display and window from handle
get_x11_handles :: proc(handle: window.Handle) -> (Display, X11_Window) {
	// The window handle on X11 is the X11 Window ID
	// We need to get the display connection separately
	foreign import x11 "system:X11"

	foreign x11 {
		XOpenDisplay :: proc "c" (display_name: cstring) -> Display ---
	}

	// Get the default display
	display := XOpenDisplay(nil)

	return display, X11_Window(uintptr(handle))
}

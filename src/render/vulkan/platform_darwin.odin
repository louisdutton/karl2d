#+build darwin

package vulkan_backend

import NS "core:sys/darwin/Foundation"
import CA "vendor:darwin/QuartzCore"
import vk "vendor:vulkan"

import "../../window"

foreign import vulkan "system:vulkan"

foreign vulkan {
	vkGetInstanceProcAddr :: proc "c" (instance: vk.Instance, name: cstring) -> vk.ProcVoidFunction ---
}

// Load Vulkan function pointers from the Vulkan loader
get_proc_addr :: proc "c" (instance: vk.Instance, name: cstring) -> vk.ProcVoidFunction {
	return vkGetInstanceProcAddr(instance, name)
}

// Get or create CAMetalLayer from NSWindow handle
get_metal_layer :: proc(handle: window.Handle) -> ^CA.MetalLayer {
	ns_window := (^NS.Window)(rawptr(uintptr(handle)))

	// Get the content view
	content_view := ns_window->contentView()

	// Make the view layer-backed
	content_view->setWantsLayer(true)

	// Create a new CAMetalLayer and set it as the view's layer
	metal_layer := CA.MetalLayer.layer()
	content_view->setLayer(metal_layer)

	return metal_layer
}

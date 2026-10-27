package haxeon.platform.interop;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.Window;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes.Result;

/** Safe Haxe view of NativeKit's process-lifetime Vulkan extension names. */
class VulkanExtensions {
	/** Queries and copies the instance extensions required by a window's presentation backend. */
	public static function requiredInstanceExtensions(window:Window):Array<String> {
		var result = NativeKitVulkan.getRequiredInstanceExtensions(window.nativeHandle());
		if (result.status != Result.Ok)
			throw new NativeKitError(result.status, "vulkan.getRequiredInstanceExtensions", NativeKit.nk_last_error());
		var extensions:Array<String> = [];
		for (extension in result.extensions) {
			if (extension == null)
				throw BindingError.invalidData("VulkanExtensions.requiredInstanceExtensions", "NativeKit returned a null Vulkan extension name");
			extensions.push(extension);
		}
		return extensions;
	}
}

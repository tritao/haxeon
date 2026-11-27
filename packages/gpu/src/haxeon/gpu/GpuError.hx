package haxeon.gpu;

/**
 * Why the GPU module could not do what the device or the system decides: what `Renderer.create`, `Shader.create`, a
 * shader or pipeline builder's `build` return as their `Err`, and what a `GpuException` carries where an API throws
 * instead. A failure that is the program's mistake (a bad argument or handle, a call in the wrong state or thread)
 * throws a `BindingError`. `reason` is the GPU module's own explanation, empty when it gave none.
 */
enum GpuError {
	/** This device, backend or build cannot do it, such as a shader without a source for the backend. */
	Unsupported(reason:String);

	/** The device was lost, as when its driver reset; the renderer is gone with it. */
	DeviceLost;

	/** The device or the system ran out of memory. */
	OutOfMemory;

	/** Any other failure: the GPU module's status `code` and its explanation. */
	Failed(code:Int, reason:String);

	/** The failure in a few words, with the GPU module's explanation where it gave one. */
	public function describe():String
		return switch this {
			case Unsupported(reason): reason.length == 0 ? "not supported" : 'not supported: $reason';
			case DeviceLost: "device lost";
			case OutOfMemory: "out of memory";
			case Failed(code, reason): reason.length == 0 ? 'failed ($code)' : 'failed ($code): $reason';
		}
}

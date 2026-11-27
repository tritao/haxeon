package haxeon.platform;

/**
 * What NativeKit's `InvalidArgument` means at a call (`NativeKitStatus`): mostly the program's mistake, but a decoder
 * answers it for input it refuses, and a call that takes a path for a path that names nothing.
 */
enum InvalidArgumentMeans {
	/** The program passed a bad argument: a `BindingError`. */
	Misuse;

	/** A decoder or parser refused its input: `InvalidData`. */
	RefusedInput;

	/** The path names nothing: `NotFound`. */
	MissingPath;
}

package std.process;

#if wasm
#error "std.process is not available on Wasm: a Wasm module cannot start processes"
#end
/** What one of a child's standard streams is connected to. */
enum Stdio {
	/** A pipe this program reads (output) or writes (input): the child's `stdin`, `stdout` or `stderr`. */
	Pipe;

	/** This program's own stream: the child reads its input, or writes where it writes. */
	Inherit;

	/** Nothing: input at its end at once, output thrown away. */
	Discard;
}

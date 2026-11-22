package build;

/** How much of a project's build runs (`HaxeonProjectBuild.build`). */
enum BuildScope {
	/** Every action: the Haxe compile, FFI imports and native libraries. */
	Full;

	/** The Haxe compile alone (`haxeon build --compiler-only`), with the FFI interfaces an earlier build generated. */
	CompilerOnly;

	/**
	 * Type the program and report its diagnostics without writing a module (`haxeon check`): the Haxe compile, with
	 * `--no-output`, and the actions it reads from (FFI imports), never the native libraries.
	 */
	Check;
}

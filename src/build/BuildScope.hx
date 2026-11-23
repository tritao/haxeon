package build;

/** How much of a project's build runs (`HaxeonProjectBuild.build`). */
enum BuildScope {
	/** Every action: the Haxe compile, FFI imports and native libraries. */
	Full;

	/** The Haxe compile alone (`haxeon build --compiler-only`), with the FFI interfaces an earlier build generated. */
	CompilerOnly;

	/**
		The Haxe compile alone after an edit a watch saw (`haxeon run --watch`). It runs without checking its fingerprint: the watch
		knows a source changed, and the compile server finds what. The stale fingerprint is dropped first, and the new one is
		recorded once the watch is idle (`BuildSession.runIdleWork`), off the edit's path. Without a session it is `CompilerOnly`.
	**/
	Edit;

	/**
	 * The Haxe compile and the actions it reads from (FFI imports), writing the module, without the native libraries: an app's
	 * runner builds those in its own CMake graph (docs/design/PROJECT_BUILDS.md).
	 */
	Module;

	/**
	 * Type the program and report its diagnostics without writing a module (`haxeon check`): the Haxe compile, with
	 * `--no-output`, and the actions it reads from (FFI imports), never the native libraries.
	 */
	Check;
}

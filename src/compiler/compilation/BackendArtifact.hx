package compiler.compilation;

import compiler.hl.HlCode;
import haxe.io.Bytes;

/** What a HashLink build emits: the module and what binds it to a running one. */
typedef HlArtifact = {
	/** HLB: the bytecode module. */
	final module:HlCode;

	/** Function indices in the emitted module, which may differ from incremental slots. */
	final functionIndices:Map<String, Int>;

	/** Stable function ids, which outlive slots and layouts and are what a patch or a host addresses a function by. */
	final functionIds:Map<String, Int>;

	/** HLI: the module identity, revision and stable ids bound to the module's function slots. */
	final runtimeIdentity:Bytes;

	/** HLP: the patch from the build's base revision to this one, or null when the build is not delivered as a patch. */
	final patchBytes:Null<Bytes>;
}

/** What a Wasm build emits. */
typedef WasmArtifact = {
	final bytes:Bytes;
}

/** The artifact of one build, by backend (`CompileResult.artifact`). */
enum BackendArtifact {
	HashLinkBuild(build:HlArtifact);
	WasmBuild(build:WasmArtifact);
}

/** Reads one backend's artifact where a caller knows which backend built it (`using compiler.compilation.BackendArtifact`). */
class BackendArtifacts {
	/** The HashLink artifact; a build by another backend is an error. */
	public static function hashLink(artifact:BackendArtifact):HlArtifact
		return switch artifact {
			case HashLinkBuild(build): build;
			case WasmBuild(_): throw "The build emitted a Wasm module, not a HashLink module";
		};

	/** The Wasm artifact; a build by another backend is an error. */
	public static function wasm(artifact:BackendArtifact):WasmArtifact
		return switch artifact {
			case WasmBuild(build): build;
			case HashLinkBuild(_): throw "The build emitted a HashLink module, not a Wasm module";
		};
}

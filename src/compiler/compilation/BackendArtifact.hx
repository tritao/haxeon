package compiler.compilation;

import compiler.core.InternalError;
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

	/**
	 * The module as HLB 9 module sections (`HlSectionWriter`), or null when the build writes `module` as one dense HLB 8 module.
	 * The function indices are then the ones the loader's link gives.
	 */
	final sections:Null<haxeon.io.SegmentedBytes>;
}

/** What a Wasm build emits. */
typedef WasmArtifact = {
	final bytes:Bytes;
}

/** What a C build emits: the sources (docs/design/AOT_BACKEND.md), which the driver writes and may compile. */
typedef HlcArtifact = {
	final files:Array<compiler.backend.c.HlcModule.HlcFile>;
}

/** The artifact of one build, by backend (`CompileResult.artifact`). */
enum BackendArtifact {
	HashLinkBuild(build:HlArtifact);
	WasmBuild(build:WasmArtifact);
	HashLinkCBuild(build:HlcArtifact);
}

/** Reads one backend's artifact where a caller knows which backend built it (`using compiler.compilation.BackendArtifact`). */
class BackendArtifacts {
	/** The HashLink artifact; a build by another backend is an error. */
	public static function hashLink(artifact:BackendArtifact):HlArtifact
		return switch artifact {
			case HashLinkBuild(build): build;
			case WasmBuild(_): throw new InternalError("The build emitted a Wasm module, not a HashLink module");
			case HashLinkCBuild(_): throw new InternalError("The build emitted C, not a HashLink module");
		};

	/** The Wasm artifact; a build by another backend is an error. */
	public static function wasm(artifact:BackendArtifact):WasmArtifact
		return switch artifact {
			case WasmBuild(build): build;
			case HashLinkBuild(_): throw new InternalError("The build emitted a HashLink module, not a Wasm module");
			case HashLinkCBuild(_): throw new InternalError("The build emitted C, not a Wasm module");
		};

	/** The bytes of a HashLink build's module: its sections, or `module` encoded densely with `cache`. */
	public static function hashLinkBytes(build:HlArtifact, ?cache:compiler.hl.HlWriterCache,
			checkReuse:Bool = false):haxeon.io.SegmentedBytes {
		var sections = build.sections;
		return sections != null ? sections : compiler.hl.HlWriter.encode(build.module, cache, checkReuse);
	}

	/** The C artifact; a build by another backend is an error. */
	public static function c(artifact:BackendArtifact):HlcArtifact
		return switch artifact {
			case HashLinkCBuild(build): build;
			default: throw new InternalError("The build did not emit C");
		};
}

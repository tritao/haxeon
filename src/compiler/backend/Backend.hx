package compiler.backend;

import compiler.backend.MemoryContract.MemoryContract;
import compiler.ir.model.Ir.IrProgram;
import haxe.io.Bytes;

/** Target selected by the compiler after canonical Haxeon IR is available. */
enum BackendTarget {
	HashLink;

	/** C from the IR on the HashLink runtime (`--target=hlc`, docs/design/AOT_BACKEND.md): HashLink's semantics and layouts. */
	HashLinkC;
	Wasm32;
	Wasm64;
	WasmGc;
}

/** Options shared by target backends without exposing target representation. */
typedef BackendOptions = {
	final target:BackendTarget;
	final debugNames:Bool;
	/** Development artifacts carry metadata for hot reload and inspection. */
	final ?developmentMetadata:Bool;
	final ?importMemory:Bool;
	final ?sharedMemory:Bool;
	final ?memoryBase:Int;
	final ?memoryContract:MemoryContract;
	final ?wasmMemoryStats:Bool;
	final ?wasmGcAllocationCount:Bool;
	final ?wasmGcStress:Bool;
	final ?wasmRuntimeNeutral:Bool;

	/** Wasm GC exception handling in the legacy try/catch encoding (`CompileOptions.wasmLegacyExceptions`). */
	final ?wasmLegacyExceptions:Bool;

	/** The backend's own passes check what they reuse and prune, as the compile does (`CompileOptions.checkReuse`). */
	final ?checkReuse:Bool;
	final ?exports:Array<String>;

	/** The C runtime linked into wasm32 modules; defaults to `haxeon/wasm/linear-runtime.wasm` of `standardLibrary`. */
	final ?wasmLinearRuntime:haxe.io.Bytes;

	/**
	 * The standard library the program was compiled with, which holds the Wasm runtimes the backend links
	 * (`haxeon/wasm/*.wasm`); `stdlib` in the working directory when not given.
	 */
	final ?standardLibrary:String;
}

/** Backend artifact returned after lowering a verified Haxeon program. */
typedef BackendResult = {
	final target:BackendTarget;
	final bytes:Bytes;

	/** Function indices in the emitted artifact, which may differ from incremental slots. */
	final ?functionIndices:Map<String, Int>;
}

/** Semantic backend boundary: the input is canonical Haxeon IR, not frontend AST. */
interface Backend {
	function compile(program:IrProgram, options:BackendOptions):BackendResult;
}

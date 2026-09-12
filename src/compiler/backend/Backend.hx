package compiler.backend;

import compiler.ir.Ir.IrProgram;
import haxe.io.Bytes;
import compiler.backend.MemoryContract.MemoryContract;

/** Target selected by the compiler after canonical Haxeon IR is available. */
enum BackendTarget {
	HashLink;
	Wasm32;
	Wasm64;
	WasmGc;
}

/** Options shared by target backends without exposing target representation. */
typedef BackendOptions = {
	final target:BackendTarget;
	final debugNames:Bool;
	final ?importMemory:Bool;
	final ?memoryBase:Int;
	final ?memoryContract:MemoryContract;
	final ?wasmMemoryStats:Bool;
	final ?exports:Array<String>;
}

/** Backend artifact returned after lowering a verified Haxeon program. */
typedef BackendResult = {
	final target:BackendTarget;
	final bytes:Bytes;
}

/** Semantic backend boundary: the input is canonical Haxeon IR, not frontend AST. */
interface Backend {
	function compile(program:IrProgram, options:BackendOptions):BackendResult;
}

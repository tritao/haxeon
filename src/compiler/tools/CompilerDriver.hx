package compiler.tools;

import compiler.Compiler.CompileResult;
import compiler.ffi.CHeaderEmitter;
import compiler.backend.Backend;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.MemoryContract.MemoryContractCodec;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;
import compiler.ir.Ir.IrProgram;
import haxe.io.Bytes;
import sys.io.File;
import compiler.documentation.HaxeXmlWriter;
import compiler.ir.codec.CanonicalIrCodec;

/** Executes one compiler request and writes its deterministic artifacts. */
class CompilerDriver {
	public static function compile(request:CompilerRequest, ?progress:String->Void, ?session:CompilerSession):CompileResult {
		var report = progress == null ? function(message:String) {} : progress;
		var requestStartedAt = Sys.time() * 1000.0;
		var memoryContract = request.memoryContract == null ? null : MemoryContractCodec.load(request.memoryContract);
		report("loading " + Std.string(request.paths.length) + " sources");
		var compiler = (session == null ? new CompilerSession() : session).prepare(request, report);
		var preparedAt = Sys.time() * 1000.0;
		report("compiling entry " + request.entry);
		var result = compiler.compile(request.entry, null, false);
		var compiledAt = Sys.time() * 1000.0;
		var backendStartedAt = Sys.time() * 1000.0;
		if (request.dumpFunction >= 0)
			dumpFunction(result, request.dumpFunction, report);
		var isWasm = StringTools.startsWith(request.target, "wasm"),
			wasmTarget = switch request.target {
				case "wasm32": Wasm32;
				case "wasm64": Wasm64;
				case "wasmgc", "wasm-gc": WasmGc;
				default: HashLink;
			},
			outputBytes:Bytes,
			outputIndices:Null<Map<String, Int>> = null;
		if (isWasm) {
			var backend:Backend = new WasmBackend(),
				backendResult = backend.compile(result.ir, {
					target: wasmTarget,
					debugNames: true,
					importMemory: request.importMemory,
					memoryBase: request.memoryBase,
					memoryContract: memoryContract,
					wasmMemoryStats: request.wasmMemoryStats,
					wasmGcStress: request.wasmGcStress,
					exports: request.exports
				});
			outputBytes = backendResult.bytes;
		} else {
			outputBytes = session == null ? HlWriter.encode(result.module) : session.encodeHashLink(result.module);
			outputIndices = result.functionIndices;
		}
		var backendDoneAt = Sys.time() * 1000.0;
		File.saveBytes(request.output, outputBytes);
		if (isWasm)
			File.saveContent(request.output + ".functions", wasmFunctionMap(result.ir));
		if (!isWasm)
			File.saveBytes(request.output + ".functions", Bytes.ofString(functionMap(outputIndices)));
		if (request.xmlOutput != null)
			File.saveContent(request.xmlOutput, HaxeXmlWriter.emit(compiler.modules));
		if (request.irOutput != null)
			File.saveBytes(request.irOutput, CanonicalIrCodec.encode(result.ir));
		if (request.ffiHeader != null && request.ffiLibrary != null)
			File.saveContent(request.ffiHeader, CHeaderEmitter.emit(result.ir.natives, request.ffiLibrary));
		var artifactsWrittenAt = Sys.time() * 1000.0;
		report("driver phases (ms): prepare=" + milliseconds(preparedAt - requestStartedAt) + " compile=" + milliseconds(compiledAt - preparedAt)
			+ " encode=" + milliseconds(backendDoneAt - backendStartedAt) + " write=" + milliseconds(artifactsWrittenAt - backendDoneAt));
		report(phaseReport(result, backendDoneAt - backendStartedAt));
		report("compiled " + Std.string(request.paths.length) + " source files -> " + request.output);
		return result;
	}

	static function phaseReport(result:CompileResult, outputBackendMs:Float):String {
		var metrics = result.metrics;
		return "compiler phases (ms): snapshot=" + milliseconds(metrics.transactionSnapshotMs) + " candidate=" + milliseconds(metrics.candidateSetupMs)
			+ " frontend=" + milliseconds(metrics.frontendMs) + " (graph=" + milliseconds(metrics.frontendGraphMs) + " parse="
			+ milliseconds(metrics.graphParseMs) + " dependencies=" + milliseconds(metrics.graphDependencyMs) + " initialization="
			+ milliseconds(metrics.graphInitializationMs) + " semantic=" + milliseconds(metrics.semanticAssemblyMs) + " (alias-setup="
			+ milliseconds(metrics.semanticAliasMs) + " canonicalization=" + milliseconds(metrics.semanticCanonicalizationMs) + " contribution-reuse="
			+ milliseconds(metrics.semanticContributionReuseMs) + " contribution-rebuild=" + milliseconds(metrics.semanticContributionRebuildMs)
			+ " invalidation=" + milliseconds(metrics.semanticInvalidationMs) + " semantic-bytes=" + Std.string(metrics.semanticAllocatedBytes) + "))"
			+ " typing/lowering=" + milliseconds(metrics.typingLoweringMs) + " (declarations=" + milliseconds(metrics.declarationMs) + " shapes="
			+ milliseconds(metrics.shapeConnectionMs) + " signatures=" + milliseconds(metrics.signatureTypingMs) + " setup="
			+ milliseconds(metrics.typerSetupMs) + " no-return=" + milliseconds(metrics.typerNoReturnMs) + " metadata="
			+ milliseconds(metrics.typerMetadataMs) + " bodies=" + milliseconds(metrics.typerBodiesMs) + " body-transition="
			+ milliseconds(metrics.bodyTransitionMs) + " assembly=" + milliseconds(metrics.typerAssemblyMs) + " finalization="
			+ milliseconds(metrics.finalizationTransitionMs) + ")" + " ir-assembly=" + milliseconds(metrics.irAssemblyMs) + " abi="
			+ milliseconds(metrics.abiPlanningMs) + " incremental-backend=" + milliseconds(metrics.backendAssemblyMs) + " (assembler-copy="
			+ milliseconds(metrics.backendAssemblerCopyMs) + " cache-preparation=" + milliseconds(metrics.backendCachePreparationMs) + " backend-lowering="
			+ milliseconds(metrics.backendLoweringMs) + " publication=" + milliseconds(metrics.backendPublicationMs) + " snapshots="
			+ milliseconds(metrics.backendSnapshotMs) + " verify=" + milliseconds(metrics.backendVerificationMs) + " lower-metadata="
			+ milliseconds(metrics.backendMetadataMs) + " lower-functions=" + milliseconds(metrics.backendFunctionLoweringMs) + " lower-debug="
			+ milliseconds(metrics.backendDebugAssemblyMs) + " lower-finalize=" + milliseconds(metrics.backendFinalizationMs) + ") patch="
			+ milliseconds(metrics.patchEncodingMs) + " finalize=" + milliseconds(metrics.finalizeMs) + " output-backend=" + milliseconds(outputBackendMs);
	}

	static inline function milliseconds(value:Float):String
		return Std.string(Math.round(value * 100.0) / 100.0);

	/** Defines supplied by the command-line target before user source is analyzed. */
	public static function targetDefines(target:String):Array<String> {
		var result = ["haxeon", "target=" + target];
		switch target {
			case "wasm32":
				result.push("wasm");
				result.push("wasm32");
			case "wasm64":
				result.push("wasm");
				result.push("wasm64");
			case "wasmgc", "wasm-gc":
				result.push("wasm");
				result.push("wasmgc");
			case "hl":
				result.push("hl");
				result.push("sys");
			default:
		}
		return result;
	}

	static function dumpFunction(result:CompileResult, index:Int, report:String->Void):Void
		for (fn in result.module.functions)
			if (fn.functionIndex == index) {
				report('function ${fn.functionIndex} type=${fn.type} registers=${[for (register in fn.registers) Std.string(register)].join(",")}');
				for (instructionIndex in 0...fn.opcodes.length)
					report('$instructionIndex\t${Std.string(fn.opcodes[instructionIndex])}');
			}

	static function functionMap(indices:Map<String, Int>):String {
		var names = [for (name in indices.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) Std.string(indices.get(name)) + "\t" + name].join("\n") + "\n";
	}

	static function wasmFunctionMap(program:IrProgram):String {
		var index = 0, lines:Array<String> = [];
		for (fn in program.functions) {
			if (fn.name == "__entry")
				continue;
			lines.push(Std.string(index++) + "\t" + fn.name);
		}
		return lines.join("\n") + (lines.length == 0 ? "" : "\n");
	}
}

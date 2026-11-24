package compiler.tools;

import compiler.Compiler.CompileResult;
import compiler.abi.AbiChangeSchema;
import compiler.backend.BackendTargets;
import compiler.backend.MemoryContract.MemoryContractCodec;
import compiler.backend.c.HlcModule.HlcFile;
import compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.core.AllocationMeter;
import compiler.core.AllocationMeter.PhaseAllocation;
import compiler.core.CancellationToken;
import compiler.core.InternalError;
import compiler.core.PeakProbe;
import compiler.documentation.HaxeXmlWriter;
import compiler.ffi.CHeaderEmitter;
import compiler.hl.HlWriter;
import compiler.ir.codec.CanonicalIrCodec;
import compiler.ir.model.Ir.IrProgram;
import compiler.types.NativeTypeDescriptorCodec;
import haxe.Json;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/** Executes one compiler request and writes its deterministic artifacts. */
class CompilerDriver {
	public static function compile(request:CompilerRequest, ?progress:String->Void, ?session:CompilerSession,
			?cancellation:CancellationToken,
			?published:() -> Void, ?diagnostics:String->Void):CompileResult {
		if (cancellation != null)
			cancellation.check();
		var report = progress == null ? function(message:String) {} : progress,
			verbosity = request.verbosity;
		// Progress at `normal`; the phase, pass and allocation reports, which tools parse, at `diagnostic`.
		var progressReport = verbosity.atLeast(Verbosity.Normal) ? report : function(message:String) {};
		var requestStartedAt = Sys.time() * 1000.0;
		var allocationAtStart = AllocationMeter.sample();
		var memoryContract = request.memoryContract == null ? null : MemoryContractCodec.load(request.memoryContract);
		progressReport("loading " + Std.string(request.paths.length) + " sources");
		var compilerSession = session == null ? new CompilerSession() : session,
			compiler = compilerSession.prepare(request, report);
		// A persistent session serves interactive and batch requests alike, so the mode is set per request.
		compiler.livePatching = request.live;
		compiler.developmentMetadata = request.buildMode == "development";
		var target = compiler.backendTarget, isWasm = BackendTargets.isWasm(target);
		// The Wasm backend builds the module during the compile (`WasmBackendSession`), with what the request asks of it.
		compiler.backendOptions = isWasm ? {
			target: target,
			debugNames: true,
			developmentMetadata: request.buildMode == "development",
			importMemory: request.importMemory,
			sharedMemory: request.sharedMemory == true,
			memoryBase: request.memoryBase,
			memoryContract: memoryContract,
			wasmMemoryStats: request.wasmMemoryStats,
			wasmGcAllocationCount: request.wasmGcAllocationCount,
			wasmGcStress: request.wasmGcStress,
			wasmRuntimeNeutral: request.wasmRuntimeNeutral,
			wasmLegacyExceptions: request.options.wasmLegacyExceptions,
			checkReuse: request.options.checkReuse,
			exports: request.exports,
			standardLibrary: request.stdlib
		} : null;
		var preparedAt = Sys.time() * 1000.0;
		var allocationAfterPrepare = AllocationMeter.sample();
		progressReport("compiling entry " + request.entry);
		var result = compiler.compile(request.entry, cancellation, false);
		var printer = new DiagnosticPrinter(request), warned = diagnostics == null ? report : diagnostics;
		for (warning in compiler.warnings(result.moduleNames))
			warned(printer.warning(warning));
		try {
			if (target == HashLinkC)
				return writeC(compiler, result, request, report, preparedAt);
			// Checked before anything is written: a module its host cannot call is not published.
			var entryIdOutput = request.entryIdOutput,
				mainId = entryIdOutput == null ? -1 : entryId(result, request.entry);
			var compiledAt = Sys.time() * 1000.0;
			var allocationAfterCompile = AllocationMeter.sample();
			if (cancellation != null)
				cancellation.check();
			var backendStartedAt = Sys.time() * 1000.0;
			if (request.dumpFunction >= 0 && !isWasm)
				dumpFunction(result, request.dumpFunction, report);
			var outputBytes:Null<Bytes> = null,
				outputIndices:Null<Map<String, Int>> = null;
			// A live edit that patches publishes the patch and its stamp before the 40 MB module and the side files are written:
			// the host applies the patch from its own memory, and a reload waits for the `.live.full` marker that vouches for them.
			var patchBytes = isWasm ? null : BackendArtifacts.hashLink(result.artifact).patchBytes;
			var deferFullModule = !isWasm && request.live && patchBytes != null && !result.requiresReload;
			// An unchanged build leaves a publication the host may not have polled yet exactly as it is.
			var publishes = !isWasm && (!result.unchanged || !hasPublication(request.output, result));
			if (!isWasm)
				deleteIfExists(request.output + ".live.full");
			if (isWasm)
				outputBytes = BackendArtifacts.wasm(result.artifact).bytes;
			else {
				outputIndices = BackendArtifacts.hashLink(result.artifact).functionIndices;
				PeakProbe.mark("write-start");
				if (!deferFullModule)
					writeModule(result, request.output, session);
				PeakProbe.mark("write-done");
			}
			if (cancellation != null && !deferFullModule)
				cancellation.check();
			var backendDoneAt = Sys.time() * 1000.0;
			var allocationAfterEncode = AllocationMeter.sample();
			var stampedAt = -1.0;
			var publishPatch = function() {
				var build = BackendArtifacts.hashLink(result.artifact);
				var identities = session == null
					? identitiesJson(build.functionIds) : session.functionIds.of(build.functionIds,
					identitiesJson);
				var patch = build.patchBytes;
				if (patch != null)
					File.saveBytes(request.output + ".hlp", patch);
				else
					deleteIfExists(request.output + ".hlp");
				// The host applies a patch from this summary alone; the full description (every function id) is for reloads.
				var summary = request.output + ".live.patch.json";
				File.saveContent(summary + ".tmp", Json.stringify({
					revision: result.revision,
					baseRevision: result.baseRevision,
					moduleIdentity: Base64.encode(build.runtimeIdentity.sub(4, 16)),
					requiresReload: result.requiresReload,
					reloadReasons: [for (reason in result.reloadReasons) AbiChangeSchema.encode(reason)],
					patchAvailable: patch != null,
					changedFunctions: result.changedFunctions,
					identities: ([]: Array<Dynamic>)
				}));
				replaceFile(summary + ".tmp", summary);
				var manifest = request.output + ".live.json";
				var temporary = manifest + ".tmp";
				// The identities come last, as their cached text.
				var head = Json.stringify({
					revision: result.revision,
					baseRevision: result.baseRevision,
					unchanged: result.unchanged,
					moduleIdentity: Base64.encode(build.runtimeIdentity.sub(4, 16)),
					requiresReload: result.requiresReload,
					reloadReasons: [for (reason in result.reloadReasons) AbiChangeSchema.encode(reason)],
					patchAvailable: patch != null,
					changedFunctions: result.changedFunctions
				});
				File.saveContent(temporary, head.substr(0, head.length - 1) + ',"identities":' + identities + "}");
				replaceFile(temporary, manifest);
				// The live host reads this small stamp every tick, and the description only when the stamp changes.
				var stamp = request.output + ".live.stamp";
				File.saveContent(stamp + ".tmp",
					Base64.encode(build.runtimeIdentity.sub(4, 16)) + ":" + result.revision);
				replaceFile(stamp + ".tmp", stamp);
				stampedAt = Sys.time() * 1000.0;
				if (published != null)
					published();
				// An unchanged build kept its revision and left nothing pending.
				if (!result.unchanged)
					compiler.acknowledgePublication(result.revision);
			};
			if (publishes && deferFullModule) {
				publishPatch();
				writeModule(result, request.output, session);
			}
			if (isWasm) {
				File.saveBytes(request.output, outputBytes);
				File.saveContent(request.output + ".functions", wasmFunctionMap(result.ir));
				// A Wasm module has no live host to acknowledge it: writing it publishes it.
				var status = compiler.publicationStatus();
				if (status.hasPendingRevision && status.pendingRevision == result.revision)
					compiler.acknowledgePublication(result.revision);
			}
			if (!isWasm)
				File.saveBytes(request.output + ".functions", Bytes.ofString(session == null
					? functionMap(outputIndices) : session.functionMap.of(outputIndices, functionMap)));
			if (publishes) {
				File.saveBytes(request.output + ".hli", BackendArtifacts.hashLink(result.artifact).runtimeIdentity);
				if (!deferFullModule)
					publishPatch();
			}
			if (entryIdOutput != null)
				File.saveContent(entryIdOutput, Std.string(mainId));
			// After the publication is acknowledged, so the state is the published module's.
			var baselineOutput = request.baselineOutput;
			if (baselineOutput != null)
				compilerSession.writeBaseline(baselineOutput);
			// A session works the HashLink module's id out from the bytes it wrote, once for an unchanged module.
			var buildId = session == null
				|| isWasm ? build.execution.ContentDigest.makeHex(File.getBytes(request.output))
				: session.hashLinkBuildId(BackendArtifacts.hashLink(result.artifact).module);
			File.saveContent(request.output + ".build-id", buildId);
			if (request.xmlOutput != null)
				File.saveContent(request.xmlOutput, HaxeXmlWriter.emit(compiler.modules));
			if (request.irOutput != null)
				File.saveBytes(request.irOutput, CanonicalIrCodec.encode(result.ir));
			if (request.inputsOutput != null)
				File.saveContent(request.inputsOutput, inputsReport(compiler, result.moduleNames, request));
			if (request.ffiHeader != null && request.ffiLibrary != null)
				File.saveContent(request.ffiHeader, CHeaderEmitter.emit(result.ir.natives, request.ffiLibrary));
			File.saveBytes(request.output + ".descriptors",
				NativeTypeDescriptorCodec.encode(result.nativeTypeDescriptors));
			File.saveContent(request.output + ".descriptors.json",
				NativeTypeDescriptorCodec.toJson(result.nativeTypeDescriptors));
			// Every file a reload reads now belongs to the published revision; the marker is the host's licence to load them.
			if (!isWasm)
				File.saveContent(request.output + ".live.full",
					Base64.encode(BackendArtifacts.hashLink(result.artifact).runtimeIdentity.sub(4, 16)) + ":"
					+ result.revision);
			// The history this revision was assembled from is recorded beside it once the session is idle, so a session that
			// starts after this one patches the module it published. An edit against a baseline is resumed from that baseline.
			if (!isWasm && request.live && request.baseline == null && session != null)
				session.recordLivePublication(request.publishedOutput == null
					? request.output : request.publishedOutput,
					File.getContent(request.output + ".live.full"));
			var artifactsWrittenAt = Sys.time() * 1000.0;
			var allocationAfterWrite = AllocationMeter.sample();
			if (verbosity.atLeast(Verbosity.Diagnostic))
				reportCosts(report, result, requestStartedAt, preparedAt, compiledAt, backendStartedAt, backendDoneAt,
					artifactsWrittenAt, stampedAt, deferFullModule, [
						AllocationMeter.delta("prepare", allocationAtStart, allocationAfterPrepare),
						AllocationMeter.delta("compile", allocationAfterPrepare, allocationAfterCompile),
						AllocationMeter.delta("encode", allocationAfterCompile, allocationAfterEncode),
						AllocationMeter.delta("write", allocationAfterEncode, allocationAfterWrite)
					]);
			progressReport("compiled " + Std.string(request.paths.length) + " source files -> " + request.output);
			return result;
		} catch (error:haxe.Exception) {
			var status = compiler.publicationStatus();
			if (status.hasPendingRevision && status.pendingRevision == result.revision)
				compiler.rejectPublication(result.revision);
			throw error;
		}
	}

	/**
	 * Executes a `--no-output` request: types the program from its entry and reports its warnings, as a compile does, but
	 * generates nothing and writes no file. A type error is thrown as from `compile`.
	 */
	public static function check(request:CompilerRequest, ?progress:String->Void, ?session:CompilerSession,
			?cancellation:CancellationToken, ?diagnostics:String->Void):compiler.Compiler.AnalysisResult {
		if (!request.noOutput)
			throw new InternalError("CompilerDriver.check takes a --no-output request");
		var report = progress == null ? function(message:String) {} : progress,
			progressReport = request.verbosity.atLeast(Verbosity.Normal) ? report : function(message:String) {};
		progressReport("loading " + Std.string(request.paths.length) + " sources");
		var compiler = (session == null ? new CompilerSession() : session).prepare(request, report);
		progressReport("checking entry " + request.entry);
		var result = compiler.analyze(request.entry, cancellation, true),
			printer = new DiagnosticPrinter(request),
			warned = diagnostics == null ? report : diagnostics;
		for (warning in compiler.warnings(result.moduleNames))
			warned(printer.warning(warning));
		progressReport("checked " + Std.string(result.moduleNames.length) + " modules");
		return result;
	}

	/** The `diagnostic` reports: where the request's time and allocations went, phase by phase and pass by pass. */
	static function reportCosts(report:String->Void, result:CompileResult, requestStartedAt:Float, preparedAt:Float,
			compiledAt:Float, backendStartedAt:Float, backendDoneAt:Float, artifactsWrittenAt:Float, stampedAt:Float,
			deferFullModule:Bool, driverAllocations:Array<PhaseAllocation>):Void {
		report("driver phases (ms): prepare="
			+ milliseconds(preparedAt - requestStartedAt)
			+ " compile="
			+ milliseconds(compiledAt - preparedAt)
			+ " encode="
			+ milliseconds(backendDoneAt - backendStartedAt)
			+ " write="
			+ milliseconds(artifactsWrittenAt - backendDoneAt)
			+ (stampedAt < 0 ? "" : " stamp=" + milliseconds(stampedAt - requestStartedAt)
			+ (deferFullModule ? " (patch first)" : "")));
		report(phaseReport(result, backendDoneAt - backendStartedAt));
		if (result.metrics.frontendStages != "")
			report("frontend " + result.metrics.frontendStages);
		report("ir passes (ms/MB/k objects): "
			+ [for (entry in result.metrics.irPassCosts) entry.name + "=" + Math.round(entry.milliseconds) + "/"
			+ Math.round(entry.bytes / 1048576.0) + "/"
			+ Math.round(entry.count / 1000.0)].join(" "));
		report("ir pass functions (read/made/dropped): "
			+ [for (entry in result.metrics.irPassCosts) entry.name + "=" + entry.read + "/" + entry.made + "/"
			+ entry.dropped].join(" "));
		report(allocationReport("compiler allocation phases:", result.metrics.allocationPhases));
		report(allocationReport("driver allocation phases:", driverAllocations));
	}

	/**
	 * A C build (docs/design/AOT_BACKEND.md): the sources go to `OUTPUT.c/`, from which the SDK's CMake package builds the
	 * executable (`haxeon_add_c_executable`). Like a Wasm module, it has no live host: writing it publishes it.
	 */
	static function writeC(owner:compiler.Compiler, result:CompileResult, request:CompilerRequest,
			report:String->Void, preparedAt:Float):CompileResult {
		var compiledAt = Sys.time() * 1000.0;
		// The sources are written in place, under the published output's name rather than a request's staging one: only files
		// whose text changed are written, so a C build (this one's or an app runner's) compiles only those again.
		var published = request.publishedOutput == null ? request.output : request.publishedOutput;
		var files = BackendArtifacts.c(result.artifact).files, directory = published + ".c";
		var changed = writeCSources(files, directory);
		// What the program was compiled from, which a project build reads to know when to compile it again.
		if (request.inputsOutput != null)
			File.saveContent(request.inputsOutput, inputsReport(owner, result.moduleNames, request));
		var writtenAt = Sys.time() * 1000.0;
		report("driver phases (ms): compile=" + milliseconds(compiledAt - preparedAt) + " write-c="
			+ milliseconds(writtenAt - compiledAt));
		report(phaseReport(result, 0));
		var status = owner.publicationStatus();
		if (status.hasPendingRevision && status.pendingRevision == result.revision)
			owner.acknowledgePublication(result.revision);
		report('wrote ${files.length} C sources ($changed changed) -> $directory');
		return result;
	}

	/**
	 * Writes a C build's `files` into `directory`; returns how many changed. A file whose text did not change is not written,
	 * so the C build compiles only what an edit changed. Files of an earlier build that this one lacks are removed.
	 */
	static function writeCSources(files:Array<HlcFile>, directory:String):Int {
		FileSystem.createDirectory(directory);
		var changed = 0, kept:Map<String, Bool> = [];
		for (file in files) {
			var path = directory + "/" + file.path;
			kept.set(file.path, true);
			if (FileSystem.exists(path) && File.getContent(path) == file.content)
				continue;
			File.saveContent(path, file.content);
			changed++;
		}
		for (name in FileSystem.readDirectory(directory))
			if ((StringTools.endsWith(name, ".c") || StringTools.endsWith(name, ".h")) && !kept.exists(name))
				FileSystem.deleteFile(directory + "/" + name);
		return changed;
	}

	/** Keep the last patch available until the live host has had a chance to observe its stamp. */
	/** The modules the compile read, as JSON: `[name, path, sha256 of the module's text]` (for the generated identity table, of its file), sorted by name. */
	static function inputsReport(session:compiler.Compiler, names:Array<String>, request:CompilerRequest):String {
		// Explicit manifests use root-relative diagnostic paths; reports must name the physical input files.
		var physicalPaths:Map<String, String> = [];
		for (path in request.paths)
			physicalPaths.set(SourceManifestLoader.projectPath(path, request.roots, request.packageRoots),
				FileSystem.fullPath(path));
		var sorted = names.copy();
		sorted.sort(Reflect.compare);
		var rows:Array<Array<String>> = [];
		for (name in sorted) {
			var state = session.modules.get(name);
			if (state == null)
				throw new InternalError("Compiled module has no source: " + name);
			// The identity table's text is generated from every other module during the compile; its file is the input.
			var path = physicalPaths.get(state.source.path);
			if (path == null) {
				var standard = haxe.io.Path.join([request.stdlib, state.source.path]);
				path = !haxe.io.Path.isAbsolute(state.source.path)
					&& FileSystem.exists(standard) ? FileSystem.fullPath(standard) : state.source.path;
			}
			var text = state.loadedText;
			rows.push([
				name,
				path,
				build.execution.ContentDigest.makeHex(Bytes.ofString(text))
			]);
			var embedded = state.embeddedInputs.copy();
			embedded.sort((left, right) -> Reflect.compare(left.path, right.path));
			for (input in embedded)
				rows.push([name + ":embed", input.path, input.digest]);
		}
		return Json.stringify(rows);
	}

	/** The stable ID of the entry's `main():Void`, by which an embedded host calls it, with no arguments and no result. */
	static function entryId(result:CompileResult, entry:String):Int {
		var main:Null<compiler.ir.model.IrFunction> = null;
		for (fn in result.ir.functions)
			if (fn.name == "main")
				main = fn;
		if (main == null)
			throw new InternalError('Entry module "$entry" must define a top-level main():Void function');
		if (main.arguments.length != 0 || main.result != compiler.ir.model.Ir.IrType.Void)
			throw new InternalError('Entry function "main" must have signature main():Void');
		var id = BackendArtifacts.hashLink(result.artifact).functionIds.get("main");
		if (id == null)
			throw new InternalError('Entry function "main" has no stable ID');
		return id;
	}

	static function hasPublication(output:String, result:CompileResult):Bool {
		var stamp = output + ".live.stamp";
		return FileSystem.exists(stamp)
			&& FileSystem.exists(output + ".live.json")
			&& FileSystem.exists(output + ".hli")
			&& File.getContent(stamp)
			== Base64.encode(BackendArtifacts.hashLink(result.artifact).runtimeIdentity.sub(4, 16))
			+ ":" + result.revision;
	}

	static function writeModule(result:CompileResult, output:String, session:Null<CompilerSession>):Void {
		var module = BackendArtifacts.hashLink(result.artifact).module;
		if (session == null)
			HlWriter.writeFile(module, output);
		else
			session.writeHashLink(module, output);
	}

	static function deleteIfExists(path:String):Void
		if (FileSystem.exists(path))
			FileSystem.deleteFile(path);

	static function phaseReport(result:CompileResult, outputBackendMs:Float):String {
		var metrics = result.metrics;
		return "compiler phases (reused: " + metrics.reuse + ", linked functions: " + metrics.linkedFunctions
			+ ", of which re-indexed: " + metrics.movedFunctions + ") (ms): snapshot="
			+ milliseconds(metrics.transactionSnapshotMs) + " candidate="
			+ milliseconds(metrics.candidateSetupMs) + " frontend=" + milliseconds(metrics.frontendMs)
			+ " (graph=" + milliseconds(metrics.frontendGraphMs) + " parse=" + milliseconds(metrics.graphParseMs)
			+ " dependencies="
			+ milliseconds(metrics.graphDependencyMs) + " initialization=" + milliseconds(metrics.graphInitializationMs)
			+ " semantic="
			+ milliseconds(metrics.semanticAssemblyMs) + " (alias-setup=" + milliseconds(metrics.semanticAliasMs)
			+ " canonicalization="
			+ milliseconds(metrics.semanticCanonicalizationMs) + " contribution-reuse="
			+ milliseconds(metrics.semanticContributionReuseMs)
			+ " contribution-rebuild=" + milliseconds(metrics.semanticContributionRebuildMs) + " invalidation="
			+ milliseconds(metrics.semanticInvalidationMs) + " semantic-bytes="
			+ Std.string(metrics.semanticAllocatedBytes) + "))" + " typing/lowering="
			+ milliseconds(metrics.typingLoweringMs) + " (analysis=" + milliseconds(metrics.analysisMs)
			+ " (declarations=" + milliseconds(metrics.declarationMs) + " shapes="
			+ milliseconds(metrics.shapeConnectionMs) + " signatures=" + milliseconds(metrics.signatureTypingMs)
			+ ") setup="
			+ milliseconds(metrics.typerSetupMs) + " no-return=" + milliseconds(metrics.typerNoReturnMs) + " metadata="
			+ milliseconds(metrics.typerMetadataMs) + " class-bodies=" + milliseconds(metrics.typerClassBodiesMs)
			+ " function-bodies="
			+ milliseconds(metrics.typerFunctionBodiesMs) + " generated=" + milliseconds(metrics.typerGeneratedMs)
			+ " body-transition="
			+ milliseconds(metrics.bodyTransitionMs) + " assembly=" + milliseconds(metrics.typerAssemblyMs)
			+ " finalization="
			+ milliseconds(metrics.finalizationTransitionMs) + " ir-generation=" + milliseconds(metrics.irGenerationMs)
			+ ")" + " ir-assembly=" + milliseconds(metrics.irAssemblyMs) + " abi="
			+ milliseconds(metrics.abiPlanningMs) + " incremental-backend=" + milliseconds(metrics.backendAssemblyMs)
			+ " (assembler-copy="
			+ milliseconds(metrics.backendAssemblerCopyMs) + " cache-preparation="
			+ milliseconds(metrics.backendCachePreparationMs) + " backend-lowering="
			+ milliseconds(metrics.backendLoweringMs) + " publication=" + milliseconds(metrics.backendPublicationMs)
			+ " snapshots="
			+ milliseconds(metrics.backendSnapshotMs) + " verify=" + milliseconds(metrics.backendVerificationMs)
			+ " lower-metadata="
			+ milliseconds(metrics.backendMetadataMs) + " lower-functions="
			+ milliseconds(metrics.backendFunctionLoweringMs) + " lower-debug="
			+ milliseconds(metrics.backendDebugAssemblyMs) + " lower-finalize="
			+ milliseconds(metrics.backendFinalizationMs) + ") patch="
			+ milliseconds(metrics.patchEncodingMs) + " finalize=" + milliseconds(metrics.finalizeMs)
			+ " output-backend=" + milliseconds(outputBackendMs);
	}

	static inline function milliseconds(value:Float):String
		return Std.string(Math.round(value * 100.0) / 100.0);

	static function allocationReport(prefix:String, phases:Array<PhaseAllocation>):String {
		var values = [prefix];
		for (phase in phases) {
			values.push(phase.name + "-bytes=" + Std.string(phase.bytes));
			values.push(phase.name + "-count=" + Std.string(phase.count));
			values.push(phase.name + "-gcs=" + Std.string(phase.collections));
			values.push(phase.name + "-gc-ms=" + milliseconds(phase.markMicros / 1000.0));
		}
		return values.join(" ");
	}

	/** Defines supplied by the command-line target before user source is analyzed. */
	/**
	 * Renames over an existing file. On Windows a rename fails while another process has the destination open, as the
	 * live host briefly has the stamp every tick, so this retries for up to half a second before giving up.
	 */
	public static function replaceFile(from:String, to:String):Void {
		var attempt = 0;
		while (true) {
			try {
				FileSystem.rename(from, to);
				return;
			} catch (error:haxe.Exception) {
				if (++attempt >= 50)
					throw error;
				Sys.sleep(0.01);
			}
		}
	}

	public static function targetDefines(target:String):Array<String> {
		var result = ["haxeon", "target=" + target], backend = BackendTargets.parse(target);
		switch backend {
			case Wasm32:
				result.push("wasm");
				result.push("wasm32");
			case Wasm64:
				result.push("wasm");
				result.push("wasm64");
			case WasmGc:
				result.push("wasm");
				result.push("wasmgc");
			case HashLink | HashLinkC:
				// Haxe defines `hlc` when it compiles HashLink to C.
				if (backend == HashLinkC)
					result.push("hlc");
				// Standard Haxe's names for a system target with threads, which HashLink's
				// sys.thread provides: code guarding shared state with `#if target.threaded`
				// must not compile its locks away here.
				result.push("hl");
				result.push("sys");
				result.push("target.sys");
				result.push("target.threaded");
			default:
		}
		return result;
	}

	static function dumpFunction(result:CompileResult, index:Int, report:String->Void):Void
		for (fn in BackendArtifacts.hashLink(result.artifact).module.functions)
			if (fn.functionIndex == index) {
				report('function ${fn.functionIndex} type=${fn.type} registers=${[for (register in fn.registers) Std.string(register)].join(",")}');
				for (instructionIndex in 0...fn.opcodes.length)
					report('$instructionIndex\t${Std.string(fn.opcodes[instructionIndex])}');
			}

	/** The live manifest's identities: every function's stable id, by name, in name order, as JSON. */
	/**
	 * The live manifest's identities, `[{"id":N,"name":"..."},...]` in name order, written directly: an edit that moves the ids
	 * writes every one again, which through the reflective printer cost more than encoding the module.
	 */
	static function identitiesJson(ids:Map<String, Int>):String {
		var names = [for (name in ids.keys()) name];
		names.sort(Reflect.compare);
		var text = new StringBuf();
		text.addChar("[".code);
		for (index in 0...names.length) {
			var name = names[index];
			if (index > 0)
				text.addChar(",".code);
			text.add('{"id":');
			text.add(ids.get(name));
			text.add(',"name":');
			text.add(plainJson(name) ? '"' + name + '"' : Json.stringify(name));
			text.addChar("}".code);
		}
		text.addChar("]".code);
		return text.toString();
	}

	/** Whether `text` is printable ASCII without a quote or a backslash, which JSON quotes as it is. */
	static function plainJson(text:String):Bool {
		for (index in 0...text.length) {
			var code = StringTools.fastCodeAt(text, index);
			if (code < 0x20 || code > 0x7e || code == '"'.code || code == "\\".code)
				return false;
		}
		return true;
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

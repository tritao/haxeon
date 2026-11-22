package compiler.compilation;

import compiler.Compiler;
import compiler.core.AllocationMeter;
import compiler.core.InternalError;
import compiler.ffi.FfiRegistry;
import compiler.modules.ModuleGraph;
import compiler.modules.ModuleState;
import compiler.runtime.NativeRegistry;
import compiler.semantic.ModuleAnalyzer;
import haxe.io.Bytes;

/**
 * One build: the state it works on (`state`, a copy of the compiler's that the compiler takes when the build succeeds), the
 * compiler's configuration as the build sees it, and the services the build derives from both (module graph, module analysis,
 * parse metering, target queries).
 */
class CompilationContext {
	/** What the build owns and changes; the compiler's own state stays as it was until it adopts this one. */
	public final state:SessionState;

	/** Parsing, dependency loading and import resolution over `state.modules`. */
	public final moduleAnalyzer:ModuleAnalyzer;

	/** The module graph this build resolves; it starts empty. */
	public final graph = new ModuleGraph();

	/** Modules compiled with every entry (Compiler.addRootModule). */
	public final rootModules:Array<String>;

	public final moduleId:Bytes;
	public final natives:NativeRegistry;
	public final ffi:FfiRegistry;

	/** How the backend assembles: see the fields of the same names on `Compiler`. */
	public final livePatching:Bool;

	public final developmentMetadata:Bool;
	public final backendOptions:Null<compiler.backend.Backend.BackendOptions>;

	/** The passes and self-checks this compile runs (`CompileOptions`). */
	public final options:compiler.CompileOptions;

	/** The reserved field slots of a live build's objects (`Compiler.liveFieldReserve`). */
	public final liveFieldReserve:Int;

	/**
	 * Whether the program must have its executable entry point. A build always needs it; an analysis needs it only when it stands
	 * for a build (`--no-output`), not when the editor types a library.
	 */
	public final requireEntry:Bool;

	/** Why the frontend started over, one entry per module typing found it needed: each restart redoes the whole frontend. */
	public final frontendRestarts:Array<String> = [];

	public final frontendPassFunctions:Array<Int> = [];

	/** One line per frontend pass: where its time and allocation went (see `FrontendCompilation.passReport`). */
	public final frontendPassReports:Array<String> = [];

	/** What each IR pass allocated in this compile, in the order the passes first ran (`IrPassMeter`). */
	public final irPassCosts:Array<compiler.core.IrPassMeter.IrPassCost> = [];

	/** Time and allocation of every `parse` so far; a pass reports the difference, since parsing happens in the graph and in semantic assembly. */
	public var parseMs = 0.0;

	public var parseBytes = 0.0;
	public var parseCount = 0.0;

	final owner:Compiler;
	final defines:Map<String, String>;

	public function new(compiler:Compiler, state:SessionState, ?buildSemanticModels = true, ?requireEntry = false) {
		this.owner = compiler;
		this.requireEntry = requireEntry;
		this.state = state;
		defines = owner.defines;
		rootModules = owner.rootModules.copy();
		moduleId = owner.moduleId;
		natives = owner.natives;
		ffi = owner.ffi;
		livePatching = owner.livePatching;
		developmentMetadata = owner.developmentMetadata;
		backendOptions = owner.backendOptions;
		options = owner.options;
		liveFieldReserve = owner.liveFieldReserve;
		// A copy: the loader remembers the names no root holds, and each build probes again for those.
		moduleAnalyzer = new ModuleAnalyzer(state.modules, state.types, natives, state.compiledOnce, defines,
			owner.sourceLoader.copy(), buildSemanticModels,
			state.declarationOwners, options.keepSession);
	}

	public function parse(module:ModuleState, entry:String, body:Map<String, Bool>, signatures:Map<String, Bool>,
			structural:Map<String, Bool>):Void {
		var startedAt = Sys.time() * 1000.0, before = AllocationMeter.sample();
		moduleAnalyzer.parse(module, entry, body, signatures, structural);
		var after = AllocationMeter.sample();
		parseMs += Sys.time() * 1000.0 - startedAt;
		parseBytes += after.bytes - before.bytes;
		parseCount += after.count - before.count;
	}

	public function identitySalt():String
		return owner.identitySalt();

	public function nativeLayoutTarget():String
		return owner.nativeLayoutTarget();

	public function isWasmTarget():Bool
		return owner.isWasmTarget();

	/**
	 * Whether the build describes its runtime ABI (`RuntimeAbi`): a live build plans against it, a kept session plans its next build
	 * with it, and a Wasm build records it in its state. A plain HashLink build that keeps no session has no reader for it.
	 */
	public function describesRuntimeAbi():Bool
		return livePatching || options.keepSession || isWasmTarget();

	public function targetProfile():compiler.ir.TargetProfile
		return isWasmTarget() ? compiler.ir.TargetProfile.wasm : compiler.ir.TargetProfile.hashLink;

	public function valueArrayTarget():compiler.ir.IrValueLaneLayout.IrValueLaneTarget
		return switch owner.backendTarget {
			case WasmGc: compiler.ir.IrValueLaneLayout.IrValueLaneTarget.WasmGc;
			case Wasm32: compiler.ir.IrValueLaneLayout.IrValueLaneTarget.Wasm32;
			case HashLink | Wasm64: compiler.ir.IrValueLaneLayout.IrValueLaneTarget.HashLink;
		};

	public function exportedFunctions():Array<String>
		return owner.exportedFunctions.copy();


	/**
	 * The functions an instrumented build probes, or null for an ordinary build. `haxeon-instrument=1` turns
	 * instrumentation on; `haxeon-instrument-include` and `haxeon-instrument-exclude` hold comma-separated patterns.
	 */
	public function instrumentScope():Null<compiler.ir.IrInstrumentation.IrInstrumentationScope> {
		var option = defines.get("haxeon-instrument");
		if (option == null || option == "0")
			return null;
		if (option != "1")
			throw new InternalError("haxeon-instrument must be 0 or 1");
		return new compiler.ir.IrInstrumentation.IrInstrumentationScope(compiler.ir.IrInstrumentation
			.IrInstrumentationScope.patterns(defines.get("haxeon-instrument-include")),
			compiler.ir.IrInstrumentation.IrInstrumentationScope
			.patterns(defines.get("haxeon-instrument-exclude")));
	}

	/** The compile-time defines, as one comparable text (they select targets, inlining and instrumentation). */
	public function definesKey():String {
		var names = [for (name in defines.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) name + "=" + defines.get(name)].join("\n");
	}

	/** Length-prefixed components preserve boundaries without binary separators in text keys. */
	public static function dependencyKey(dependencies:Array<String>):String {
		var key = "";
		for (dependency in dependencies)
			key += dependency.length + ":" + dependency;
		return key;
	}

	public static function mapIsEmpty(values:Map<String, Bool>):Bool {
		for (_ in values.keys())
			return false;
		return true;
	}

	public static function copyIndices(source:Map<String, Int>):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (name => index in source)
			result.set(name, index);
		return result;
	}
}

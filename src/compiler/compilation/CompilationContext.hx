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

	/** The functions the frontend typed: those an edit invalidated, or every one in a first build. */
	public var frontendTypedFunctions = 0;

	/** Where the frontend's stages spent their time and allocation (see `FrontendCompilation.stagesReport`). */
	public var frontendStages = "";

	/** What each IR pass allocated in this compile, in the order the passes first ran (`IrPassMeter`). */
	public final irPassCosts:Array<compiler.core.IrPassMeter.IrPassCost> = [];

	/** Time and allocation of every `parse` so far; a pass reports the difference, since parsing happens in the graph and in semantic assembly. */
	public var parseMs = 0.0;

	public var parseBytes = 0.0;
	public var parseCount = 0.0;

	final owner:Compiler;
	final defines:Map<String, String>;
	final buildSemanticModels:Bool;

	public function new(compiler:Compiler, state:SessionState, ?buildSemanticModels = true, ?requireEntry = false) {
		this.owner = compiler;
		this.requireEntry = requireEntry;
		this.buildSemanticModels = buildSemanticModels;
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
			state.declarationOwners, options.keepSession, options.scriptModule);
	}

	/** A context with this one's configuration over `state`. */
	public function over(state:SessionState):CompilationContext
		return new CompilationContext(owner, state, buildSemanticModels, requireEntry);

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

	/** The build's sources, which place the anchors IR locations count from (`SourceAnchors`), with what `history` remembers. */
	public function sourceAnchors(?history:compiler.core.SourceAnchor.SourceAnchorHistory):compiler.core.SourceAnchor
		.SourceAnchors
		return new compiler.core.SourceAnchor
			.SourceAnchors([for (module in state.modules) module.source.path => module.source],
			history);

	/**
	 * What `sourceAnchors` places anchors from, as a short text: the same for the same texts at the same paths, of every module or of
	 * those at `paths`. Two independent 32-bit sums, so the modules' order does not matter and nothing is sorted or allocated per
	 * module.
	 */
	public function sourcesKey(?paths:Map<String, Bool>):String {
		var first = 0, second = 0, count = 0;
		for (module in state.modules) {
			var source = module.source, path = source.path, pathHash:Int = cast 0x811C9DC5;
			if (paths != null && !paths.exists(path))
				continue;
			for (index in 0...path.length)
				pathHash = (pathHash ^ StringTools.fastCodeAt(path, index)) * 16777619;
			first += mix(pathHash ^ source.contentHash());
			second += mix(pathHash + source.secondContentHash() * 31);
			count++;
		}
		return count + ":" + StringTools.hex(first, 8) + StringTools.hex(second, 8);
	}

	/** Spreads every bit of `value` over the result (a 32-bit finalizer), so sums of mixed values rarely collide. */
	static function mix(value:Int):Int {
		value = (value ^ (value >>> 16)) * 0x7FEB352D;
		value = (value ^ (value >>> 15)) * (cast 0x846CA68B:Int);
		return value ^ (value >>> 16);
	}

	/**
	 * Whether the build describes its runtime ABI (`RuntimeAbi`): a live build plans against it, a kept session plans its next build
	 * with it, and a Wasm build records it in its state. A plain HashLink build that keeps no session has no reader for it.
	 */
	public function describesRuntimeAbi():Bool
		return livePatching || options.keepSession || isWasmTarget();

	public function targetProfile():compiler.ir.pipeline.TargetProfile
		return isWasmTarget() ? compiler.ir.pipeline.TargetProfile.wasm : compiler.ir.pipeline.TargetProfile.hashLink;

	public function valueArrayTarget():compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget
		return switch owner.backendTarget {
			case WasmGc: compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget.WasmGc;
			case Wasm32: compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget.Wasm32;
			case HashLink | HashLinkC | Wasm64: compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget.HashLink;
		};

	public function exportedFunctions():Array<String>
		return owner.exportedFunctions.copy();


	/**
	 * The functions an instrumented build probes, or null for an ordinary build. `haxeon-instrument=1` turns
	 * instrumentation on; `haxeon-instrument-include` and `haxeon-instrument-exclude` hold comma-separated patterns.
	 */
	public function instrumentScope():Null<compiler.ir.tools.IrInstrumentation.IrInstrumentationScope> {
		var option = defines.get("haxeon-instrument");
		if (option == null || option == "0")
			return null;
		if (option != "1")
			throw new InternalError("haxeon-instrument must be 0 or 1");
		return new compiler.ir.tools.IrInstrumentation.IrInstrumentationScope(compiler.ir.tools.IrInstrumentation
			.IrInstrumentationScope.patterns(defines.get("haxeon-instrument-include")),
			compiler.ir.tools.IrInstrumentation.IrInstrumentationScope
			.patterns(defines.get("haxeon-instrument-exclude")));
	}

	/** The compile-time defines, as one comparable text (they select targets, inlining and instrumentation). */
	public function definesKey():String {
		var names = [for (name in defines.keys()) name];
		names.sort(Reflect.compare);
		return [for (name in names) name + "=" + defines.get(name)].join("\n");
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

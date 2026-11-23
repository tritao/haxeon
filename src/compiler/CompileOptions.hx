package compiler;

import compiler.NullSafetyRule.NullSafetyMode;

/** The options a request sets, each left out for its default. */
typedef CompileOptionsInit = {
	final ?inlining:Bool;
	final ?loadStoreForwarding:Bool;
	final ?strengthReduction:Bool;
	final ?earlyPrune:Bool;
	final ?checkReuse:Bool;
	final ?wasmLegacyExceptions:Bool;
	final ?reverseTypingOrder:Bool;
	final ?parseThreads:Int;
	final ?keepSession:Bool;
	final ?elaborateGenerics:Bool;
	final ?verifyIr:Bool;
	final ?checkIrBody:Bool;
	final ?phaseCollections:Bool;
	final ?inlineAllocation:Bool;
	final ?nullSafety:Array<NullSafetyRule>;
}

/**
 * What a compile does beyond its sources and target: its optimization passes and its self-checks. Each request states them
 * (`--no-inline`, `--check-reuse`, ...; see `CompilerArguments`), and nothing reads them from the environment or keeps them
 * in a static, so one compile server serves any mix of them and a cached result names the options it was made with.
 */
class CompileOptions {
	/** Inline small functions into their callers (`IrInliner`). */
	public final inlining:Bool;

	/** Forward a value stored to a field or element to the loads that read it back (`IrLoadStoreForwarding`). */
	public final loadStoreForwarding:Bool;

	/** Replace costly arithmetic by cheaper equivalent operations (`IrStrengthReduction`). */
	public final strengthReduction:Bool;

	/**
	 * Prune what the entry cannot reach before the passes run (`IrEntryPrune`). Off only to compare against the unpruned
	 * pipeline: it is a migration reference, not a product option (docs/design/REACHABILITY_WALK.md, "Removal").
	 */
	public final earlyPrune:Bool;

	/**
	 * Check every reuse (cached IR and lowerings, links, modules, memoized inlining and verification, the early prune) against
	 * what a fresh build makes, and fail on a difference. Slow; for the test suites.
	 */
	public final checkReuse:Bool;

	/** Emit Wasm GC exception handling in the legacy try/catch encoding, for hosts without the standard one. */
	public final wasmLegacyExceptions:Bool;

	/**
	 * Type the program's function bodies and field initializers in reverse declaration order. Output must not change: a body's
	 * typing may depend only on the program and the body, never on which bodies were typed before it. For the tests that check so.
	 */
	public final reverseTypingOrder:Bool;

	/**
	 * Threads that parse the modules ahead of the graph walk (`ModuleAnalyzer.prefetchParses`). 1, the default, parses each module
	 * as the walk reaches it. Changes no output, so `key` leaves it out.
	 */
	public final parseThreads:Int;

	/**
	 * Keep what a next build in the same session would reuse: the modules' syntax trees, typed and IR bodies, the pipeline
	 * snapshot, the caches. Off for a process that compiles once (`HaxeonCompiler`), which releases them before the backend and so
	 * peaks lower. Changes no output, so `key` leaves it out.
	 */
	public final keepSession:Bool;

	/**
	 * Make generic code (a generic class's erased methods, each specialization of a generic function or abstract member, each
	 * owner specialization's methods) from its own-parameter typing, passed through the elaboration pass (`GenericElaboration`),
	 * instead of typing each body again for each representation. Output must not change: the test driver builds programs both
	 * ways and compares the bytes (docs/design/GENERIC_TYPING_ONCE.md, stage 2). For the tests that check so, until the pass
	 * replaces the second typing.
	 */
	public final elaborateGenerics:Bool;

	/**
	 * Check the final IR before lowering (`IrVerifier`). On by default and in tests; a release build turns it off (`CompilerArguments`), since a valid compiler only ever makes valid IR.
	 * A cached result names it, so a checked build never reuses an unchecked one.
	 */
	public final verifyIr:Bool;

	/**
	 * Check that every function the verifier checks round-trips through an `IrBody` (docs/design/IR_CORE_COLUMNS.md); implies
	 * `verifyIr`. Off by default: it allocates a copy of every function.
	 */
	public final checkIrBody:Bool;

	/**
	 * Collect at the ends of the compile's phases once enough was allocated since the last collection (`PhaseCollections`), so
	 * the peak is the live data at a boundary plus a phase's allocation, not wherever the byte trigger happens to fire. On by
	 * default for a compile that keeps no session; a session's process keeps the byte trigger alone. Changes no output, so `key`
	 * leaves it out.
	 */
	public final phaseCollections:Bool;

	/**
	 * Allocate objects in a `--target=hlc` build's C from the thread's allocation buffer inline, as the JIT does on Linux.
	 * Off by default: the C build allocates through `hl_alloc_obj` unless asked.
	 */
	public final inlineAllocation:Bool;

	/**
	 * The null-safety rules of the compile (`--null-safety=MODE[:PATH[:shallow]]`): what Haxe's `--macro nullSafety(...)` states,
	 * and what a project's `nullSafety` setting becomes. Empty by default, so only `@:nullSafety` metadata turns the checker on.
	 * They change what a compile reports, so `key` keeps them.
	 */
	public final nullSafety:Array<NullSafetyRule>;

	public function new(?init:CompileOptionsInit) {
		inlining = init == null || init.inlining != false;
		loadStoreForwarding = init == null || init.loadStoreForwarding != false;
		strengthReduction = init == null || init.strengthReduction != false;
		earlyPrune = init == null || init.earlyPrune != false;
		checkReuse = init != null && init.checkReuse == true;
		wasmLegacyExceptions = init != null && init.wasmLegacyExceptions == true;
		reverseTypingOrder = init != null && init.reverseTypingOrder == true;
		parseThreads = init == null || init.parseThreads == null || init.parseThreads < 1 ? 1 : init.parseThreads;
		keepSession = init == null || init.keepSession != false;
		elaborateGenerics = init != null && init.elaborateGenerics == true;
		checkIrBody = init != null && init.checkIrBody == true;
		verifyIr = checkIrBody || init == null || init.verifyIr != false;
		phaseCollections = init == null || init.phaseCollections == null ? !keepSession : init.phaseCollections;
		inlineAllocation = init != null && init.inlineAllocation == true;
		nullSafety = init == null || init.nullSafety == null ? [] : init.nullSafety;
	}

	/** These options with `inlining` set, the others kept. */
	public function withInlining(value:Bool):CompileOptions
		return copy(value, nullSafety);

	/** These options with the null-safety rules `rules`, the others kept: what a language server takes from the project. */
	public function withNullSafety(rules:Array<NullSafetyRule>):CompileOptions
		return copy(inlining, rules);

	function copy(inlining:Bool, nullSafety:Array<NullSafetyRule>):CompileOptions
		return new CompileOptions({
			inlining: inlining,
			loadStoreForwarding: loadStoreForwarding,
			strengthReduction: strengthReduction,
			earlyPrune: earlyPrune,
			checkReuse: checkReuse,
			wasmLegacyExceptions: wasmLegacyExceptions,
			reverseTypingOrder: reverseTypingOrder,
			parseThreads: parseThreads,
			keepSession: keepSession,
			elaborateGenerics: elaborateGenerics,
			verifyIr: verifyIr,
			checkIrBody: checkIrBody,
			phaseCollections: phaseCollections,
			inlineAllocation: inlineAllocation,
			nullSafety: nullSafety
		});

	/** The command-line flags that state these options, the defaults left out; `CompilerArguments` reads them back. */
	public function arguments():Array<String> {
		var flags:Array<String> = [];
		if (!inlining)
			flags.push("--no-inline");
		if (!loadStoreForwarding)
			flags.push("--no-load-store-forwarding");
		if (!strengthReduction)
			flags.push("--no-strength-reduction");
		if (!earlyPrune)
			flags.push("--no-early-prune");
		if (checkReuse)
			flags.push("--check-reuse");
		if (wasmLegacyExceptions)
			flags.push("--wasm-legacy-exceptions");
		if (reverseTypingOrder)
			flags.push("--reverse-typing-order");
		if (parseThreads > 1)
			flags.push(PARSE_THREADS + parseThreads);
		if (!keepSession)
			flags.push(NO_KEEP_SESSION);
		if (elaborateGenerics)
			flags.push("--elaborate-generics");
		if (!verifyIr)
			flags.push(NO_VERIFY_IR);
		if (checkIrBody)
			flags.push(CHECK_IR_BODY);
		if (phaseCollections && keepSession)
			flags.push(PHASE_COLLECTIONS);
		if (!phaseCollections && !keepSession)
			flags.push(NO_PHASE_COLLECTIONS);
		if (inlineAllocation)
			flags.push(INLINE_ALLOCATION);
		for (rule in nullSafety)
			flags.push(NULL_SAFETY + rule.argument());
		return flags;
	}

	static inline final PARSE_THREADS = "--parse-threads=";

	/** Allocates objects inline in a `--target=hlc` build (`inlineAllocation`). */
	public static inline final INLINE_ALLOCATION = "--inline-allocation";

	/** One null-safety rule (`nullSafety`). */
	public static inline final NULL_SAFETY = "--null-safety=";

	public static inline final NO_KEEP_SESSION = "--no-keep-session";
	public static inline final NO_VERIFY_IR = "--no-verify-ir";

	/** Verifies the IR even where the build mode would not (`verifyIr`). */
	public static inline final VERIFY_IR = "--verify-ir";

	/** Checks the `IrBody` round trip of every verified function (`checkIrBody`). */
	public static inline final CHECK_IR_BODY = "--check-ir-body";

	/** Collects at phase ends in a compile that keeps its session too (`phaseCollections`). */
	public static inline final PHASE_COLLECTIONS = "--phase-collections";

	/** Leaves collections to the byte trigger alone in a compile that keeps no session. */
	public static inline final NO_PHASE_COLLECTIONS = "--no-phase-collections";

	/**
	 * One spelling of the options that change what a compile makes, for a session's identity and a cached result's key: their flags,
	 * or "" for the defaults. How many threads parse is left out.
	 */
	public function key():String
		return [
			for (flag in arguments())
				if (!StringTools.startsWith(flag, PARSE_THREADS) && flag != NO_KEEP_SESSION && flag != PHASE_COLLECTIONS
				&& flag != NO_PHASE_COLLECTIONS) flag
		].join(" ");

	/** Whether `argument` is one of the flags `arguments` writes. */
	public static function isFlag(argument:String):Bool
		return switch argument {
			case "--no-inline", "--no-load-store-forwarding", "--no-strength-reduction", "--no-early-prune",
				"--check-reuse",
				"--wasm-legacy-exceptions", "--reverse-typing-order", "--elaborate-generics": true;
			case NO_KEEP_SESSION, NO_VERIFY_IR, VERIFY_IR, CHECK_IR_BODY, PHASE_COLLECTIONS, NO_PHASE_COLLECTIONS,
				INLINE_ALLOCATION: true;
			default: StringTools.startsWith(argument, PARSE_THREADS) || StringTools.startsWith(argument, NULL_SAFETY);
		};

	/** The options the flags among `arguments` state, the others left at their defaults. */
	public static function fromArguments(arguments:Array<String>):CompileOptions
		return new CompileOptions({
			inlining: arguments.indexOf("--no-inline") < 0,
			loadStoreForwarding: arguments.indexOf("--no-load-store-forwarding") < 0,
			strengthReduction: arguments.indexOf("--no-strength-reduction") < 0,
			earlyPrune: arguments.indexOf("--no-early-prune") < 0,
			checkReuse: arguments.indexOf("--check-reuse") >= 0,
			wasmLegacyExceptions: arguments.indexOf("--wasm-legacy-exceptions") >= 0,
			reverseTypingOrder: arguments.indexOf("--reverse-typing-order") >= 0,
			parseThreads: threadsFrom(arguments),
			keepSession: arguments.indexOf(NO_KEEP_SESSION) < 0,
			elaborateGenerics: arguments.indexOf("--elaborate-generics") >= 0,
			verifyIr: arguments.indexOf(NO_VERIFY_IR) < 0 || arguments.indexOf(VERIFY_IR) >= 0,
			checkIrBody: arguments.indexOf(CHECK_IR_BODY) >= 0,
			phaseCollections: arguments.indexOf(PHASE_COLLECTIONS) >= 0 ? true : arguments.indexOf(NO_PHASE_COLLECTIONS)
				>= 0 ? false : null,
			inlineAllocation: arguments.indexOf(INLINE_ALLOCATION) >= 0,
			nullSafety: nullSafetyFrom(arguments)
		});

	/** The rules of the `--null-safety=` flags among `arguments`, in order. A malformed one is a usage error. */
	static function nullSafetyFrom(arguments:Array<String>):Array<NullSafetyRule> {
		var rules:Array<NullSafetyRule> = [];
		for (argument in arguments)
			if (StringTools.startsWith(argument, NULL_SAFETY)) {
				var value = argument.substr(NULL_SAFETY.length), rule = NullSafetyRule.parse(value);
				if (rule == null)
					throw new compiler.core
						.UsageError('Compiler option "$NULL_SAFETY" takes MODE, MODE:PATH or MODE:PATH:shallow, '
						+ 'MODE one of ${NullSafetyMode.NAMES.join(", ")}, not "$value"');
				rules.push(rule);
			}
		return rules;
	}

	/** The value of the last `--parse-threads=N` among `arguments`, or 1. */
	static function threadsFrom(arguments:Array<String>):Int {
		var threads = 1;
		for (argument in arguments)
			if (StringTools.startsWith(argument, PARSE_THREADS)) {
				var value = Std.parseInt(argument.substr(PARSE_THREADS.length));
				if (value != null && value > 0)
					threads = value;
			}
		return threads;
	}
}

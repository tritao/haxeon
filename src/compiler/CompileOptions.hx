package compiler;

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
	final ?typingArenas:TypingArenas;
	final ?phaseCollections:Bool;
	final ?cCompiler:String;
	final ?cSdk:String;
	final ?inlineAllocation:Bool;
}

/** Whether the typer types each class's methods in an arena of its own (`CompileOptions.typingArenas`). */
enum abstract TypingArenas(Int) {
	var Off;
	var On;

	/** On, and a class whose arena is kept fails the compile; `HL_GC_ARENA_SITES=1` names what kept it. */
	var Check;

	/**
	 * As `Check`, and no release may evacuate: every leftover of a class's typing must be placed outside its arena by the code
	 * (docs/design/ARENAS.md, "Data rules for arenas"), not copied out by the runtime.
	 */
	var Strict;
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
	 * Type each class's methods in an arena of its own (`Arena.unit`), released when they are typed, so their temporaries never
	 * reach the collector (docs/design/ARENAS.md). Off by default until every class's arena is released by explicit placement;
	 * `Check` and `Strict` fail the compile when one is kept. Changes no output, so `key` leaves it out.
	 */
	public final typingArenas:TypingArenas;

	/**
	 * Collect at the ends of the compile's phases once enough was allocated since the last collection (`PhaseCollections`), so
	 * the peak is the live data at a boundary plus a phase's allocation, not wherever the byte trigger happens to fire. On by
	 * default for a compile that keeps no session; a session's process keeps the byte trigger alone. Changes no output, so `key`
	 * leaves it out.
	 */
	public final phaseCollections:Bool;

	/**
	 * The C compiler a `--target=hlc` build compiles and links its C with (`cc`, `clang`, `gcc`), or null to write the C sources
	 * only (docs/design/AOT_BACKEND.md). Changes no output of the compile itself, so `key` leaves it out.
	 */
	public final cCompiler:Null<String>;

	/** The C SDK a `--target=hlc` build compiles against: a directory with `include/` and `lib/` (the native build's `hlc-sdk`). */
	public final cSdk:Null<String>;

	/**
	 * Allocate objects in a `--target=hlc` build's C from the thread's allocation buffer inline, as the JIT does when the VM runs
	 * with `HL_JIT_ALLOC_INLINE=1`. Off by default, as on the JIT: both allocate through `hl_alloc_obj` unless asked.
	 */
	public final inlineAllocation:Bool;

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
		typingArenas = init == null || init.typingArenas == null ? Off : init.typingArenas;
		phaseCollections = init == null || init.phaseCollections == null ? !keepSession : init.phaseCollections;
		cCompiler = init == null ? null : init.cCompiler;
		cSdk = init == null ? null : init.cSdk;
		inlineAllocation = init != null && init.inlineAllocation == true;
	}

	/** These options with `inlining` set, the others kept. */
	public function withInlining(value:Bool):CompileOptions
		return new CompileOptions({
			inlining: value,
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
			typingArenas: typingArenas,
			phaseCollections: phaseCollections,
			cCompiler: cCompiler,
			cSdk: cSdk,
			inlineAllocation: inlineAllocation
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
		if (typingArenas == On)
			flags.push(TYPING_ARENAS);
		if (typingArenas == Check)
			flags.push(TYPING_ARENAS_CHECK);
		if (typingArenas == Strict)
			flags.push(TYPING_ARENAS_STRICT);
		if (phaseCollections && keepSession)
			flags.push(PHASE_COLLECTIONS);
		if (!phaseCollections && !keepSession)
			flags.push(NO_PHASE_COLLECTIONS);
		if (cCompiler != null)
			flags.push(C_COMPILER + cCompiler);
		if (cSdk != null)
			flags.push(C_SDK + cSdk);
		if (inlineAllocation)
			flags.push(INLINE_ALLOCATION);
		return flags;
	}

	static inline final PARSE_THREADS = "--parse-threads=";

	/** The C compiler of a `--target=hlc` build (`cCompiler`). */
	public static inline final C_COMPILER = "--c-compiler=";

	/** The C SDK of a `--target=hlc` build (`cSdk`). */
	public static inline final C_SDK = "--c-sdk=";

	/** Allocates objects inline in a `--target=hlc` build (`inlineAllocation`). */
	public static inline final INLINE_ALLOCATION = "--inline-allocation";
	public static inline final NO_KEEP_SESSION = "--no-keep-session";
	public static inline final NO_VERIFY_IR = "--no-verify-ir";

	/** Verifies the IR even where the build mode would not (`verifyIr`). */
	public static inline final VERIFY_IR = "--verify-ir";

	/** Checks the `IrBody` round trip of every verified function (`checkIrBody`). */
	public static inline final CHECK_IR_BODY = "--check-ir-body";

	/** Types each class's methods in an arena of its own (`typingArenas`). */
	public static inline final TYPING_ARENAS = "--typing-arenas";

	/** The same, failing the compile when an arena is kept. */
	public static inline final TYPING_ARENAS_CHECK = "--typing-arenas=check";

	/** The same, without evacuating releases. */
	public static inline final TYPING_ARENAS_STRICT = "--typing-arenas=strict";

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
				if (!StringTools.startsWith(flag, PARSE_THREADS) && !StringTools.startsWith(flag, C_COMPILER)
				&& !StringTools.startsWith(flag, C_SDK) && flag != NO_KEEP_SESSION && flag != TYPING_ARENAS
				&& flag != TYPING_ARENAS_CHECK && flag != TYPING_ARENAS_STRICT && flag != PHASE_COLLECTIONS
				&& flag != NO_PHASE_COLLECTIONS) flag
		].join(" ");

	/** Whether `argument` is one of the flags `arguments` writes. */
	public static function isFlag(argument:String):Bool
		return switch argument {
			case "--no-inline", "--no-load-store-forwarding", "--no-strength-reduction", "--no-early-prune",
				"--check-reuse",
				"--wasm-legacy-exceptions", "--reverse-typing-order", "--elaborate-generics": true;
			case NO_KEEP_SESSION, NO_VERIFY_IR, VERIFY_IR, CHECK_IR_BODY, TYPING_ARENAS, TYPING_ARENAS_CHECK,
				TYPING_ARENAS_STRICT, PHASE_COLLECTIONS, NO_PHASE_COLLECTIONS, INLINE_ALLOCATION: true;
			default: StringTools.startsWith(argument, PARSE_THREADS) || StringTools.startsWith(argument, C_COMPILER)
				|| StringTools.startsWith(argument, C_SDK);
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
			typingArenas: arguments.indexOf(TYPING_ARENAS_STRICT) >= 0 ? Strict : arguments.indexOf(TYPING_ARENAS_CHECK)
				>= 0 ? Check : arguments.indexOf(TYPING_ARENAS) >= 0 ? On : Off,
			phaseCollections: arguments.indexOf(PHASE_COLLECTIONS) >= 0 ? true : arguments.indexOf(NO_PHASE_COLLECTIONS)
				>= 0 ? false : null,
			cCompiler: lastValue(arguments, C_COMPILER),
			cSdk: lastValue(arguments, C_SDK),
			inlineAllocation: arguments.indexOf(INLINE_ALLOCATION) >= 0
		});

	/** The value of the last `PREFIXvalue` among `arguments`, or null. */
	static function lastValue(arguments:Array<String>, prefix:String):Null<String> {
		var found:Null<String> = null;
		for (argument in arguments)
			if (StringTools.startsWith(argument, prefix))
				found = argument.substr(prefix.length);
		return found;
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

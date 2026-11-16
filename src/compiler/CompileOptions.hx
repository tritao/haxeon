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

	public function new(?init:CompileOptionsInit) {
		inlining = init == null || init.inlining != false;
		loadStoreForwarding = init == null || init.loadStoreForwarding != false;
		strengthReduction = init == null || init.strengthReduction != false;
		earlyPrune = init == null || init.earlyPrune != false;
		checkReuse = init != null && init.checkReuse == true;
		wasmLegacyExceptions = init != null && init.wasmLegacyExceptions == true;
		reverseTypingOrder = init != null && init.reverseTypingOrder == true;
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
			reverseTypingOrder: reverseTypingOrder
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
		return flags;
	}

	/** One spelling of the options, for a session's identity and a cached result's key: the flags, or "" for the defaults. */
	public function key():String
		return arguments().join(" ");

	/** Whether `argument` is one of the flags `arguments` writes. */
	public static function isFlag(argument:String):Bool
		return switch argument {
			case "--no-inline", "--no-load-store-forwarding", "--no-strength-reduction", "--no-early-prune",
				"--check-reuse",
				"--wasm-legacy-exceptions", "--reverse-typing-order": true;
			default: false;
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
			reverseTypingOrder: arguments.indexOf("--reverse-typing-order") >= 0
		});
}

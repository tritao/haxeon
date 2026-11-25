package compiler.tools;

typedef PackageSourceRoot = {
	final packageName:String;
	final path:String;
}

/** What a compile server does with the session its last requests built (`--session=`). */
enum abstract CompileSessionMode(String) to String {
	/** Build on what the session holds: the default. A request with other settings starts it over anyway. */
	var Reuse = "reuse";

	/** Start the session over before compiling, so the result depends on the request alone, never on what came before it. */
	var Fresh = "fresh";
}

typedef CompilerRequest = {
	final target:String;
	/** Build mode controls metadata required by development tools. */
	final buildMode:String;
	final defines:Array<String>;
	final output:String;
	/** Where to write the program's API model (docs/design/API_MODEL.md) as JSON. */
	final apiJsonOutput:Null<String>;
	final irOutput:Null<String>;
	/** Where to write the modules this compile read: one `[name, path, sha256 of its text]` per module, sorted by name. */
	final inputsOutput:Null<String>;
	final entry:String;
	final dumpFunction:Int;
	final importMemory:Bool;
	final ?sharedMemory:Bool;
	final memoryBase:Int;
	final memoryContract:Null<String>;
	final wasmMemoryStats:Bool;
	final wasmGcAllocationCount:Bool;
	final wasmGcStress:Bool;
	final wasmRuntimeNeutral:Bool;

	/** The passes and self-checks the compile runs (`--no-inline`, `--check-reuse`, ...). */
	final options:compiler.CompileOptions;

	/** Whether a compile server builds on its session or starts it over (`--session=reuse` or `--session=fresh`). */
	final session:CompileSessionMode;

	/**
	 * What the compile reports besides its diagnostics (`--verbosity=`, default `normal`): presentation only, so it is no part of
	 * a session's identity or of a build action's fingerprint.
	 */
	final verbosity:Verbosity;

	/** How diagnostics are printed (`--diagnostic-format=short|full`, default short): presentation, like `verbosity`. */
	final diagnosticFormat:DiagnosticPrinter.DiagnosticFormat;

	/** Whether the full format is coloured (`--color=always|never`, default never); the caller knows whether a terminal reads it. */
	final color:Bool;

	/** The directory the full format gives paths relative to (`--diagnostic-directory=`): where the user ran the command. */
	final diagnosticDirectory:Null<String>;

	/**
	 * Keep the append-only function, symbol and stable-id history across requests so a running module can be
	 * patched (`haxeon run --watch` of an app it patches). Without it every compile assembles from scratch and its bytes are a
	 * function of the source alone, whatever the session compiled before.
	 */
	final live:Bool;

	/**
	 * Type the program and report its diagnostics without generating or writing anything (`--no-output`, Haxe's name): what
	 * `haxeon check` asks for. `output` is not written.
	 */
	final noOutput:Bool;

	/**
	 * Where `output` is published when the compile server stages it under a temporary name. A live session that starts
	 * without history resumes the module published there, not the staged copy.
	 */
	final ?publishedOutput:String;

	/**
	 * An identity state (`Compiler.exportIdentityState`, an Android `.hcs`) to compile against instead of the session's own
	 * history: the module a device runs, so the result patches or reloads that module. Requires `live`.
	 */
	final ?baseline:String;

	/** Where to write the identity state after the module is published: the baseline a later `baseline` request starts from. */
	final ?baselineOutput:String;

	/** Where to write the stable ID of the entry's `main():Void`, which an embedded host (Android's) calls by that ID. */
	final ?entryIdOutput:String;

	final exports:Array<String>;
	final ffiHeader:Null<String>;
	final ffiLibrary:Null<String>;
	final ffiInterfaces:Array<String>;
	final ffiProjections:Array<String>;
	final roots:Array<String>;

	/**
	 * The standard library (`--stdlib=`, default `stdlib` in the working directory, where the checkout's scripts and tools run):
	 * the CLI names its SDK's (`build.HaxeonSdk.stdlib`), so a compile does not depend on where it runs.
	 */
	final stdlib:String;
	final packageRoots:Array<PackageSourceRoot>;
	final paths:Array<String>;
}

import compiler.Compiler;
import compiler.Compiler.CompileResult;
import compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.runtime.CompilerIntrinsics;
import runtime.Runtime;
import sys.thread.Mutex;
import sys.thread.Thread;

class Completion {
	public var done:Bool = false;
	public var build:Null<CompileResult>;
	public var error:Null<String>;
	public var mutex:Mutex = new Mutex();
	public function new() {}
}

function main():Int {
	var compiler = new Compiler(null, CompilerIntrinsics.configuration());
	compiler.enablePublicationTracking();
	compiler.update("Helper.hx", "class Helper { public static function answer(value:Int = 42):Int return value; }");
	compiler.update("Probe.hx",
		"class Box { public static function answer():Int return 42; } function main():Int return Box.answer() + Helper.answer(0);");
	var build = compiler.compile("Probe");
	var module = Runtime.load(BackendArtifacts.hashLinkBytes(BackendArtifacts.hashLink(build.artifact)).flatten(),
		BackendArtifacts.hashLink(build.artifact).runtimeIdentity);
	var id = Runtime.functionId(module, "main");
	if (id == null) throw "compiled entry has no stable function ID";
	var answer = Runtime.callInt(module, id);
	Runtime.dispose(module);
	compiler.acknowledgePublication(build.revision);
	if (answer != 42) throw "embedded compiler/runtime returned the wrong answer";
	compiler.update("Probe.hx",
		"class Box { public static function answer():Int return 43; } function main():Int return Box.answer() + Helper.answer(0);");
	var completion = new Completion();
	Thread.create(function() {
		try {
			var generated = compiler.compile("Probe");
			completion.mutex.acquire();
			completion.build = generated;
		} catch (error:Dynamic) {
			completion.mutex.acquire();
			completion.error = Std.string(error);
		}
		completion.done = true;
		completion.mutex.release();
	});
	var waited = 0;
	while (true) {
		completion.mutex.acquire();
		var done = completion.done;
		completion.mutex.release();
		if (done) break;
		if (waited++ > 10000) throw "incremental compiler thread timed out";
		Sys.sleep(0.001);
	}
	if (completion.error != null) throw completion.error;
	var next = completion.build;
	if (next == null) throw "incremental thread produced no compile result";
	var replacement = Runtime.load(BackendArtifacts.hashLinkBytes(BackendArtifacts.hashLink(next.artifact)).flatten(),
		BackendArtifacts.hashLink(next.artifact).runtimeIdentity);
	var nextId = Runtime.functionId(replacement, "main");
	if (nextId == null) throw "incremental entry lost its function ID";
	var updated = Runtime.callInt(replacement, nextId);
	Runtime.dispose(replacement);
	if (updated != 43) throw "incremental guest code did not update";
	Sys.println("PASS: package embeds compiler and executes incremental generated code");
	return 0;
}

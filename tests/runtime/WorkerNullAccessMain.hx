import compiler.Compiler;
import compiler.runtime.CompilerIntrinsics;
import compiler.hl.HlWriter;
import sys.io.File;

class WorkerNullAccessMain {
	static function main():Void {
		var source = File.getContent("tests/fixtures/WorkerNullAccess.hx");
		for (inlineEnabled in [false, true]) {
			var compiler = new Compiler();
			CompilerIntrinsics.register(compiler);
			compiler.addSourceRoot("stdlib");
			compiler.configure("worker-null", "test", ["haxeon-inline=" + (inlineEnabled ? "1" : "0")]);
			var input = inlineEnabled ? StringTools.replace(source, 'stack.indexOf("resolveTarget") >= 0', "true") : source;
			for (revision in 0...2) {
				compiler.update("WorkerNullAccess.hx", revision == 0 ? input : StringTools.replace(input, "return 42;", "return 43;"));
				var result = compiler.compile("WorkerNullAccess");
				var path = "out/worker-null-access.hl";
				File.saveBytes(path, HlWriter.encode(result.module));
				var child = new sys.io.Process(".tools/hashlink/hl", [path]);
				var output = child.stdout.readAll().toString() + child.stderr.readAll().toString();
				var status = child.exitCode();
				child.close();
				if (status != 42 + revision)
					throw 'Worker null access (inline=$inlineEnabled, revision=$revision) exited $status: $output';
			}
		}
		Sys.println("PASS: null dereferences throw with source stacks on the main and four worker threads, clean and incremental");
	}
}

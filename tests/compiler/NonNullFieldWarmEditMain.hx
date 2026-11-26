using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.CompileOptions;
import compiler.Compiler;
import compiler.hl.HlCode;
import compiler.hl.HlFunction.HlInstruction;
import compiler.runtime.CompilerIntrinsics;

/**
 * A field never null once constructed (`IrNonNullFields`) lets a reader drop the null check of the value it reads from it. An edit
 * of another function that stores null in the field makes it nullable: a warm build must lower the reader again, though the reader
 * did not change, because the fact it read (`HlLoweringView.nonNull`) has another print, and give the bytes of a fresh build.
 */
class NonNullFieldWarmEditMain {
	static final nodeSource =
		"class Node { public var label:String; public var count:Int; public function new() { label = \"n\"; count = 0; } }";

	/** `read` is recursive so it is not inlined: the reader stays a function of its own that the edit does not touch. */
	static final readerSource =
		"class Reader { public static function read(node:Node, n:Int):Int return n > 0 ? read(node, n - 1) : node.label.length; }";

	/** The second store's receiver is proven by the first, so the edit adds no null check of its own. */
	static final writerSource =
		"class Writer { public static function write(node:Node):Void { node.count = node.count + 1; } }";

	static final mainSource =
		"class Main { static function main():Int { var node = new Node(); Writer.write(node); return Reader.read(node, 1) == 1 ? 42 : 1; } }";

	static function sources():Map<String, String>
		return [
			"Node.hx" => nodeSource,
			"Reader.hx" => readerSource,
			"Writer.hx" => writerSource,
			"Main.hx" => mainSource
		];

	static function main():Void {
		for (check in [false, true]) {
			var files = sources(), compiler = newCompiler(files);
			compiler.options = new CompileOptions({checkReuse: check});
			var first = compiler.compile("Main").artifact.hashLink().module;
			files.set("Writer.hx",
				StringTools.replace(writerSource, "node.count = node.count + 1;",
				"node.count = node.count + 1; node.label = null;"));
			compiler.update("Writer.hx", files.get("Writer.hx"));
			compiler.addSourceRoot("stdlib");
			var warmBuild = compiler.compile("Main").artifact.hashLink(),
				freshBuild = newCompiler(files).compile("Main").artifact.hashLink(),
				warm = warmBuild.module,
				fresh = freshBuild.module;
			var label = check ? " (checked)" : "";
			if (nullChecks(fresh) <= nullChecks(first))
				throw 'the edit made no read of the field checked$label: ${nullChecks(first)} null checks before, ${nullChecks(fresh)} after';
			if (nullChecks(warm) != nullChecks(fresh))
				throw 'the warm build kept the reader lowered with the field never null$label: ${nullChecks(warm)} null checks, a fresh build has ${nullChecks(fresh)}';
			var warmBytes = warmBuild.hashLinkBytes().flatten(), freshBytes = freshBuild.hashLinkBytes().flatten();
			if (warmBytes.compare(freshBytes) != 0)
				throw 'the warm module differs from a fresh one$label (${warmBytes.length} and ${freshBytes.length} bytes)';
		}
		Sys.println("PASS: an edit that makes a field nullable lowers its unchanged readers again");
	}

	static function nullChecks(code:HlCode):Int {
		var count = 0;
		for (fn in code.functions)
			for (instruction in fn.opcodes)
				switch instruction {
					case NullCheck(_):
						count++;
					default:
				}
		return count;
	}

	static function newCompiler(files:Map<String, String>):Compiler {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.livePatching = false;
		compiler.addSourceRoot("stdlib");
		for (path => text in files)
			compiler.update(path, text);
		return compiler;
	}
}

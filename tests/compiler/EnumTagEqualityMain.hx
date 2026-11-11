import compiler.Compiler;
import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrInterpreter;
import compiler.tools.CompilerDriver;

/** The cost of synthesized tag equality is independent of the number of cases and of inlining. */
class EnumTagEqualityMain {
	static function main():Void {
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true])
				check(target, inlining);
		Sys.println("PASS: 32-case tag equality is one scalar comparison on all targets, with inlining off/on");
	}

	static function check(target:String, inlining:Bool):Void {
		var session = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("tag-equality-" + target + inlining, "tag-equality",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
		var cases = [for (index in 0...32) "C" + index + ";"].join(" ");
		session.update("Main.hx",
			'enum Wide implements Hashable { $cases } '
			+ 'struct Pair implements Equatable { public final value:Wide; public function new(value:Wide) this.value=value; } '
			+ 'class Compare { @:expose public static function same(left:Wide, right:Wide):Bool return left==right; } '
			+ 'function main():Int { var first:Null<Wide>=null, second:Null<Wide>=C31; '
			+ 'if (first==second || second!=C31 || !Compare.same(C31,C31) || Compare.same(C0,C31)) return 1; '
			+ 'return new Pair(C31)==new Pair(C31) && new Pair(C0)!=new Pair(C31) ? 42 : 2; }');
		var program = session.compile("Main").ir,
			scalarComparisons = 0,
			kinds = [for (fn in program.functions) fn.name => fn.kind];
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, name, arguments) if ((switch kinds.get(name) {
							case Equality: true;
							default: false;
						})):
							if (arguments.length == 2 && compiler.ir.IrVerifier.sameType(arguments[0].type, EnumTag("Wide")))
								throw "Typed tag equality retained a helper call";
						case Equal(_, left, right) if (fn.name == "Compare.same"):
							if (!compiler.ir.IrVerifier.sameType(left.type, EnumTag("Wide"))
								|| !compiler.ir.IrVerifier.sameType(right.type, left.type))
								throw "Tag equality still compares extracted indices";
							scalarComparisons++;
						case EnumIndex(_, _) if (fn.name == "Compare.same"):
							throw "Direct tag equality retained a dead index extraction";
						case Call(_, _, _) if (fn.name == "Compare.same"):
							throw "Tag comparison must make no allocating or equality calls";
						default:
					}
		if (scalarComparisons != 1 || new IrInterpreter(program).run("main") != 42)
			throw "Tag equality changed its scalar shape or nullable/field semantics";
		var bytes = target == "hl" ? new compiler.backend.hl.HlBackend().compile(program, {target: HashLink, developmentMetadata: false, debugNames: true})
			.bytes : new compiler.backend.wasm.WasmBackend().compile(program, {
				target: target == "wasm32" ? Wasm32 : WasmGc,
				developmentMetadata: false,
				debugNames: true
			}).bytes;
		var temp = Sys.getEnv("TMPDIR");
		if (temp == null)
			temp = "out";
		var path = temp + "/tag-equality-" + target + inlining + "-" + Std.random(0x7fffffff) + (target == "hl" ? ".hl" : ".wasm");
		sys.io.File.saveBytes(path, bytes);
		try {
			var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;'
				+ 'if(e.main()!==42||!e["Compare.same"](32,32)||e["Compare.same"](1,32))throw Error("tag equality");';
			var child = new sys.io.Process(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", js, path]);
			var output = child.stdout.readAll().toString(),
				error = child.stderr.readAll().toString(),
				status = child.exitCode();
			child.close();
			if (status != (target == "hl" ? 42 : 0))
				throw target + ": " + status + " " + output + " " + error;
		} catch (error:Dynamic) {
			sys.FileSystem.deleteFile(path);
			throw error;
		}
		sys.FileSystem.deleteFile(path);
	}
}

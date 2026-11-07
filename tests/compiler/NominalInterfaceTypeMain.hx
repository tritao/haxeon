import compiler.Compiler;
import compiler.Frontend;
import compiler.backend.wasm.WasmBackend;
import compiler.hl.HlWriter;
import compiler.ir.IrInterpreter;
import compiler.tools.CompilerDriver;

class NominalInterfaceTypeMain {
	static function main():Void {
		var source = sys.io.File.getContent("tests/programs/identity-class.hx");
		// Keep the interpreter check independent of the fixture's native allocation census.
		var declarations = source.substr(0, source.indexOf("interface IdentityView"));
		var start = source.indexOf("function main():Int {");
		var body = source.substring(start, source.indexOf(" var a = new IdentityObject", start));
		if (new IrInterpreter(Frontend.compile(declarations + body + " return 42; }")).run("main") != 42)
			throw "Interpreter interface conformance differs from declared inheritance";
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlining in [false, true]) {
				var c = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
				c.addSourceRoot("stdlib");
				c.configure("nominal-" + target + inlining, "nominal",
					CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlining ? 1 : 0)]));
				c.update("Main.hx", source);
				var result = c.compile("Main"), temp = Sys.getEnv("TMPDIR");
				if (temp == null) temp = "out";
				var path = temp + "/nominal-interface-" + target + inlining + (target == "hl" ? ".hl" : ".wasm");
				sys.io.File.saveBytes(path, target == "hl" ? HlWriter.encode(result.module) : new WasmBackend().compile(result.ir, {
					target: target == "wasm32" ? Wasm32 : WasmGc, debugNames: true
				}).bytes);
				var js = 'const e=new WebAssembly.Instance(new WebAssembly.Module(require("fs").readFileSync(process.argv[1]))).exports;const r=e.main();if(r!==42)throw Error("result "+r);';
				var status = Sys.command(target == "hl" ? "scripts/hl" : "node", target == "hl" ? [path] : ["-e", js, path]);
				if (status != (target == "hl" ? 42 : 0)) throw target + " inline=" + inlining + " failed " + status;
				sys.FileSystem.deleteFile(path);
				Sys.println("PASS: nominal interfaces " + target + " inline=" + inlining);
			}
	}
}

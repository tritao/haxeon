import compiler.backend.Backend.BackendTarget;
import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;

/**
 * The `Unreachable` terminator (a method nothing can receive a call for, see the declaration-only slot in docs/REACHABILITY_WALK.md) is a
 * trap, not an exception: on HashLink the fatal runtime native `__unreachable` aborts the process, on Wasm it is `unreachable`. A hand-built
 * program whose `main` calls a function that ends in it must not return, on every target.
 */
class UnreachableTerminatorMain {
	static function program():IrProgram {
		var stub = new IrBuilder();
		stub.argument("this", I32);
		stub.unreachable();
		var main = new IrBuilder();
		var result = main.call("stub", [main.constInt(1)], I32);
		main.returnValue(result);
		var program = new IrProgram("main");
		program.functions = [new IrFunction("main", main.arguments, I32, main.blocks, Ordinary), new IrFunction("stub", stub.arguments, I32, stub.blocks, Ordinary)];
		compiler.ir.IrVerifier.verify(program);
		return program;
	}

	static function main():Void {
		// The terminator survives the canonical IR codec and compares equal after the round trip.
		var original = program(), decoded = compiler.ir.codec.CanonicalIrCodec.decode(compiler.ir.codec.CanonicalIrCodec.encode(original));
		for (index in 0...original.functions.length)
			if (!compiler.ir.codec.IrFunctionStateEquality.same(original.functions[index], decoded.functions[index]))
				throw 'The IR codec changed ${original.functions[index].name}';
		var stubBlock = decoded.functions[1].blocks[0];
		if (stubBlock.terminator == null || !Type.enumEq(stubBlock.terminator.value, Unreachable))
			throw "The decoded stub does not end in Unreachable";
		// HashLink: the process aborts with the runtime's message; the status is not the program's 42 and not a clean exit.
		var hashLink = program();
		hashLink.natives = [{name: "__unreachable", library: "haxeon_runtime", symbol: "__unreachable", arguments: [], result: Void}, {name: "exit", library: "std", symbol: "sys_exit", arguments: [I32], result: Void}];
		var wrapper = new IrBuilder(), value = wrapper.call("main", [], I32);
		wrapper.call("exit", [value], Void);
		wrapper.returnValue(wrapper.constVoid());
		hashLink.functions.push(new IrFunction("run", wrapper.arguments, Void, wrapper.blocks, Ordinary));
		hashLink.entryPoint = "run";
		var path = "out/unreachable-terminator.hl";
		sys.io.File.saveBytes(path, compiler.hl.HlWriter.encode(compiler.ir.hl.HlLower.lower(hashLink)).flatten());
		var process = new sys.io.Process(Sys.getEnv("HAXEON_HASHLINK_DIR") + "/hl", [path]),
			output = process.stdout.readAll().toString() + process.stderr.readAll().toString(), status = process.exitCode();
		process.close();
		// HashLink's fatal error prints its message to stdout and exits with a nonzero status.
		if (status == 0 || status == 42 || output.indexOf("FATAL ERROR : unreachable") < 0)
			throw 'HashLink: an Unreachable terminator did not abort with its fatal message (status $status): $output';
		// Wasm linear and GC: a trap, which the module cannot catch either.
		for (target in [Wasm32, WasmGc]) {
			var backend:BackendTarget = target == Wasm32 ? Wasm32 : WasmGc, wasmPath = 'out/unreachable-terminator-$target.wasm';
			sys.io.File.saveBytes(wasmPath, new compiler.backend.wasm.WasmBackend().compile(program(), {target: backend, debugNames: true}).bytes);
			var js = 'const fs=require("fs"), e=new WebAssembly.Instance(new WebAssembly.Module(fs.readFileSync(process.argv[1]))).exports; try { e.main(); } catch (error) { if (error instanceof WebAssembly.RuntimeError) process.exit(0); throw error; } process.exit(3);';
			var node = new sys.io.Process("node", ["-e", js, wasmPath]), nodeError = node.stderr.readAll().toString(), nodeStatus = node.exitCode();
			node.close();
			if (nodeStatus != 0)
				throw '$target: an Unreachable terminator did not trap (status $nodeStatus): $nodeError';
		}
		Sys.println("PASS: an Unreachable terminator aborts HashLink with a fatal message and traps Wasm linear and GC");
	}
}

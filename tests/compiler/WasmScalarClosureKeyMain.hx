import compiler.Compiler;
import compiler.backend.wasm.WasmScalarAbi;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.Ir.IrValue;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.verify.IrVerifier;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;

/** Scalar closure signatures use the same key when planned by either compiler runtime. */
class WasmScalarClosureKeyMain {
	static function plan(exposed:Bool, nullable:Bool = false):WasmScalarAbi {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.configure("scalar-key", "scalar-key", CompilerDriver.targetDefines("wasm32"));
		var boundary = exposed ? '@:expose function boundary(f:R->Int->Int):Int return 42;' : '';
		compiler.update("Main.hx", 'struct R { public var x:Int; public function new(x:Int) this.x=x; } '
			+ 'function apply(f:R->Int->Int):Int return f(new R(40),2); '
			+ boundary + 'function main():Int return apply((r,n)->r.x+n);');
		var program = compiler.compile("Main").ir;
		if (nullable) {
			var found = false;
			program.functions = [for (fn in program.functions) {
				if (fn.name.indexOf("boundary") >= 0) {
					var arguments = fn.arguments.copy(),
						argument = arguments[0],
						nullableArgument = new IrValue(argument.id, argument.name, Nullable(argument.type));
					arguments[0] = nullableArgument;
					found = true;
					// The argument's debug binding names the retyped value, as the verifier requires.
					fn.withBlocks(fn.blocks, [
						for (binding in fn.debugBindings)
							binding.value.id == argument.id ? {
								identity: binding.identity,
								name: binding.name,
								value: nullableArgument,
								anchor: binding.anchor,
								scopeStart: binding.scopeStart,
								scopeEnd: binding.scopeEnd
							} : binding
					], arguments);
				} else fn;
			}];
			if (!found) throw "Missing exposed boundary";
			IrVerifier.verify(program);
		}
		return new WasmScalarAbi(program, [], false);
	}

	static function main():Void {
		var key = IrTypeIdentity.text(Function([Obj("R"), I32], I32));
		if (!plan(false).scalarClosures.exists(key)) throw "Internal value closure should use scalar ABI";
		if (plan(true).scalarClosures.exists(key)) throw "Exposed value closure must keep its boundary ABI";
		if (plan(true, true).scalarClosures.exists(key)) throw "Nullable exposed closure must keep its boundary ABI";
		Sys.println("PASS: scalar closure keys agree across boundary planning");
	}
}

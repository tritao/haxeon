import compiler.Compiler;
import compiler.backend.wasm.WasmScalarAbi;
import compiler.ir.Ir.IrType;
import compiler.ir.IrTypeIdentity;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;

/** Scalar closure signatures use the same key when planned by either compiler runtime. */
class WasmScalarClosureKeyMain {
	static function plan(exposed:Bool):WasmScalarAbi {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.configure("scalar-key", "scalar-key", CompilerDriver.targetDefines("wasm32"));
		var boundary = exposed ? '@:expose function boundary(f:R->Int->Int):Int return apply(f);' : '';
		compiler.update("Main.hx", 'struct R { public var x:Int; public function new(x:Int) this.x=x; } '
			+ 'function apply(f:R->Int->Int):Int return f(new R(40),2); '
			+ boundary + 'function main():Int return apply((r,n)->r.x+n);');
		return new WasmScalarAbi(compiler.compile("Main").ir, [], false);
	}

	static function main():Void {
		var key = IrTypeIdentity.text(Function([Obj("R"), I32], I32));
		if (!plan(false).scalarClosures.exists(key)) throw "Internal value closure should use scalar ABI";
		if (plan(true).scalarClosures.exists(key)) throw "Exposed value closure must keep its boundary ABI";
		Sys.println("PASS: scalar closure keys agree across boundary planning");
	}
}

import compiler.Compiler;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.hl.HlBackend;
import compiler.backend.wasm.WasmBackend;
import compiler.ir.IrInterpreter;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;

/** A cached value equality helper can keep an enum helper after its owner changes. */
class EnumEqualityHelperReuseMain {
	static function main():Void {
		for (target in ["hl", "wasm32", "wasm-gc"])
			for (inlineEnabled in [false, true])
				check(target, inlineEnabled);
		Sys.println("PASS: enum equality helper has one current owner across module updates on all targets");
	}

	static function check(target:String, inlineEnabled:Bool):Void {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.addStandardLibrarySourceRoot("stdlib");
		compiler.configure("enum-equality-helper-reuse-" + target + "-" + inlineEnabled, "enum-equality-helper-reuse",
			CompilerDriver.targetDefines(target).concat(["haxeon-inline=" + (inlineEnabled ? "1" : "0")]));
		compiler.update("Equatable.hx", "interface Equatable {}");
		compiler.update("Value.hx", "enum Value implements Equatable { Empty; Item(value:Int); }");
		compiler.update("Box.hx", "struct Box implements Equatable { public final value:Value; public function new(value:Value) this.value=value; }");
		compiler.update("A.hx", "class A { public static function same(a:Box, b:Box):Bool return a == b; }");
		compiler.update("Main.hx", "function main():Int return A.same(new Box(Value.Item(1)), new Box(Value.Item(1))) ? 42 : 1;");
		var initial = compiler.compile("Main");
		if (new IrInterpreter(initial.ir).run("main") != 42)
			throw 'initial enum equality call failed for $target inline=$inlineEnabled';

		compiler.update("B.hx", comparisonModule("B"));
		compiler.update("Main.hx", "function main():Int return A.same(new Box(Value.Item(1)), new Box(Value.Item(1))) && B.same(Value.Item(2), Value.Item(2)) ? 42 : 1;");
		var updated = compiler.compile("Main");
		if (new IrInterpreter(updated.ir).run("main") != 42)
			throw 'enum equality helper was not reused for $target inline=$inlineEnabled';
		var helpers = 0;
		for (fn in updated.ir.functions)
			if (StringTools.startsWith(fn.name, "$enum-equals:")) helpers++;
		if (helpers != 1)
			throw 'expected one shared enum equality helper for $target inline=$inlineEnabled, found $helpers';
		compiler.update("Alpha.hx", "enum Alpha { One; }");
		compiler.update("Main.hx", "function main():Int { var extra:Dynamic=Alpha.One; return extra != null && A.same(new Box(Value.Item(1)), new Box(Value.Item(1))) && B.same(Value.Item(2), Value.Item(2)) ? 42 : 1; }");
		updated = compiler.compile("Main");
		if (new IrInterpreter(updated.ir).run("main") != 42)
			throw 'adding an enum changed cached Dynamic equality for $target inline=$inlineEnabled';
		switch target {
			case "hl": new HlBackend().compile(updated.ir, {target: HashLink, debugNames: true});
			case "wasm32": new WasmBackend().compile(updated.ir, {target: Wasm32, debugNames: true});
			case "wasm-gc": new WasmBackend().compile(updated.ir, {target: WasmGc, debugNames: true});
			default: throw 'unsupported test target "$target"';
		}
	}

	static function comparisonModule(name:String):String
		return 'class $name { public static function same(a:Value, b:Value):Bool { var left:Dynamic=a, right:Dynamic=b; return left == right; } }';
}

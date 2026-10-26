import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.Backend.BackendTarget;
import sys.io.File;

class MixedArrayLiteralMain {
	static final prefix = 'class Base { public var value:Int=42; public function new() {} } class Child extends Base { public function new() super(); } ';
	static final cases = [
		'var a:Array<Dynamic>=[1,"hello",true,null]; return a[0]==1 && a[1]=="hello" && a[2]==true && a[3]==null ? 42 : 1;',
		'var d:Dynamic=[1,"hello",true]; var a:Array<Dynamic>=d; return a[0]==1 && a[1]=="hello" && a[2]==true ? 42 : 1;',
		'var a=[1,2.5]; return a[0]+a[1]==3.5 ? 42 : 1;',
		'var a=[2.5,1]; return a[0]+a[1]==3.5 ? 42 : 1;',
		'var a=[null,"hello"]; return a[0]==null && a[1]=="hello" ? 42 : 1;',
		'var a=["hello",null]; return a[0]=="hello" && a[1]==null ? 42 : 1;',
		'var a=[null,42]; var n=a[1]; return n==null ? 1 : n;',
		'var a=[42,null]; var n=a[0]; return n==null ? 1 : n;',
		'var a=[new Base(),new Child()]; return a[1].value;',
		'var a=[new Child(),new Base()]; return a[0].value;',
		'var a:Array<Dynamic>=[[1,"x"],true]; var inner:Array<Dynamic>=a[0]; return inner[1]=="x" && a[1]==true ? 42 : 1;',
		'var n=1; var a=[n,(n=2)+0.5]; return a[0]==1.0 && a[1]==2.5 && n==2 ? 42 : 1;',
		'var d:Dynamic=[]; var a:Array<Dynamic>=d; return a.length==0 ? 42 : 1;'
	];

	static function compiler():Compiler {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addSourceRoot("stdlib");
		return c;
	}

	static function source(body:String):String
		return prefix + 'function main():Int { $body }';

	static function main():Void {
		var warm = compiler();
		for (index in 0...cases.length) {
			for (c in [warm, compiler()]) {
				c.update("Main.hx", source(cases[index]));
				var result = c.compile("Main");
				if (GeneratedProgramRunner.exitCode(result) != 42)
					throw 'Mixed array case $index failed';
				if (c == warm)
					for (target in [Wasm32, WasmGc])
						File.saveBytes('out/mixed-array-$target-$index.wasm', new WasmBackend().compile(result.ir, {target: target, debugNames: true}).bytes);
			}
		}
		File.saveContent("out/mixed-array-count.txt", Std.string(cases.length));
		for (body in [
			'var a=[1,"x"];',
			'var a=["x",1];',
			'var a:Array<Int>=[1,2.5];',
			'var a:Array<Int>=[1,"x"];',
			'var a:Array<String>=["x",true];'
		])
			for (c in [warm, compiler()]) {
				c.update("Main.hx", source(body + ' return 42;'));
				try {
					c.compile("Main");
				} catch (error:CompileError) {
					if (error.diagnostic.code != "E1003")
						throw error;
					continue;
				}
				throw 'Incompatible array accepted: $body';
			}
		var dependency = compiler();
		dependency.update("Helper.hx", "class Helper { public static function value():Float return 2.5; }");
		dependency.update("Main.hx", 'import Helper; function main():Int { var a=[1,Helper.value()]; return a[0]+a[1]==3.5 ? 42 : 1; }');
		if (GeneratedProgramRunner.exitCode(dependency.compile("Main")) != 42)
			throw "Numeric dependency case failed";
		dependency.update("Helper.hx", 'class Helper { public static function value():String return "x"; }');
		try {
			dependency.compile("Main");
		} catch (error:CompileError) {
			if (error.diagnostic.code != "E1003")
				throw error;
			Sys.println("PASS: mixed array context, numeric/nullable/reference joins, boxing, rejection and incremental edits");
			return;
		}
		throw "A dependency edit retained an incompatible element type";
	}
}

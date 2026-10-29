import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.wasm.WasmBackend;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import compiler.hl.HlWriter;
import sys.io.File;

/** Dynamic boundaries and collection callbacks, exercised on every runtime and with a reused compiler. */
class CompilerGapsMain {
	static final programs = [
		'function main():Int {var d:Dynamic=haxe.Json.parse(haxe.Json.stringify({items:[[{value:42}]]}));var x:{items:Array<Array<{value:Int}>>}=d;return x.items[0][0].value;}',
		'function main():Int {var d:Dynamic=haxe.Json.parse(haxe.Json.stringify({items:[{value:42}]}));var x:{items:Array<{value:Int}>}=d;return x.items[0].value;}',
		'function main():Int {var d:Dynamic={value:"bad"};try {var x:{value:Int}=d;return x.value;}catch(e:Dynamic){return 42;}}',
		'function main():Int {var d:Dynamic={value:null};try {var x:{value:Int}=d;return x.value;}catch(e:Dynamic){return 42;}}',
		'function main():Int {var d:Dynamic={value:42};try {var x:{value:String}=d;return 1;}catch(e:Dynamic){return 42;}}',
		'import haxe.Json; function main():Int {var d:Dynamic=Json.parse("{\\"value\\":42}");var x:{value:Int}=d;return x.value;}',
		'function main():Int {var a:Array<Dynamic>=[{value:42},"hello",true];var d=a[0];return d.value;}',
		'function main():Int { var d:Dynamic={value:42}; var x:{value:Int}=d; return x.value; }',
		'function main():Int { var d:Dynamic={value:42}; var x:{value:Int}=cast d; return x.value; }',
		'function main():Int { var d:Dynamic={value:42}; var x=cast(d,{value:Int}); return x.value; }',
		'function main():Int { var a={value:42}; var d:Dynamic=a; return d.value; }',
		'function main():Int { var d:Dynamic={value:42}; return Reflect.field(d,"value"); }',
		'function main():Int { var d:Dynamic={value:1}; Reflect.setField(d,"value",42); return d.value; }',
		'function main():Int { var d:Dynamic={value:42}; var n=Reflect.fields(d).length; if(!Reflect.hasField(d,"value") || n!=1) return 1; return Reflect.deleteField(d,"value") && !Reflect.hasField(d,"value") ? 42 : 1; }',
		'function main():Int { var d:Dynamic={child:{value:42}}; var x:{child:{value:Int}}=d; return x.child.value; }',
		'function main():Int { var d:Dynamic={value:42}; var x:{value:Int,?other:Int}=d; return x.other==null ? x.value : 1; }',
		'function main():Int { var d:Dynamic=null; var x:Null<{value:Int}>=d; return x==null?42:1; }',
		'function main():Int { var d:Dynamic={value:1}; try {var x:{missing:Int}=d;return x.missing;} catch(e:Dynamic) { return 42; } }',
		'function main():Int { var calls=0; var make=()->{calls++;return {value:42};}; var d:Dynamic=make(); var x:{value:Int}=d; return calls==1?x.value:1; }',
		'class Box { public function new(){} public function value():Int return 42; } function box():Box return new Box(); function main():Int return box().value();',
		'function values():Array<Int> return [1,42]; function main():Int {var count=0;var found=values().exists(x->{count++;return x==1;});return found && count==1?42:1;}',
		'function main():Int { var a:Array<String>=[];return !a.exists(x->x=="missing")?42:1; }',
		'function main():Int { var a=[1,2];return !a.exists(x->x==42)?42:1; }',
		'function main():Int { var d:Dynamic={value:42}; var x:{value:Int}=d; x.value=9;return d.value==42?42:1; }',
		'function main():Int { var d:Dynamic={f:(x:Int)->x+1};var x:{f:Int->Int}=d;return x.f(41); }'
	];

	static function create(target:BackendTarget):Compiler {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addSourceRoot("stdlib");
		if (target != HashLink) {
			var name = target == WasmGc ? "wasm-gc" : "wasm32";
			c.configure("gaps:" + name, "gaps:" + name, CompilerDriver.targetDefines(name));
		}
		return c;
	}

	static function main():Void {
		for (target in [HashLink, Wasm32, WasmGc]) {
			var warm = create(target);
			for (index in 0...programs.length)
				for (c in [warm, create(target)]) {
					c.update("Main.hx", programs[index]);
					var result = c.compile("Main");
					if (target == HashLink) {
						if (GeneratedProgramRunner.exitCode(result) != 42)
							throw 'Compiler gap case $index failed';
					} else if (c == warm)
						File.saveBytes('out/compiler-gaps-$target-$index.wasm', new WasmBackend().compile(result.ir, {target: target, debugNames: true})
							.bytes);
				}
		}

		var invalid = [
			{code: "E1016", text: 'typedef Node={value:Int,?next:Node};function main():Int{var d:Dynamic={value:42};var x:Node=d;return x.value;}'},
			{
				code: "E1005",
				text: 'class Box{public var value:Int=42;public function new(){}} function main():Int{var x:Null<Box>=new Box();if(x==null)return 1;[1].exists(v->{x=null;return true;});return x.value;}'
			},
			{code: "E1003", text: 'function main():Int{var a=[1,"hello"];return 42;}'}
		];
		for (target in [HashLink, Wasm32, WasmGc]) {
			var warm = create(target);
			for (test in invalid)
				for (c in [warm, create(target)]) {
					c.update("Main.hx", test.text);
					try
						c.compile("Main")
					catch (error:CompileError) {
						if (error.diagnostic.code != test.code)
							throw error;
						continue;
					}
					throw "An unsafe or unsupported conversion was accepted";
				}
		}
		File.saveContent("out/compiler-gaps-count.txt", Std.string(programs.length));
		Sys.println("PASS: checked Dynamic records, reflection, chained calls and Array.exists, cold and incremental, all targets");
	}
}

import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import compiler.backend.wasm.WasmBackend;
import compiler.backend.Backend.BackendTarget;
import sys.io.File;

class NullReassignmentMain {
	static final prefix = 'class Box { public var value:Int=42; public var child:Null<Box>; public function new() {} } '
		+ 'class Hooks { public static var saved:Null<Void->Void>; public static function fire():Void {var call=saved;if(call!=null) call();} } '
		+ 'class Holder { public var slot:Null<Box>=new Box(); public final saved:Null<Box>=new Box(); public function new() {} } '
		+ 'function invoke(call:Void->Void):Void call(); function invokeGeneric<T>(call:Void->Void, value:T):T {call();return value;} '
		+ 'function readOnly():Void {} '
		+ 'function flag():Bool return true; '
		+ 'function maybe(flag:Bool):Void { if(flag) throw "stop"; } '
		+ 'function clear(h:Holder):Void { h.slot=null; throw "stop"; } ';
	static final valid = [
		'var x:Null<Box>=new Box(); if(x==null) return 1; var saved=x; x=null; return saved.value;',
		'var x:Null<Box>=new Box(); x=null; x=new Box(); return x.value;',
		'var x:Null<Box>=new Box(); x=null; if(x==null) x=new Box(); return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; if(flag()) {x=null;x=new Box();} else x=new Box(); return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; var saved=x; x=null; var read=()->saved.value; return read();',
		'var x:Null<Box>=new Box(); x=null; (x=new Box()); return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; var saved=x; try {x=null;throw "stop";} catch(e:Dynamic) {} return saved.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {x=null;throw "stop";} catch(e:Dynamic) {x=new Box();} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {throw "stop";} catch(e:Dynamic) {} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {var x:Null<Box>=null;throw "stop";} catch(e:Dynamic) {} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {var unused=()->{x=null;};throw "stop";} catch(e:Dynamic) {} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {x=new Box();} catch(e:Dynamic) {return 1;} return x.value;',
		'var h=new Holder(); if(h.saved==null) return 1; try {clear(h);} catch(e:Dynamic) {} return h.saved.value;',
		'var h=new Holder(); if(h.slot==null) return 1; try {var ignored=1;} catch(e:Dynamic) {} return h.slot.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; var reset=()->{x=null;}; try {reset();throw "stop";} catch(e:Dynamic) {if(x==null) x=new Box();} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {x=new Box();throw "stop";} catch(e:Dynamic) {} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {try {x=new Box();throw "stop";} catch(e:Dynamic) {throw e;}} catch(e:Dynamic) {} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; var saved=x; saved.child=new Box(); if(saved.child==null) return 1; try {x=null;throw "stop";} catch(e:Dynamic) {} return saved.child.value;',
		'var m=new Map<String,Box>(); m.set("a",new Box()); var key="a"; var replace=()->{key="missing";}; if(m.exists(key)) { replace(); if(m.exists(key)) return m.get(key).value; return 42; } return 1;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; var reset=()->{x=null;}; readOnly(); return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; var saved=x; invoke(()->{x=null;}); return saved.value;',
		'var x:Null<Box>=new Box(); var reset=()->{x=null;}; for(i in 0...2) {if(x==null) x=new Box(); var value=x.value;invoke(reset);} return 42;',
		'var x:Null<Int>=null; x=42; var read=()->{if(x==null) return 1;return x;}; if(x==null) return 1; invoke(()->{}); return x;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {x=new Box();} catch(e:Dynamic) {return 1;} invoke(()->{}); return x.value;',
		'var x:Null<Box>=new Box(); var reset=()->{x=null;}; if(x==null) return 1; var items=[2,1];items.sort((a,b)->a-b);return x.value;',
		'var x:Null<Int>=42; var y=x; x=null; if(y==null) return 1; return y;'
	];
	static final invalid = [
		'var x:Null<Box>=new Box(); if(x==null) return 1; var items=[2,1]; items.sort((a,b)->{x=null;return a-b;}); return x.value;',
		'var x:Null<Box>=new Box(); Hooks.saved=()->{x=null;}; if(x==null) return 1; var forward=()->Hooks.fire(); forward(); return x.value;',
		'var x:Null<Box>=new Box(); var reset=()->{x=null;}; if(x==null) return 1; for(i in 0...2) {var value=x.value;invoke(reset);} return 42;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; invoke(()->{x=null;}); return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; var ignored=invokeGeneric(()->{x=null;},1); return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {invoke(()->{x=null;});throw "stop";} catch(e:Dynamic) {} return x.value;',
		'var m=new Map<String,Box>(); m.set("a",new Box()); var key="a"; var replace=()->{key="missing";}; if(m.exists(key)) { replace(); return m.get(key).value; } return 1;',
		'var m=new Map<String,Box>(); m.set("a",new Box()); var key="a"; var replace=()->{key="missing";}; if(m.exists(key)) { try {replace();throw "stop";} catch(e:Dynamic) {} return m.get(key).value; } return 1;',
		'var x:Null<Box>=new Box(); if(x!=null) {x=null;return x.value;} return 1;',
		'var x:Null<Box>=new Box(); if(x!=null) {(x=null);return x.value;} return 1;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; if(flag()) x=null; return x.value;',
		'var x:Null<Box>=new Box(); var reset=()->{x=null;}; if(x==null) return 1; reset(); return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {x=null;throw "stop";} catch(e:Dynamic) {} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {x=null;throw "stop";} catch(e:Dynamic) {return x.value;} return 1;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {x=null;maybe(true);x=new Box();} catch(e:Dynamic) {} return x.value;',
		'var x:Null<Box>=new Box(); var reset=()->{x=null;}; if(x==null) return 1; try {reset();maybe(true);x=new Box();} catch(e:Dynamic) {} return x.value;',
		'var x:Null<Box>=new Box(); if(x==null) return 1; try {try {x=null;throw "stop";} catch(e:Dynamic) {throw e;}} catch(e:Dynamic) {} return x.value;',
		'var h=new Holder(); if(h.slot==null) return 1; try {h.slot=null;throw "stop";} catch(e:Dynamic) {} return h.slot.value;',
		'var h=new Holder(); if(h.slot==null) return 1; try {clear(h);} catch(e:Dynamic) {} return h.slot.value;',
		'var x:Null<Int>=42; if(x==null) return 1; try {x=null;throw "stop";} catch(e:Dynamic) {} var y:Int=x; return y;'
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
		for (index in 0...valid.length)
			for (c in [warm, compiler()]) {
				c.update("Main.hx", source(valid[index]));
				var result = c.compile("Main");
				if (GeneratedProgramRunner.exitCode(result) != 42)
					throw 'Valid null reassignment $index returned the wrong result';
				if (c == warm)
					for (target in [Wasm32, WasmGc])
						File.saveBytes('out/null-reassignment-$target-$index.wasm',
							new WasmBackend().compile(result.ir, {target: target, debugNames: true}).bytes);
			}
		File.saveContent("out/null-reassignment-count.txt", Std.string(valid.length));
		for (index in 0...invalid.length)
			for (c in [warm, compiler()]) {
				c.update("Main.hx", source(invalid[index]));
				try {
					c.compile("Main");
				} catch (e:CompileError) {
					if (e.diagnostic.code != "E1005" && e.diagnostic.code != "E1002")
						throw e;
					continue;
				}
				throw 'Unsafe null reassignment $index was accepted';
			}
		Sys.println("PASS: null reassignment, saved copies, captures, shadowing and exceptional flow, clean and incremental");
	}
}

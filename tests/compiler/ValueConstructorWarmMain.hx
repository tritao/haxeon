import compiler.Compiler;
import compiler.tools.CompilerDriver;
import compiler.hl.HlWriter;
import compiler.runtime.CompilerIntrinsics;

class ValueConstructorWarmMain {
	static final five = 'struct Point { public var a:Int; public var b:Int; public var c:Int; public var d:Int; public var e:Int; public var f:Int; public function new(items:Array<Int>) { a=items==null?0:items[0]; b=items==null?0:items[0]; c=items==null?0:items[0]; d=items==null?0:items[0]; e=items==null?0:items[0]; f=items[0]; } }';
	static final six = StringTools.replace(five, 'f=items[0];', 'f=items==null?0:items[0];');
	static final changed = StringTools.replace(six, 'public var f:Int;', 'public var f:Int; public var g:Int;');
	static final mainSource = 'class Holder { public var p:Point; public function new() {} } class Main { static var items:Array<Int>; static var holder:Holder; static function main():Int { if(items==null) items=[7]; if(holder==null) holder=new Holder(); var before=hl.Gc.totalAllocated(); var sum=0; for(i in 0...1024) { holder.p=new Point(items); sum+=holder.p.a+holder.p.b+holder.p.c+holder.p.d+holder.p.e+holder.p.f; } if(sum!=43008) return 2; if(hl.Gc.totalAllocated()!=before) return 3; return 42; } }';
	static var useInlining:Bool = false;

	static function compiler(source:String, live:Bool):Compiler {
		var c = new Compiler(null, CompilerIntrinsics.configuration());
		c.livePatching = live;
		c.configure('value-warm', 'value-warm', CompilerDriver.targetDefines('hl').concat(['haxeon-inline=' + (useInlining ? 1 : 0)]));
		c.addSourceRoot('stdlib');
		c.update('Main.hx', mainSource);
		c.update('Point.hx', source);
		return c;
	}

	static function warm(before:String, after:String, checked:Bool):Void {
		Sys.putEnv('HAXEON_CHECK_REUSE', checked ? '1' : '0');
		var c = compiler(before, false);
		c.compile('Main');
		c.update('Point.hx', after);
		c.addSourceRoot('stdlib');
		var result = c.compile('Main');
		var fresh = compiler(after, false).compile('Main');
		if (HlWriter.encode(result.module).flatten().compare(HlWriter.encode(fresh.module).flatten()) != 0)
			throw 'warm module differs';
		if (StringTools.startsWith(result.metrics.reuse, 'ir'))
			throw 'reused IR after constructor edit';
	}

	static function main():Void {
		for (inlining in [false, true]) {
			useInlining = inlining;
			for (checked in [false, true]) {
				warm(five, six, checked);
				warm(six, five, checked);
			}
			liveCheck();
		}
		Sys.println('PASS: constructor warm edits and value layout change');
	}

	static function liveCheck():Void {
		Sys.putEnv('HAXEON_CHECK_REUSE', '1');
		var live = compiler(six, true);
		var initial = live.compile('Main');
		var module = runtime.Runtime.load(HlWriter.encode(initial.module).flatten(), initial.runtimeIdentity);
		var id = initial.functionIds.get('Main.main');
		if (id == null)
			id = initial.functionIds.get('main');
		if (id == null)
			throw 'missing live entry';
		var initialResult = runtime.Runtime.callInt(module, id);
		if (initialResult != 42)
			throw 'initial live result: ' + initialResult;
		live.update('Point.hx', five);
		live.addSourceRoot('stdlib');
		var patch = live.compile('Main');
		if (patch.requiresReload || patch.patchBytes == null)
			throw 'constructor body edit did not yield a patch';
		runtime.Runtime.patchSet(module, new runtime.PatchSet(initial.revision, patch.revision, patch.patchBytes, patch.changedFunctions));
		if (runtime.Runtime.callInt(module, id) != 42)
			throw 'patched live result differs';
		live.update('Point.hx', changed);
		live.addSourceRoot('stdlib');
		var result = live.compile('Main');
		if (!result.requiresReload || result.patchBytes != null)
			throw 'value layout change did not refuse a live patch';
		var reasons = [for (reason in result.reloadReasons) Std.string(reason)].join(',');
		if (reasons.indexOf('Point') < 0)
			throw 'layout reload did not name Point: ' + reasons;
		if (runtime.Runtime.callInt(module, id) != 42)
			throw 'old live domain changed after incompatible layout';
		runtime.Runtime.dispose(module);
	}
}

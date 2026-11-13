import compiler.Compiler;
import compiler.hl.HlWriter;
import compiler.hl.HlType;
import compiler.runtime.CompilerIntrinsics;
import compiler.tools.CompilerDriver;
import runtime.PatchSet;
import runtime.Runtime;

/** A value embedded in an object gives HashLink a packed parameterized type in the loaded prefix. */
class PackedValuePatchMain {
	static final point = 'struct Point { public var value:Int; public function new(value:Int) this.value=value; }';
	static final mainSource = 'class Holder { public var point:Point; public function new() {} } class Main { static function main():Int { var h=new Holder(); h.point=new Point(40); return h.point.value; } }';

	static function main():Void {
		for (inlining in [false, true])
			check(inlining);
		Sys.println('PASS: live patches with packed value fields');
	}

	static function check(inlining:Bool):Void {
		var compiler = new Compiler(null, CompilerIntrinsics.configuration());
		compiler.configure('packed-patch-' + inlining, 'packed-patch', CompilerDriver.targetDefines('hl').concat(['haxeon-inline=' + (inlining ? 1 : 0)]));
		compiler.addSourceRoot('stdlib');
		compiler.update('Point.hx', point);
		compiler.update('Main.hx', mainSource);
		var first = compiler.compile('Main');
		var packed = false;
		for (type in first.module.types)
			switch type {
				case Parameterized(kind, _) if (kind == HlType.Packed):
					packed = true;
				default:
			}
		if (!packed)
			throw 'the fixture has no packed type';
		var live = Runtime.load(HlWriter.encode(first.module).flatten(), first.runtimeIdentity);
		try {
			var id = first.functionIds.get('Main.main');
			if (id == null || Runtime.callInt(live, id) != 40)
				throw 'wrong initial value';
			compiler.update('Point.hx', StringTools.replace(point, 'this.value=value;', 'this.value=value+2;'));
			compiler.addSourceRoot('stdlib');
			var next = compiler.compile('Main');
			if (next.requiresReload || next.patchBytes == null)
				throw 'body edit did not produce a patch';
			Runtime.patchSet(live, new PatchSet(first.revision, next.revision, next.patchBytes, next.changedFunctions));
			if (Runtime.callInt(live, id) != 42)
				throw 'wrong patched value';
		} catch (error:Dynamic) {
			Runtime.dispose(live);
			throw error;
		}
		Runtime.dispose(live);
	}
}

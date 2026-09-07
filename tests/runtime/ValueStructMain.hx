import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.hl.persistence.HlTypeDefStateCodec;
import sys.io.File;

class ValueStructMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Main.hx",
			"@:value class Vec2 { public var x:Float; public var y:Float; public function new(x:Float, y:Float) { this.x = x; this.y = y; } } class Holder { public var point:Vec2; public function new(point:Vec2) { this.point = point; } } function main():Int { var holder = new Holder(new Vec2(20.0, 22.0)); return holder.point.x + holder.point.y == 42.0 ? 42 : 0; }");
		var result = compiler.compile("Main"),
			foundStructure = false,
			foundPacked = false;
		for (type in result.module.types)
			switch type {
				case Structure(_, _, _, _, _):
					foundStructure = true;
				case Parameterized(kind, _):
					if (kind == HlType.Packed)
						foundPacked = true;
				default:
			}
		if (!foundStructure || !foundPacked)
			throw "value structures must emit HSTRUCT and packed embedded fields";
		var restored = HlTypeDefStateCodec.decode(HlTypeDefStateCodec.encode(result.module.types), result.module.strings.length, result.module.globals.length);
		if ([
			for (type in restored)
				if (switch type {
						case Structure(_, _, _, _, _): true;
						default: false;
					}) type
		].length != 1)
			throw "persisted backend state lost the value structure representation";
		var representationChange = new Compiler();
		representationChange.update("Main.hx", "class Point { public var x:Int; } function main():Int return 0;");
		representationChange.compile("Main");
		representationChange.update("Main.hx", "@:value class Point { public var x:Int; } function main():Int return 0;");
		if (!representationChange.compile("Main").requiresReload)
			throw "changing object/value representation must require a reload";
		expectCompileError("class Base {} @:value class Point extends Base {} function main():Int return 0;", "cannot extend");
		expectCompileError("interface Located {} @:value class Point implements Located {} function main():Int return 0;", "cannot implement");
		File.saveBytes(Sys.args()[0], HlWriter.encode(result.module));
	}

	static function expectCompileError(source:String, expected:String):Void {
		var compiler = new Compiler();
		compiler.update("Main.hx", source);
		try {
			compiler.compile("Main");
			throw 'expected compile error containing "$expected"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(expected) < 0)
				throw error;
		}
	}
}

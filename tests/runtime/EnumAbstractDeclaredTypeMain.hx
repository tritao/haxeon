import compiler.hl.HlWriter;
import compiler.Compiler;
import runtime.Runtime;

/**
 * Two enum abstracts over Int can declare the same value name. Where the other side of the expression is declared
 * as one of them (a parameter, local, field, or call result), a bare value name belongs to that abstract.
 */
class EnumAbstractDeclaredTypeMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Left.hx", "enum abstract Left(Int) from Int to Int { var Shared = 1; var OnlyLeft = 3; }");
		compiler.update("Right.hx", "enum abstract Right(Int) from Int to Int { var Shared = 20; var OnlyRight = 4; }");
		compiler.update("Main.hx",
			"function switchLeft(v:Left):Int return switch v { case Shared: 100; default: 0; }\n"
			+ "function switchRight(v:Right):Int return switch v { case Shared: 1000; default: 0; }\n"
			+ "function equalLeft(v:Left):Int return v == Shared ? 1 : 0;\n"
			+ "function notEqualRight(v:Right):Int return v != Shared ? 1 : 0;\n"
			+ "function takeLeft(v:Left):Int return v;\n"
			+ "function takeRight(v:Right):Int return v;\n"
			+ "function passLeft():Int return takeLeft(Shared);\n"
			+ "function passRight():Int return takeRight(Shared);\n"
			+ "function localLeft():Int { var v:Left = Shared; return v; }\n"
			+ "function localRight():Int { var v:Right = Shared; return v; }\n"
			+ "function returnRight():Right return Shared;\n"
			+ "function returned():Int return returnRight();\n"
			+ "function switchCall():Int return switch returnRight() { case Shared: 7; default: 0; }\n"
			+
			"class Holder { public static final left:Left = Shared; public static final right:Right = Shared; public static var current:Right = Right.Shared; "
			+ "public var own:Left = Shared; public function new() {} }\n"
			+ "function fields():Int return Holder.left * 1000 + Holder.right;\n"
			+ "function switchField():Int return switch Holder.current { case Shared: 5; default: 0; }\n"
			+ "function switchMember():Int return switch new Holder().own { case Shared: 9; default: 0; }\n"
			+ "function callSwitchLeft():Int return switchLeft(1);\n"
			+ "function callSwitchRight():Int return switchRight(20);\n"
			+ "function callEqualLeft():Int return equalLeft(1);\n"
			+ "function callNotEqualRight():Int return notEqualRight(20);\n"
			+
			"function main():Int return callSwitchLeft() + callSwitchRight() + callEqualLeft() + callNotEqualRight() + passLeft() + passRight() + localLeft() + localRight() + returned() + switchCall() + fields() + switchField() + switchMember();");
		var result = compiler.compile("Main"),
			live = Runtime.load(HlWriter.encode(result.module), result.runtimeIdentity);
		function call(name:String, expected:Int):Void {
			var actual = Runtime.callInt(live, result.functionIds.get("Main." + name));
			if (actual != expected)
				throw '$name returned $actual, expected $expected';
		}
		call("callSwitchLeft", 100);
		call("callSwitchRight", 1000);
		call("callEqualLeft", 1);
		call("callNotEqualRight", 0);
		call("passLeft", 1);
		call("passRight", 20);
		call("localLeft", 1);
		call("localRight", 20);
		call("returned", 20);
		call("switchCall", 7);
		call("fields", 1020);
		call("switchField", 5);
		call("switchMember", 9);
		Runtime.dispose(live);

		// Declared as Int, the expected type no longer says which abstract: still ambiguous, and still an error.
		compiler = new Compiler();
		compiler.update("Left.hx", "enum abstract Left(Int) from Int to Int { var Shared = 1; }");
		compiler.update("Right.hx", "enum abstract Right(Int) from Int to Int { var Shared = 20; }");
		compiler.update("Main.hx", "function take(v:Int):Int return v; function main():Int return take(Shared) + Left.Shared + Right.Shared;");
		var rejected = false;
		try {
			compiler.compile("Main");
		} catch (error:Dynamic) {
			rejected = Std.string(error).indexOf("Ambiguous enum abstract value") >= 0;
		}
		if (!rejected)
			throw "An Int-typed position cannot choose between two enum abstracts that declare the value";
		Sys.println("PASS: a declared enum abstract type decides which abstract a bare value name belongs to");
	}
}

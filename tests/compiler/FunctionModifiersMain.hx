import compiler.Compiler;
import compiler.ir.IrFunction;
import compiler.tools.CompilerDriver;

/**
 * `inline` and `@:keep` reach the lowered function whatever path the declaration takes: an inferred result or argument, a class method,
 * an abstract method, and a body edit that reuses the validated signatures. Each of these passes copies the function, and they used to
 * drop the modifiers.
 */
class FunctionModifiersMain {
	static function main():Void {
		var session = new Compiler(null, compiler.runtime.CompilerIntrinsics.configuration());
		session.addStandardLibrarySourceRoot("stdlib");
		session.configure("function-modifiers", "function-modifiers", CompilerDriver.targetDefines("hl"));
		session.update("Main.hx",
			"import Edited.Length; "
			+ "inline function inlineExplicit():Int return 1; "
			+ "inline function inlineInferred() return 2; "
			+ "inline function inlineArgument(value = 3):Int return value; "
			+ "@:keep function keptExplicit():Int return 4; "
			+ "@:keep function keptInferred() return 5; "
			+ "@:keep function keptVoid() {} "
			+ "@:keep function keptArgument(value = 6):Int return value; "
			+ "class C { public static inline function inlineExplicit():Int return 7; public static inline function inlineInferred() return 8; "
			+ "@:keep public static function keptInferred() return 9; } "
			+ "abstract Meters(Int) { public inline function new(value:Int) this = value; public inline function raw():Int return this; "
			+ "public static inline function zero():Int return 0; @:keep public static function kept():Int return 10; } "
			+ "function main():Int return inlineExplicit() + inlineInferred() + inlineArgument() + C.inlineExplicit() + C.inlineInferred() "
			+ "+ new Meters(1).raw() + Meters.zero() + Edited.inlineMethod() + Length.zero();");
		session.update("Edited.hx", edited(1));
		var inlined = [
			"Main.inlineExplicit",
			"Main.inlineInferred",
			"Main.inlineArgument",
			"C.inlineExplicit",
			"C.inlineInferred",
			"Meters.zero",
			"Edited.inlineMethod",
			"Length.zero"
		];
		var kept = [
			"Main.keptExplicit",
			"Main.keptInferred",
			"Main.keptVoid",
			"Main.keptArgument",
			"C.keptInferred",
			"Meters.kept",
			"Edited.keptMethod",
			"Length.kept"
		];
		// Abstract instance members are lowered as their (non-generic) specializations.
		for (name in ["Meters.new", "Meters.raw"])
			inlined.push("$" + 'generic:$name[]<>');
		check(session.compile("Main").ir.functions, "initial build", inlined, kept);
		// Only explicitly typed bodies of Edited.hx change, so the semantic program is reused with the new bodies.
		session.update("Edited.hx", edited(2));
		check(session.compile("Main").ir.functions, "body edit", inlined, kept);
		Sys.println("PASS: inline and @:keep survive inferred signatures, class and abstract methods, and body edits");
	}

	static function edited(revision:Int):String
		return 'class Edited { public static inline function inlineMethod():Int return $revision; '
			+ '@:keep public static function keptMethod():Int return $revision; } '
			+ 'abstract Length(Int) { public static inline function zero():Int return $revision; '
			+ '@:keep public static function kept():Int return $revision; }';

	static function check(functions:Array<IrFunction>, phase:String, inlined:Array<String>, kept:Array<String>):Void {
		var byName = [for (fn in functions) fn.name => fn];
		for (name in inlined)
			expect(byName.exists(name) && byName.get(name).inlineHint, '$phase: $name should carry the inline hint');
		for (name in kept)
			expect(byName.exists(name) && byName.get(name).retention == IrRetention.Keep,
				'$phase: $name should be kept');
	}

	static function expect(condition:Bool, message:String):Void {
		if (!condition)
			throw message;
	}
}

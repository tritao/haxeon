import compiler.Compiler;
import compiler.core.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;

/**
 * Making an exception changes nothing anyone can see (`@:pure` on haxe.Exception's constructor), and neither does making a
 * subclass whose constructors only set their own fields: a function that throws one keeps the null checks of its callers.
 * A subclass whose constructor has an effect does not.
 */
class ExceptionPurityMain {
	static final shared = [
		'class Box { public final n:Int; public function new(n:Int) this.n = n; }',
		'class Holder { public var value:Null<Box>; public function new() value = new Box(2); }'
	];

	static function program(failure:String):String
		return shared.concat([
			failure,
			'function check(n:Int):Int { if (n < 0) throw new Failure("negative"); return n; }',
			'function main():Int { var holder = new Holder(); if (holder.value == null) return 0; return check(holder.value.n) + holder.value.n; }'
		]).join("\n");

	static function main():Void {
		compile(program('class Failure extends haxe.Exception {}'));
		compile(program('class Failure extends haxe.Exception { public final code:Int; public function new(message:String) { super(message); code = 3; } }'));
		compile(program('class Base extends haxe.Exception {} class Failure extends Base {}'));
		var rejected:Null<String> = null;
		try
			compile(program('class Failure extends haxe.Exception { public static var made = 0; public function new(message:String) { super(message); made++; } }'))
		catch (error:CompileError)
			rejected = error.diagnostic.message;
		if (rejected == null || rejected.indexOf('the null check on "holder.value" no longer holds') < 0)
			throw 'A subclass whose constructor has an effect kept the caller\'s null check: ${rejected == null ? "it compiled" : rejected}';
		Sys.println("PASS: making an exception keeps flow facts, unless its constructor has an effect");
	}

	static function compile(source:String):Void {
		var c = new Compiler();
		CompilerIntrinsics.register(c);
		c.addStandardLibrarySourceRoot("stdlib");
		c.update("Main.hx", source);
		c.analyze("Main");
	}
}

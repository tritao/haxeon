import compiler.Compiler;
import compiler.ir.IrInterpreter;
import compiler.runtime.CompilerIntrinsics;

/** Editing handwritten enum equality must invalidate callers and their generated helper. */
class EnumEqualityIncrementalMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.update("Equatable.hx", "interface Equatable {}");
		compiler.update("Value.hx", source("true"));
		compiler.update("Main.hx", "function main():Int { var a:Value = Value.Item(1), b:Value = Value.Item(2); return a == b ? 1 : 2; }");
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 1) throw "initial handwritten enum equality was not used";
		compiler.update("Value.hx", source("false"));
		if (new IrInterpreter(compiler.compile("Main").ir).run("main") != 2) throw "incremental enum equality retained a stale method body";
		var dynamicCompiler = new Compiler();
		dynamicCompiler.update("Equatable.hx", "interface Equatable {}");
		dynamicCompiler.update("Value.hx", source("true"));
		dynamicCompiler.update("Main.hx", "function main():Int { var a:Dynamic = Value.Item(1), b:Dynamic = Value.Item(2); return a == b ? 1 : 2; }");
		if (new IrInterpreter(dynamicCompiler.compile("Main").ir).run("main") != 1) throw "initial Dynamic enum equality was not used";
		dynamicCompiler.update("Value.hx", source("false"));
		if (new IrInterpreter(dynamicCompiler.compile("Main").ir).run("main") != 2) throw "incremental Dynamic enum equality retained a stale method body";
		var arrayCompiler = new Compiler(null, CompilerIntrinsics.configuration());
		arrayCompiler.update("Equatable.hx", "interface Equatable {}");
		arrayCompiler.update("Value.hx", genericSource("true"));
		arrayCompiler.update("Other.hx", "class Other { public static function code():Int return 1; }");
		arrayCompiler.update("Main.hx", "function main():Int { var typed:Array<Value<Int>> = [Value.Item(1), Value.Item(2)]; var view:Array<Dynamic> = cast typed; return view[0] == view[1] ? Other.code() : 2; }");
		if (GeneratedProgramRunner.exitCode(arrayCompiler.compile("Main")) != 1) throw "initial generic enum array view equality was not used";
		arrayCompiler.update("Other.hx", "class Other { public static function code():Int return 3; }");
		if (GeneratedProgramRunner.exitCode(arrayCompiler.compile("Main")) != 3) throw "cached generic enum descriptor or equality was lost";
		arrayCompiler.update("Value.hx", genericSource("false"));
		if (GeneratedProgramRunner.exitCode(arrayCompiler.compile("Main")) != 2) throw "incremental generic enum array view retained stale equality";
		var reflectionCompiler = new Compiler(null, CompilerIntrinsics.configuration());
		reflectionCompiler.addSourceRoot("stdlib");
		reflectionCompiler.update("Equatable.hx", "interface Equatable {}");
		reflectionCompiler.update("Value.hx", genericSource("true"));
		reflectionCompiler.update("Other.hx", "class Other { public static function code():Int return 1; }");
		reflectionCompiler.update("Main.hx", "class Holder { public var item:Value<Int>; public function new(n:Int) item=Value.Item(n); } function main():Int { var a:Dynamic=Reflect.field(new Holder(1), \"item\"), b:Dynamic=Reflect.field(new Holder(2), \"item\"); return a == b ? Other.code() : 2; }");
		if (GeneratedProgramRunner.exitCode(reflectionCompiler.compile("Main")) != 1) throw "reflected enum equality was not used";
		reflectionCompiler.update("Other.hx", "class Other { public static function code():Int return 3; }");
		if (GeneratedProgramRunner.exitCode(reflectionCompiler.compile("Main")) != 3) throw "cached reflected enum equality was lost";
		reflectionCompiler.update("Value.hx", genericSource("false"));
		if (GeneratedProgramRunner.exitCode(reflectionCompiler.compile("Main")) != 2) throw "reflected enum equality retained a stale method body";
		var nativeCompiler = new Compiler(null, CompilerIntrinsics.configuration());
		nativeCompiler.update("Equatable.hx", "interface Equatable {}");
		nativeCompiler.update("Value.hx", genericSource("true"));
		nativeCompiler.update("Main.hx", "@:hlNative(\"haxeon_runtime\", \"__array_get_any\") extern function nativeGet(values:Array<Value<Int>>, index:Int):Dynamic; function main():Int { var values:Array<Value<Int>>=[Value.Item(1),Value.Item(2)]; return nativeGet(values,0) == nativeGet(values,1) ? 1 : 2; }");
		if (GeneratedProgramRunner.exitCode(nativeCompiler.compile("Main")) != 1) throw "native enum escape did not use declared equality";
		nativeCompiler.update("Value.hx", genericSource("false"));
		if (GeneratedProgramRunner.exitCode(nativeCompiler.compile("Main")) != 2) throw "native enum escape retained stale equality";
		var lateReflection = new Compiler(null, CompilerIntrinsics.configuration());
		lateReflection.addSourceRoot("stdlib");
		lateReflection.update("Equatable.hx", "interface Equatable {}");
		lateReflection.update("Value.hx", source("true"));
		lateReflection.update("Holder.hx", "class Holder { public var value:Value; public function new() value=Value.Item(1); }");
		lateReflection.update("Main.hx", "function main():Int { var holder=new Holder(); return 42; }");
		var beforeReflection = lateReflection.compile("Main");
		for (fn in beforeReflection.ir.functions)
			if (StringTools.startsWith(fn.name, "$enum-reflect-equals:")) throw "unused incremental enum reflection helper was retained";
		if (GeneratedProgramRunner.exitCode(beforeReflection) != 42) throw "initial enum holder failed";
		lateReflection.update("Main.hx", "function main():Int { var first:Dynamic=Reflect.field(new Holder(),\"value\"), second:Dynamic=Reflect.field(new Holder(),\"value\"); return Type.enumEq(first,second) ? 42 : 1; }");
		if (GeneratedProgramRunner.exitCode(lateReflection.compile("Main")) != 42) throw "incremental reflective enum equality was not restored";
		Sys.println("PASS: handwritten enum equality follows incremental method edits");
	}

	static function genericSource(result:String):String
		return 'enum Value<T> : Equatable { Item(value:T); public function equals(other:Value<T>):Bool return $result; }';

	static function source(result:String):String
		return 'enum Value : Equatable { Item(value:Int); public function equals(other:Value):Bool return $result; }';
}

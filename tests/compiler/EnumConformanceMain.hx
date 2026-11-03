import compiler.Diagnostic.CompileError;
import compiler.Frontend;
import compiler.ir.IrInterpreter;

class EnumConformanceMain {
	static function main():Void {
		var program = Frontend.compile('interface Equatable {} interface Hashable extends Equatable {} '
			+ 'enum Value : Hashable { Item(value:Int); Empty; } '
			+ 'function main():Int return Item(1) == Item(1) && Item(1) != Item(2) ? 42 : 1;');
		if (new IrInterpreter(program).run("main") != 42) throw "enum equality must compare payload values";
		expectError('enum Value { Item(value:Int); } function main():Int return Item(1) == Item(1) ? 42 : 0;',
			'does not conform to Equatable');
		expectError('interface Equatable {} class Ref {} enum Value : Equatable { Item(value:Ref); } function main():Int return 0;',
			'does not conform to Equatable');
		expectError('interface Equatable {} interface Hashable extends Equatable {} '
			+ 'enum Value : Hashable { Item(value:Int); public function equals(other:Value):Bool return true; } function main():Int return 0;',
			'provide hash():Int');
		expectError('interface Equatable {} enum Value : Equatable { Item(value:Int); '
			+ 'public static function equals(other:Value):Bool return true; } function main():Int return 0;',
			'must have signature equals');
		expectError('interface Equatable {} enum Value : Equatable { Item; public function equals(other:Value):Bool return true; } '
			+ 'function main():Int return 0;', 'uses tag equality');
		var custom = Frontend.compile('interface Equatable {} class Ref {} enum Value : Equatable { Item(value:Ref); '
			+ 'public function equals(other:Value):Bool return true; } '
			+ 'function main():Int { var a:Value = Item(new Ref()), b:Value = Item(new Ref()); return a == b ? 42 : 0; }');
		if (new IrInterpreter(custom).run("main") != 42) throw "handwritten enum equality must handle non-Equatable payloads";
		var declarations = 'interface Equatable {} enum Inner : Equatable { Item(value:Int); } '
			+ 'enum Outer : Equatable { Wrap(value:Inner); } '
			+ 'class Holder { public var value:Outer; public function new(value:Outer) this.value = value; } ';
		var unusedReflection = Frontend.compile(declarations + 'function main():Int { var holder = new Holder(Outer.Wrap(Inner.Item(1))); return 42; }');
		for (fn in unusedReflection.functions)
			if (StringTools.startsWith(fn.name, "$enum-reflect-equals:")) throw "unused enum reflection helper was retained";
		var nestedReflection = Frontend.compile(declarations + 'function main():Int return '
			+ 'Type.enumEq(Outer.Wrap(Inner.Item(1)), Outer.Wrap(Inner.Item(1))) ? 42 : 1;');
		if (new IrInterpreter(nestedReflection).run("main") != 42) throw "nested reflective enum helpers were not retained";
		Sys.println("PASS: enum conformances declare value equality and reject unsupported payloads");
	}

	static function expectError(source:String, expected:String):Void {
		try {
			Frontend.compile(source);
			throw 'expected error containing "$expected"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(expected) < 0) throw error;
		}
	}
}

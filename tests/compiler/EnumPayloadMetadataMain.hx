import compiler.Compiler;
import compiler.Frontend;
import compiler.ir.Ir;
import compiler.ir.IrInterpreter;
import compiler.ir.IrInlineEnumLayout;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.IrVerifier;
import compiler.ir.codec.CanonicalIrCodec;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.typing.EnumRuntimeType;

/** A concrete descriptor must describe every case, even if its constructor never used T. */
class EnumPayloadMetadataMain {
	static final declaration = 'enum Value<T> { Empty; Code(value:Int); Item(value:T); Items(values:Array<T>); } ';
	static final body = 'function size(value:Value<String>):Int return switch value { case Item(text): text.length; default: 0; }; '
		+ 'function main():Int { var a:Value<String> = Item("x"); var b:Value<Int> = Code(41); '
		+ 'var empty:Value<Float> = Empty; return size(a) + switch b { case Code(value): value; default: 0; }; }';

	static function main():Void {
		var program = Frontend.compile(declaration + body);
		check(program);
		if (new IrInterpreter(program).run("main") != 42) throw "Concrete enum construction/projection failed";
		check(CanonicalIrCodec.decode(CanonicalIrCodec.encode(program)));
		var inferred = Frontend.compile('enum Word { Code(value:Int); } '
			+ 'function collect(value:Word):Array<Int> { var values = []; '
			+ 'switch value { case Code(code): values.push(code); } return values; } '
			+ 'function main():Int return collect(Code(42))[0];');
		if (new IrInterpreter(inferred).run("main") != 42) throw "Enum pattern payload inference required a physical layout";
		for (source in [
			'function make<T>(value:T):Dynamic { var item:Value<T> = Item(value); return item; } '
				+ 'function main():Int { var value = make("x"); return 42; }',
			'class Factory<T> { var value:T; public function new(value:T) this.value=value; '
				+ 'public function make():Dynamic { var item:Value<T> = Item(value); return item; } } '
				+ 'function main():Int { var value = new Factory("x").make(); return 42; }',
			'function make<T>(value:T):Void->Dynamic return () -> { var item:Value<T> = Item(value); return item; }; '
				+ 'function main():Int { var get = make("x"); var value = get(); return 42; }',
			'typedef Wrapped<T> = Value<T>; '
				+ 'function make<T>(value:T):Dynamic { var item:Wrapped<T> = Item(value); return item; } '
				+ 'function main():Int { var value = make("x"); return 42; }'
		]) {
			var factory = Frontend.compile(declaration + source), retained = false;
			for (entry in factory.enums) if (entry.name == name(TString)) {
				retained = true;
				if (!IrVerifier.sameType(entry.cases[2].params[0], Bytes)) throw "Local enum factory erased its semantic argument";
			}
			if (!retained) throw "Local enum factory lost its concrete descriptor";
		}
		var planner = new IrInlineEnumLayout(program.enums, program.objects, 64, HashLink);
		var shape = planner.shape(name(TInt));
		if (shape == null || !IrVerifier.sameType(shape.cases[1].parameters[0], I32)
			|| !IrVerifier.sameType(shape.cases[2].parameters[0], I32)) throw "Layout planner received erased generic payloads";

		var recursive = Frontend.compile('enum Growing<T> { End; Next(value:T, tail:Growing<Array<T>>); } '
			+ 'enum Indirect<T> { Stop; More(values:Array<Indirect<Array<T>>>); } '
			+ 'enum Outer { Wrap(value:Growing<Int>); } '
			+ 'function main():Int { var a:Growing<Int> = End; var b:Indirect<String> = Stop; return 42; }');
		if (recursive.enums.length > 6) throw "Non-regular recursive enum expanded without a bound";
		for (candidate in [recursive, CanonicalIrCodec.decode(CanonicalIrCodec.encode(recursive))]) {
			var layout = new IrInlineEnumLayout(candidate.enums, candidate.objects, 64, HashLink);
			for (entry in candidate.enums) {
				var origin = EnumRuntimeType.declaration(entry.name);
				if (origin == "Growing" && (entry.isRecursive != true || layout.shape(entry.name) != null))
					throw 'By-value recursive enum lost its boxed decision: ${entry.name}';
				if (origin == "Indirect" && (entry.isRecursive == true || layout.shape(entry.name) == null))
					throw 'A reference descriptor cycle rejected a finite inline layout: ${entry.name}';
			}
			if (layout.shape("Outer") == null) throw "A boxed recursive child must not force its parent to be boxed";
		}
		var wrapped = Frontend.compile('enum Wrapper<T> { Wrap(value:T); } '
			+ 'enum Rec<T> { End; More(value:Wrapper<Wrapper<Rec<Array<T>>>>); } '
			+ 'function main():Int { var value:Rec<Int> = End; var wrapped:Wrapper<Rec<Int>> = Wrap(value); return 42; }');
		if (wrapped.enums.length > 4) throw "Wrapped non-regular recursion expanded its semantic-only arguments";
		var wrappedLayout = new IrInlineEnumLayout(wrapped.enums, wrapped.objects, 64, HashLink);
		for (entry in wrapped.enums) {
			var origin = EnumRuntimeType.declaration(entry.name);
			if (origin == "Rec" && (entry.isRecursive != true || wrappedLayout.shape(entry.name) != null))
				throw "A repeated generic wrapper hid recursive enum storage";
			if (origin == "Wrapper" && (entry.isRecursive == true || wrappedLayout.shape(entry.name) == null))
				throw "A wrapper around a boxed child was made recursive";
		}
		var phantom = Frontend.compile('enum Phantom<T> { Nothing; } '
			+ 'enum Parent<T> { Item(value:Phantom<Parent<Array<T>>>); } '
			+ 'function main():Int { var empty:Phantom<Parent<Int>> = Nothing; return 42; }');
		if (phantom.enums.length > 4) throw "Phantom enum arguments requested unreachable payload layouts";
		for (entry in phantom.enums) if (entry.isRecursive == true) throw "A phantom argument was treated as a stored payload";
		var throughStruct = Frontend.compile('struct Cell { public var value:ThroughStruct; '
			+ 'public function new(value:ThroughStruct) this.value=value; } '
			+ 'enum ThroughStruct { End; More(value:Cell); } function main():Int return 42;');
		for (entry in throughStruct.enums) if (entry.name == "ThroughStruct" && entry.isRecursive != true)
			throw "A value struct hid recursive enum storage";

		var compiler = new Compiler();
		compiler.update("Value.hx", declaration);
		compiler.update("Other.hx", "class Other { public static function code():Int return 1; }");
		compiler.update("Main.hx", StringTools.replace(body, "size(a) + switch", "Other.code() - 1 + size(a) + switch"));
		check(compiler.compile("Main").ir);
		compiler.update("Other.hx", "class Other { public static function code():Int return 2; }");
		check(compiler.compile("Main").ir);
		compiler.update("Value.hx", StringTools.replace(declaration, "Items(values:Array<T>);", "Items(values:Array<T>); Again(value:Value<T>);"));
		check(compiler.compile("Main").ir, true);
		compiler.update("Value.hx", declaration);
		check(compiler.compile("Main").ir);
		Sys.println("PASS: concrete enum payload types and recursive decisions survive cached callers and canonical IR");
	}

	static function name(argument:CompilerType):String return EnumRuntimeType.name(TInstance(NominalKind.Enum, "Value", [argument]));

	static function check(program:IrProgram, boxedRecursive = false):Void {
		for (argument in [TInt, TString, TFloat]) {
			var expected:IrType = switch argument { case TInt: I32; case TString: Bytes; case TFloat: F64; default: throw "Invalid test type"; };
			var declaration = null;
			for (entry in program.enums) if (entry.name == name(argument)) declaration = entry;
			if (declaration == null) throw 'Missing concrete enum metadata for $argument';
			if ((declaration.isRecursive == true) != boxedRecursive) throw "Cached recursive storage decision was not refreshed";
			if (!IrVerifier.sameType(declaration.cases[1].params[0], boxedRecursive ? Dyn : I32)
				|| !IrVerifier.sameType(declaration.cases[2].params[0], boxedRecursive ? Dyn : expected)
				|| !IrVerifier.sameType(declaration.cases[3].params[0], boxedRecursive ? Dyn : Array(expected)))
				throw 'Wrong concrete payload types for $argument';
		}
	}
}

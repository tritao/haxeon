import compiler.Frontend;
import compiler.ir.Ir.IrType;
import compiler.ir.IrInlineValueLayout;
import compiler.ir.IrProgramAssembler;
import compiler.Source.SourceFile;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.types.Typer;

/** The shared IR retains the payload identity needed to select nullable struct storage. */
class NullableStructIrMain {
	static function main():Void {
		var program = Frontend.compile("struct Value { public var x:Int; public function new(x:Int) this.x = x; } "
			+ "function identity(value:Null<Value>):Null<Value> return value; "
			+ "function main():Int { var value:Null<Value> = new Value(42); return identity(value) == null ? 0 : 42; }");
		var found = false;
		for (fn in program.functions)
			if (fn.name == "identity") {
				found = true;
				if (!Type.enumEq(fn.arguments[0].type, Nullable(Obj("Value"))) || !Type.enumEq(fn.result, Nullable(Obj("Value"))))
					throw 'nullable struct payload was erased in IR: ${fn.arguments[0].type} -> ${fn.result}';
			}
		if (!found)
			throw "missing nullable identity function";
		var source = "struct Point { public var x:Int; public function new(x:Int) this.x = x; } "
			+ "class Holder { public var value:Null<Point> = new Point(1); public function new() {} } function main():Int return 42;";
		var ast = new Parser(new Lexer(new SourceFile("Optional.hx", source)).tokenize()).parseProgram(), typed = Typer.type(ast),
			physical = Frontend.compile(source);
		var flag = IrInlineValueLayout.slotName("value", {path: [], type: Bool, isPresence: true, nativeLayout: null}),
			payload = IrInlineValueLayout.slotName("value", {path: ["x"], type: I32, isPresence: false, nativeLayout: null}),
			holder = [for (object in physical.objects) if (object.name == "Holder") object][0];
		if (holder == null || holder.fields.length != 2 || holder.fields[0].name != flag || holder.fields[1].name != payload)
			throw "nullable field was not expanded into inline flag and payload slots";
		var alreadyPublished = IrProgramAssembler.liveInitializersFrom(typed, _ -> true, (_, field) -> field == flag);
		if (alreadyPublished.length != 0) throw "an existing optional field was treated as a newly published field";
		var added = IrProgramAssembler.liveInitializersFrom(typed, _ -> true, (_, _) -> false);
		if (added.length != 1) throw "a new optional field did not get its live initializer";
		var copied = Frontend.compile("struct Child { public var text:String; } "
			+ "struct Value { public var nested:Null<Child>; public var n:Int; } "
			+ "class Holder { public var value:Null<Value>; public function new() {} } "
			+ "function copy(a:Holder, b:Holder):Void a.value = b.value; function main():Int return 42;");
		var copy = [for (fn in copied.functions) if (fn.name == "copy") fn][0], reads = 0, writes = 0, wrote = false;
		if (copy == null) throw "missing optional field copy";
		for (block in copy.blocks) for (located in block.instructions) switch located.value {
			case FieldGet(_, _, _):
				if (wrote) throw "optional copy read a source slot after writing the destination";
				reads++;
			case FieldSet(_, _, _): wrote = true; writes++;
			case NewObject(_, _) | ToDyn(_, _) | Call(_, _, _): throw "optional field copy allocated or called an accessor";
			default:
		}
		if (reads != 4 || writes != reads) throw 'optional field copy did not snapshot all nested slots: $reads reads, $writes writes';
		Sys.println("PASS: shared IR retains nullable struct payload types");
	}
}

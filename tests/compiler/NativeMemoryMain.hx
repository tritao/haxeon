import compiler.Compiler;
import compiler.Diagnostic.CompileError;
import compiler.runtime.CompilerIntrinsics;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrType;
import compiler.ir.codec.IrFunctionStateCodec;
import sys.io.File;

class NativeMemoryMain {
	static function main():Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("NativeMemory.hx", File.getContent("tests/programs/native-memory.hx"));
		var result = compiler.compile("NativeMemory"),
			sawOffset = false,
			sawLoad = false,
			sawStore = false,
			sawF32Load = false,
			mainFunction:Null<compiler.ir.IrFunction> = null;
		for (fn in result.ir.functions)
			if (fn.name == "main")
				mainFunction = fn;
		for (fn in result.ir.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case PointerOffset(_, _, _):
							sawOffset = true;
						case MemoryLoad(output, _, _, _):
							sawLoad = true;
							if (output.type == F32)
								sawF32Load = true;
						case MemoryStore(_, _, _):
							sawStore = true;
						case _:
					}
		if (!sawOffset || !sawLoad || !sawStore || !sawF32Load)
			throw "RawPtr operations must lower to explicit pointer and memory IR instructions";
		if ([
			for (object in result.ir.objects)
				if (object.name.indexOf("NativeNode") >= 0) object
		].length != 0)
			throw "Native records must not become HashLink objects";
		if (mainFunction == null)
			throw "Native memory fixture did not produce an entry function";
		var restored = IrFunctionStateCodec.decode(IrFunctionStateCodec.encode(mainFunction)),
			restoredF32Load = false;
		for (block in restored.blocks)
			for (located in block.instructions)
				switch located.value {
					case MemoryLoad(output, _, _, _) if (output.type == F32):
						restoredF32Load = true;
					case _:
				}
		if (!restoredF32Load)
			throw "Native pointer memory instructions and F32 types must survive IR persistence";

		var u32Compiler = new Compiler();
		CompilerIntrinsics.register(u32Compiler);
		u32Compiler.addSourceRoot("stdlib");
		u32Compiler.update("NativeU32RuntimeValues.hx", File.getContent("tests/programs/NativeU32RuntimeValues.hx"));
		var u32Result = u32Compiler.compile("NativeU32RuntimeValues"),
			u32RoundTrip:Null<compiler.ir.IrFunction> = null,
			u32ArrayRoundTrip:Null<compiler.ir.IrFunction> = null;
		for (fn in u32Result.ir.functions)
			if (StringTools.endsWith(fn.name, "roundTripTick"))
				u32RoundTrip = fn;
			else if (StringTools.endsWith(fn.name, "roundTripTicks"))
				u32ArrayRoundTrip = fn;
		if (u32RoundTrip == null
			|| u32RoundTrip.arguments.length != 1
			|| u32RoundTrip.arguments[0].type != I32
			|| u32RoundTrip.result != I32)
			throw "UInt32 runtime value parameters and results must use the lossless I32 carrier";
		var u32ArrayInputIsI32 = u32ArrayRoundTrip != null
			&& u32ArrayRoundTrip.arguments.length == 1
			&& switch u32ArrayRoundTrip.arguments[0].type {
				case Array(I32): true;
				case _: false;
			};
		var u32ArrayResultIsI32 = u32ArrayRoundTrip != null && switch u32ArrayRoundTrip.result {
			case Array(I32): true;
			case _: false;
		};
		if (!u32ArrayInputIsI32 || !u32ArrayResultIsI32)
			throw "Array<UInt32> parameters and results must use the existing i32 array runtime ABI";
		var sawU32Field = false;
		for (object in u32Result.ir.objects)
			if (StringTools.endsWith(object.name, "TickValue"))
				for (field in object.fields)
					if (field.name == "tick" && field.type == I32)
						sawU32Field = true;
		if (!sawU32Field)
			throw "A managed UInt32 field must use the lossless I32 carrier";

		var incrementalFlat = new Compiler();
		CompilerIntrinsics.register(incrementalFlat);
		incrementalFlat.addSourceRoot("stdlib");
		incrementalFlat.update("model/Packet.hx", "package model; struct Packet { public var value:Int32; }");
		incrementalFlat.update("app/Reader.hx",
			"package app; import model.Packet; import runtime.memory.NativeSpan; class Reader { public static function copy(span:NativeSpan<Packet>):Packet return span.get(0); }");
		incrementalFlat.update("Main.hx",
			"import app.Reader; import model.Packet; import runtime.memory.NativeSpan; import runtime.memory.RawPtr; " +
			"function main():Int { var pointer:RawPtr<Packet> = RawPtr.nullPtr(), span:NativeSpan<Packet> = new NativeSpan<Packet>(pointer, 1); " +
			"Reader.copy(span); return 42; }");
		incrementalFlat.compile("Main");
		incrementalFlat.update("app/Reader.hx",
			"package app; import model.Packet; import runtime.memory.NativeSpan; class Reader { public static function copy(span:NativeSpan<Packet>):Packet { " +
			"var packet:Packet = span.get(0); return packet; } }");
		var incrementalFlatResult = incrementalFlat.compile("Main"), sawFlatGetSpecialization = false, sawFlatMemoryLoad = false;
		for (fn in incrementalFlatResult.ir.functions)
			if (fn.name.indexOf("runtime.memory.NativeSpan.get[layout]") >= 0) {
				sawFlatGetSpecialization = true;
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case MemoryLoad(_, _, _, _): sawFlatMemoryLoad = true;
							case _:
						}
			}
		if (!incrementalFlatResult.retyped.contains("app.Reader.copy") || !sawFlatGetSpecialization || !sawFlatMemoryLoad)
			throw 'Incremental Flat RawPtr lowering must preserve its cached layout and exact specialization: retyped=${incrementalFlatResult.retyped}';

		expectCompileError('import runtime.memory.RawPtr; function bad(pointer:RawPtr<String>):String return pointer.load(); function main():Int return 0;',
			"has no fixed native memory layout");
		expectCompileError('import runtime.memory.RawPtr; struct Rich { public var text:String; } function bad(pointer:RawPtr<Rich>):String return pointer.ref.text; function main():Int return 0;',
			"RawPtr.ref requires a Flat struct pointee");
		expectCompileError('import runtime.memory.RawPtr; @:value @:repr("C") class Pair { public var value:Int32; } function bad(pointer:RawPtr<Pair>):Void { pointer.store(null); } function main():Int return 0;',
			"address-only and cannot be stored by value");
		expectCompileError('import runtime.memory.RawPtr; @:value @:repr("C") class Pair { public var value:Int32; } function bad(pointer:RawPtr<Pair>):Int return pointer.ref.value; function main():Int return 0;',
			"RawPtr.ref requires a Flat struct pointee");
	}

	static function expectCompileError(source:String, expected:String):Void {
		var compiler = new Compiler();
		CompilerIntrinsics.register(compiler);
		compiler.addSourceRoot("stdlib");
		compiler.update("Negative.hx", source);
		try {
			compiler.compile("Negative");
			throw 'expected compile error containing "$expected"';
		} catch (error:CompileError) {
			if (error.diagnostic.message.indexOf(expected) < 0)
				throw error;
		}
	}
}

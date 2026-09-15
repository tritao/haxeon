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

		expectCompileError('import runtime.memory.RawPtr; function bad(pointer:RawPtr<String>):String return pointer.load(); function main():Int return 0;',
			"has no fixed native memory layout");
		expectCompileError('import runtime.memory.RawPtr; @:value @:repr("C") class Pair { public var value:Int32; } function bad(pointer:RawPtr<Pair>):Void { pointer.store(null); } function main():Int return 0;',
			"address-only and cannot be stored by value");
		expectCompileError('import runtime.memory.RawPtr; function bad(pointer:RawPtr<Int>):Int return pointer.ref.value; function main():Int return 0;',
			"RawPtr.ref requires a native value record pointee");
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

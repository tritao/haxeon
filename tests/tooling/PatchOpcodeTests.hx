import compiler.hl.HlCode;
import compiler.hl.HlFunction;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlWriter;
import compiler.hl.HlOpcode;
import compiler.hl.HlType as HashLinkType;
import Type as HaxeType;
import compiler.hl.patch.HlPatchWriter;
import compiler.hl.patch.HlPatchReader;
import compiler.hl.patch.HlPatchFormat;
import compiler.hl.persistence.HlRuntimeIdentity;
import haxe.io.Bytes as HaxeBytes;
import haxe.io.BytesOutput;
import runtime.Runtime;
import runtime.RuntimeError;
import runtime.RuntimeStatus;
import runtime.PatchSet;

/** Wire fixtures are pinned to vendor/hashlink/src/opcodes.h, independent of the writer. */
class PatchOpcodeTests {
	static function main():Void
		run();

	public static function run():Void {
		var fixtures:Array<{instruction:HlInstruction, opcode:Int, operands:Array<Int>}> = [
			{instruction: Move(0, 1), opcode: 0, operands: [0, 1]},
			{instruction: LoadInt(0, 128), opcode: 1, operands: [0, 128]},
			{instruction: LoadFloat(0, 128), opcode: 2, operands: [0, 128]},
			{instruction: LoadBool(0, true), opcode: 3, operands: [0, 1]},
			{instruction: LoadString(0, 128), opcode: 5, operands: [0, 128]},
			{instruction: LoadNull(0), opcode: 6, operands: [0]},
			{instruction: Add(0, 1, 2), opcode: 7, operands: [0, 1, 2]},
			{instruction: Sub(0, 1, 2), opcode: 8, operands: [0, 1, 2]},
			{instruction: Mul(0, 1, 2), opcode: 9, operands: [0, 1, 2]},
			{instruction: Div(0, 1, 2), opcode: 10, operands: [0, 1, 2]},
			{instruction: Mod(0, 1, 2), opcode: 12, operands: [0, 1, 2]},
			{instruction: ShiftLeft(0, 1, 2), opcode: 14, operands: [0, 1, 2]},
			{instruction: ShiftRight(0, 1, 2), opcode: 15, operands: [0, 1, 2]},
			{instruction: UnsignedShiftRight(0, 1, 2), opcode: 16, operands: [0, 1, 2]},
			{instruction: BitAnd(0, 1, 2), opcode: 17, operands: [0, 1, 2]},
			{instruction: BitOr(0, 1, 2), opcode: 18, operands: [0, 1, 2]},
			{instruction: BitXor(0, 1, 2), opcode: 19, operands: [0, 1, 2]},
			{instruction: Call0(0, 0), opcode: 24, operands: [0, 0]},
			{instruction: Call1(0, 0, 1), opcode: 25, operands: [0, 0, 1]},
			{instruction: Call2(0, 0, 1, 2), opcode: 26, operands: [0, 0, 1, 2]},
			{instruction: CallN(0, 0, [1, 2, 3]), opcode: 29, operands: [0, 0, 3, 1, 2, 3]},
			{instruction: CallMethod(0, 1, [2, 3]), opcode: 30, operands: [0, 1, 2, 2, 3]},
			{instruction: CallClosure(0, 1, [2, 3]), opcode: 32, operands: [0, 1, 2, 2, 3]},
			{instruction: StaticClosure(0, 0), opcode: 33, operands: [0, 0]},
			{instruction: InstanceClosure(0, 0, 1), opcode: 34, operands: [0, 0, 1]},
			{instruction: GlobalGet(0, 128), opcode: 36, operands: [0, 128]},
			{instruction: GlobalSet(128, 0), opcode: 37, operands: [128, 0]},
			{instruction: FieldGet(0, 1, 2), opcode: 38, operands: [0, 1, 2]},
			{instruction: FieldSet(0, 1, 2), opcode: 39, operands: [0, 1, 2]},
			{instruction: JumpTrue(0, "target"), opcode: 44, operands: [0, -2]},
			{instruction: JumpSignedLess(0, 1, "target"), opcode: 48, operands: [0, 1, -2]},
			{instruction: JumpSignedLessOrEqual(0, 1, "target"), opcode: 51, operands: [0, 1, -2]},
			{instruction: JumpEqual(0, 1, "target"), opcode: 56, operands: [0, 1, -2]},
			{instruction: Jump("target"), opcode: 58, operands: [-2]},
			{instruction: ToDyn(0, 1), opcode: 59, operands: [0, 1]},
			{instruction: ToSFloat(0, 1), opcode: 60, operands: [0, 1]},
			{instruction: ToInt(0, 1), opcode: 62, operands: [0, 1]},
			{instruction: SafeCast(0, 1), opcode: 63, operands: [0, 1]},
			{instruction: ToVirtual(0, 1), opcode: 65, operands: [0, 1]},
			{instruction: Label("other"), opcode: 66, operands: []},
			{instruction: Return(0), opcode: 67, operands: [0]},
			{instruction: Throw(0), opcode: 68, operands: [0]},
			{instruction: Rethrow(0), opcode: 69, operands: [0]},
			{instruction: Trap(0, "target"), opcode: 72, operands: [0, -2]},
			{instruction: EndTrap(0), opcode: 73, operands: [0]},
			{instruction: ArrayGet(0, 1, 2), opcode: 77, operands: [0, 1, 2]},
			{instruction: ArraySet(0, 1, 2), opcode: 81, operands: [0, 1, 2]},
			{instruction: New(0, 128, 256), opcode: 82, operands: [0]},
			{instruction: ArraySize(0, 1), opcode: 83, operands: [0, 1]},
			{instruction: LoadType(0, 128), opcode: 84, operands: [0, 128]},
			{instruction: MakeEnum(0, 1, [2, 3]), opcode: 90, operands: [0, 1, 2, 2, 3]},
			{instruction: EnumIndex(0, 1), opcode: 92, operands: [0, 1]},
			{instruction: EnumField(0, 1, 2, 3), opcode: 93, operands: [0, 1, 2, 3]},
			{instruction: CallN(0, 0, []), opcode: 29, operands: [0, 0, 0]},
			{instruction: CallMethod(0, 1, []), opcode: 30, operands: [0, 1, 0]},
			{instruction: CallClosure(0, 1, []), opcode: 32, operands: [0, 1, 0]},
			{instruction: MakeEnum(0, 1, []), opcode: 90, operands: [0, 1, 0]}
		];
		var covered:Map<String, Bool> = [];
		// These are wire-format probes, not executable functions: operands deliberately
		// include distinct values and multi-byte indices to expose stream misalignment.
		for (fixture in fixtures) {
			var name = HaxeType.enumConstructor(fixture.instruction);
			covered.set(name, true);
			var code = module([Label("target"), fixture.instruction, Return(0)]);
			var bytes = HlPatchWriter.encode(code, HaxeBytes.alloc(16), [0], [0 => 70000], 1, 2);
			var decoded = HlPatchReader.decode(bytes),
				native = Runtime.inspectPatch(bytes);
			var actual = decoded.functions[0].instructions;
			if (native.functionCount != 1
				|| native.baseRevision != 1
				|| native.revision != 2
				|| actual.length != 3
				|| actual[1].opcode != fixture.opcode
				|| actual[1].operands.join(",") != fixture.operands.join(",")
				|| actual[2].opcode != 67
				|| actual[2].operands.join(",") != "0")
				throw 'Patch opcode decoding disagrees for $name';
		}
		for (name in HaxeType.getEnumConstructs(HlInstruction))
			if (!covered.exists(name))
				throw 'Missing patch opcode fixture for $name';
		testMalformed();
		testRejectedTransactions();
		Sys.println('PASS: ${HaxeType.getEnumConstructs(HlInstruction).length} instruction variants covered by both patch decoders; malformed patches rejected');
	}

	static function module(ops:Array<HlInstruction>):HlCode {
		var code = new HlCode();
		code.ints = [42];
		code.types = [Simple(HashLinkType.Void), Simple(HashLinkType.I32), Function([], 1)];
		code.functions = [new HlFunction(2, 0, [1], ops)];
		return code;
	}

	static function index(out:BytesOutput, value:Int):Void
		out.write(HlWriter.encodeIndex(value));

	// Independent envelope permits malformed operands without weakening the writer.
	static function rawPatch(opcode:Int, operands:Array<Int>):HaxeBytes {
		var symbols = new BytesOutput();
		symbols.bigEndian = false;
		for (_ in 0...4) {
			symbols.writeInt32(0);
			index(symbols, 0);
			index(symbols, 0);
		}
		var body = new BytesOutput();
		for (value in [70000, 2, 0, 1, 1, 1])
			index(body, value);
		body.writeByte(opcode);
		for (operand in operands)
			index(body, operand);
		index(body, 0); // relocations
		var functions = new BytesOutput();
		index(functions, 1);
		index(functions, body.length);
		functions.write(body.getBytes());
		var out = new BytesOutput();
		out.writeString("HLP");
		out.writeByte(HlPatchFormat.VERSION);
		out.write(HaxeBytes.alloc(16));
		index(out, 1);
		index(out, 2);
		index(out, 2);
		out.writeByte(1);
		index(out, symbols.length);
		out.write(symbols.getBytes());
		out.writeByte(2);
		index(out, functions.length);
		out.write(functions.getBytes());
		return out.getBytes();
	}

	static function rejectBytes(bytes:HaxeBytes, name:String):Void {
		var haxeRejected = false, nativeRejected = false;
		try {
			HlPatchReader.decode(bytes);
		} catch (error:String) {
			haxeRejected = true;
		}
		try {
			Runtime.inspectPatch(bytes);
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.BadFormat)
				throw error;
			nativeRejected = true;
		}
		if (!haxeRejected || !nativeRejected)
			throw '$name: decoder rejection differs (Haxe=$haxeRejected, native=$nativeRejected)';
	}

	static function testMalformed():Void {
		rejectBytes(rawPatch(255, []), "unknown opcode");
		var callThis = rawPatch(HlOpcode.CallThis, [0, 1, 0]);
		HlPatchReader.decode(callThis);
		Runtime.inspectPatch(callThis);
		for (opcode in [HlOpcode.CallN, HlOpcode.CallMethod, HlOpcode.CallClosure, HlOpcode.MakeEnum]) {
			rejectBytes(rawPatch(opcode, [0, 0, -1]), 'negative variable operand count $opcode');
			rejectBytes(rawPatch(opcode, [0, 0, 0x1000001]), 'oversized variable operand count $opcode');
			rejectBytes(rawPatch(opcode, [0, 0, 3, 0]), 'truncated variable operands $opcode');
		}
		rejectBytes(rawPatch(93, [0, 0, 0]), "missing enum field operand");
		rejectBytes(rawPatch(6, [0, 0]), "extra null operand");
		var valid = rawPatch(6, [0]);
		HlPatchReader.decode(valid);
		Runtime.inspectPatch(valid);
		for (length in 0...valid.length)
			rejectBytes(valid.sub(0, length), 'truncated patch at $length');
	}

	static function testRejectedTransactions():Void {
		var code = module([LoadInt(0, 0), Return(0)]),
			moduleId = HaxeBytes.alloc(16);
		code.globals = [1];
		var loaded = Runtime.load(HlWriter.encode(code), HlRuntimeIdentity.encode(moduleId, 1, ["main" => 0], ["main" => 70000]));
		var invalid:Array<HlInstruction> = [
			Mod(1, 0, 0),
			ShiftLeft(0, 1, 0),
			ShiftRight(0, 0, 1),
			UnsignedShiftRight(1, 0, 0),
			BitAnd(0, 1, 0),
			BitOr(0, 0, 1),
			BitXor(1, 0, 0),
			GlobalGet(0, 1),
			GlobalGet(1, 0),
			GlobalSet(1, 0),
			GlobalSet(0, 1)
		];
		for (op in invalid) {
			code.functions = [new HlFunction(2, 0, [1], [op, Return(0)])];
			var bytes = HlPatchWriter.encode(code, moduleId, [0], [0 => 70000], 1, 2, 1, 0, 0, 3);
			var rejected = false;
			try {
				Runtime.patchSet(loaded, new PatchSet(1, 2, bytes, [70000]));
			} catch (error:RuntimeError) {
				if (error.status != RuntimeStatus.Incompatible)
					throw error;
				rejected = true;
			}
			if (!rejected || Runtime.liveRevision(loaded) != 1 || Runtime.callInt(loaded, 70000) != 42)
				throw 'Invalid ${HaxeType.enumConstructor(op)} changed live state';
		}
		code.functions = [
			new HlFunction(2, 0, [1], [LoadInt(0, 0), GlobalSet(0, 0), GlobalGet(0, 0), Return(0)])
		];
		var recovery = HlPatchWriter.encode(code, moduleId, [0], [0 => 70000], 1, 2, 1, 0, 0, 3);
		Runtime.patchSet(loaded, new PatchSet(1, 2, recovery, [70000]));
		if (Runtime.liveRevision(loaded) != 2 || Runtime.callInt(loaded, 70000) != 42)
			throw "Valid patch did not recover after rejected transactions";
		Runtime.dispose(loaded);
	}
}

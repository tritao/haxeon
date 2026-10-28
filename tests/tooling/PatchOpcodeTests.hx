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
			{instruction: JumpNull(0, "target"), opcode: 46, operands: [0, -2]},
			{instruction: JumpSignedLess(0, 1, "target"), opcode: 48, operands: [0, 1, -2]},
			{instruction: JumpSignedLessOrEqual(0, 1, "target"), opcode: 51, operands: [0, 1, -2]},
			{instruction: JumpUnsignedLess(0, 1, "target"), opcode: 52, operands: [0, 1, -2]},
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
			{instruction: NullCheck(0), opcode: 71, operands: [0]},
			{instruction: Trap(0, "target"), opcode: 72, operands: [0, -2]},
			{instruction: EndTrap(0), opcode: 73, operands: [0]},
			{instruction: GetI8(0, 1, 2), opcode: 74, operands: [0, 1, 2]},
			{instruction: GetI16(0, 1, 2), opcode: 75, operands: [0, 1, 2]},
			{instruction: GetMem(0, 1, 2), opcode: 76, operands: [0, 1, 2]},
			{instruction: ArrayGet(0, 1, 2), opcode: 77, operands: [0, 1, 2]},
			{instruction: SetI8(0, 1, 2), opcode: 78, operands: [0, 1, 2]},
			{instruction: SetI16(0, 1, 2), opcode: 79, operands: [0, 1, 2]},
			{instruction: SetMem(0, 1, 2), opcode: 80, operands: [0, 1, 2]},
			{instruction: ArraySet(0, 1, 2), opcode: 81, operands: [0, 1, 2]},
			{instruction: New(0, 128, 256), opcode: 82, operands: [0]},
			{instruction: ArraySize(0, 1), opcode: 83, operands: [0, 1]},
			{instruction: RefData(0, 1), opcode: 96, operands: [0, 1]},
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
		testGlobalPatches();
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
		// A patch cannot describe a method's signature, so appending that type must be rejected. (Structs travel with their
		// layout, as `Structure`, since HLP 10.)
		for (kind in [HashLinkType.Method]) {
			code.types.push(Simple(kind));
			code.functions = [new HlFunction(2, 0, [1], [LoadInt(0, 0), Return(0)])];
			var typeBytes = HlPatchWriter.encode(code, moduleId, [0], [0 => 70000], 1, 2, 1, 0, 0, 3),
				typeRejected = false;
			code.types.pop();
			try {
				Runtime.patchSet(loaded, new PatchSet(1, 2, typeBytes, [70000]));
			} catch (error:RuntimeError) {
				if (error.status != RuntimeStatus.Incompatible)
					throw error;
				typeRejected = true;
			}
			if (!typeRejected || Runtime.liveRevision(loaded) != 1 || Runtime.callInt(loaded, 70000) != 42)
				throw 'An appended type of kind $kind changed live state';
		}
		// Each path ends its trap, but the end-trap lies after the handler, outside the try region the JIT tracks in
		// instruction order, where emitting it aborts the process.
		var trapPastHandler:Array<HlInstruction> = [
			Trap(0, "handler"),
			Jump("after"),
			Label("handler"),
			Return(0),
			Label("after"),
			EndTrap(0),
			Return(0)
		];
		code.functions = [new HlFunction(2, 0, [1], trapPastHandler)];
		var trapBytes = HlPatchWriter.encode(code, moduleId, [0], [0 => 70000], 1, 2, 1, 0, 0, 3),
			trapRejected = false;
		try {
			Runtime.patchSet(loaded, new PatchSet(1, 2, trapBytes, [70000]));
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Incompatible)
				throw error;
			trapRejected = true;
		}
		if (!trapRejected || Runtime.liveRevision(loaded) != 1 || Runtime.callInt(loaded, 70000) != 42)
			throw "An end-trap outside its try region changed live state";
		code.functions = [
			new HlFunction(2, 0, [1], [LoadInt(0, 0), GlobalSet(0, 0), GlobalGet(0, 0), Return(0)])
		];
		var recovery = HlPatchWriter.encode(code, moduleId, [0], [0 => 70000], 1, 2, 1, 0, 0, 3);
		Runtime.patchSet(loaded, new PatchSet(1, 2, recovery, [70000]));
		if (Runtime.liveRevision(loaded) != 2 || Runtime.callInt(loaded, 70000) != 42)
			throw "Valid patch did not recover after rejected transactions";
		Runtime.dispose(loaded);
	}

	// A module with one String-like constant global: an object of a bytes pointer and an int length, as HashLink's String is.
	// Patches add further constants of that type, reading their strings and lengths from the tables they extend.
	static function stringModule():HlCode {
		var code = new HlCode();
		code.ints = [42, 5];
		code.strings = ["String", "bytes", "length", "hello"];
		code.types = [
			Simple(HashLinkType.Void),
			Simple(HashLinkType.I32),
			Function([], 1),
			Simple(HashLinkType.Bytes),
			Object(0, -1, 0, [{name: 1, type: 3}, {name: 2, type: 1}], [], [])
		];
		code.globals = [4];
		code.constants = [{global: 0, fields: [3, 1]}];
		code.functions = [new HlFunction(2, 0, [1], [LoadInt(0, 0), Return(0)])];
		return code;
	}

	/**
	 * A patch to the module after `existing` earlier patches each added one String constant: it adds `added` more, whose
	 * lengths are 100, 101, ... in order, and returns the length of global `read`.
	 */
	static function stringsPatch(existing:Int, added:Int, read:Int, ?customize:HlCode->Void, ?revision:Int):{code:HlCode, bytes:HaxeBytes} {
		var code = stringModule();
		for (i in 0...existing + added) {
			code.ints.push(100 + i);
			code.strings.push('literal$i');
			code.globals.push(4);
			code.constants.push({global: 1 + i, fields: [code.strings.length - 1, code.ints.length - 1]});
		}
		code.functions = [new HlFunction(2, 0, [1, 4], [GlobalGet(1, read), FieldGet(0, 1, 1), Return(0)])];
		if (customize != null)
			customize(code);
		var baseRevision = revision != null ? revision : existing > 0 ? 2 : 1;
		return {
			code: code,
			bytes: HlPatchWriter.encode(code, HaxeBytes.alloc(16), [0], [0 => 70000], baseRevision, baseRevision
				+ 1, 2
				+ existing, 0, 4
				+ existing, 5, null,
				null, 1
				+ existing)
		};
	}

	static function loadStrings():runtime.LoadedModule
		return Runtime.load(HlWriter.encode(stringModule()), HlRuntimeIdentity.encode(HaxeBytes.alloc(16), 1, ["main" => 0], ["main" => 70000]));

	static function readIndexAt(bytes:HaxeBytes, position:Int):{value:Int, next:Int} {
		var first = bytes.get(position);
		if (first & 0x80 == 0)
			return {value: first, next: position + 1};
		if (first & 0x40 == 0)
			return {value: bytes.get(position + 1) | ((first & 31) << 8), next: position + 2};
		return {
			value: (bytes.get(position + 1) << 16) | (bytes.get(position + 2) << 8) | bytes.get(position + 3) | ((first & 31) << 24),
			next: position + 4
		};
	}

	/** The patch with its globals section (tag 6) written twice. */
	static function withGlobalsTwice(bytes:HaxeBytes):HaxeBytes {
		var base = readIndexAt(bytes, 20),
			revision = readIndexAt(bytes, base.next),
			count = readIndexAt(bytes, revision.next),
			position = count.next,
			sectionStart = -1,
			sectionEnd = -1;
		for (_ in 0...count.value) {
			var start = position,
				tag = bytes.get(position),
				length = readIndexAt(bytes, position + 1);
			position = length.next + length.value;
			if (tag == 6) {
				sectionStart = start;
				sectionEnd = position;
			}
		}
		var out = new BytesOutput();
		out.write(bytes.sub(0, revision.next));
		index(out, count.value + 1);
		out.write(bytes.sub(count.next, bytes.length - count.next));
		out.write(bytes.sub(sectionStart, sectionEnd - sectionStart));
		return out.getBytes();
	}

	/** Applies the patch and reports whether the module turned it away; a module that did must be exactly as it was. */
	static function turnedAway(loaded:runtime.LoadedModule, baseRevision:Int, bytes:HaxeBytes):Bool {
		var revision = Runtime.liveRevision(loaded),
			result = Runtime.callInt(loaded, 70000);
		try {
			Runtime.patchSet(loaded, new PatchSet(baseRevision, baseRevision + 1, bytes, [70000]));
		} catch (error:RuntimeError) {
			if (error.status != RuntimeStatus.Incompatible)
				throw error;
			if (Runtime.liveRevision(loaded) != revision || Runtime.callInt(loaded, 70000) != result)
				throw "A rejected patch changed the module";
			return true;
		}
		return false;
	}

	static function testGlobalPatches():Void {
		var valid = stringsPatch(0, 1, 1);
		var decoded = HlPatchReader.decode(valid.bytes);
		Runtime.inspectPatch(valid.bytes);
		if (decoded.baseGlobals != 1
			|| decoded.globals.length != 1
			|| decoded.globals[0].type != 4
			|| decoded.globals[0].fields.join(",") != "4,2")
			throw "The globals section decoded to the wrong constants";
		for (length in 0...valid.bytes.length)
			rejectBytes(valid.bytes.sub(0, length), 'truncated globals patch at $length');
		rejectBytes(withGlobalsTwice(valid.bytes), "duplicate globals section");

		// The added global holds a String the patched function reads, built before the code can run.
		var loaded = loadStrings();
		Runtime.patchSet(loaded, new PatchSet(1, 2, valid.bytes, [70000]));
		if (Runtime.liveRevision(loaded) != 2 || Runtime.callInt(loaded, 70000) != 100)
			throw "A patch-added String constant was not readable by the patched function";
		// Later patches see the added global as the module's own: this one reads past it into two more.
		var stacked = stringsPatch(1, 2, 3);
		Runtime.patchSet(loaded, new PatchSet(2, 3, stacked.bytes, [70000]));
		if (Runtime.liveRevision(loaded) != 3 || Runtime.callInt(loaded, 70000) != 102)
			throw "A patch building on an earlier patch's globals did not apply";
		// A global a patch added holds a constant that code reads without a barrier, so code that assigns it is rejected.
		var assigning = stringsPatch(3, 0, 0, code -> code.functions = [
			new HlFunction(2, 0, [1, 4], [GlobalGet(1, 0), GlobalSet(1, 1), LoadInt(0, 0), Return(0)])
		], 3);
		if (!turnedAway(loaded, 3, assigning.bytes))
			throw "Code assigning a global that a patch added should be rejected";
		Runtime.dispose(loaded);

		// Each defect is turned away without changing the module, which then takes the good patch.
		var defects:Array<{name:String, bytes:HaxeBytes}> = [
			{
				name: "base globals that disagree with the module",
				bytes: HlPatchWriter.encode(valid.code, HaxeBytes.alloc(16), [0], [0 => 70000], 1, 2, 2, 0, 4, 5, null, null, 0)
			},
			{
				name: "a prefix hash from other global types",
				bytes: stringsPatch(0, 1, 1, code -> {
					code.globals[0] = 1;
					code.constants.shift();
				}).bytes
			},
			{name: "a global of a type the module lacks", bytes: stringsPatch(0, 1, 1, code -> code.globals[1] = 99).bytes},
			{name: "a global that is not an object", bytes: stringsPatch(0, 1, 1, code -> code.globals[1] = 1).bytes},
			{name: "a string index past the strings", bytes: stringsPatch(0, 1, 1, code -> code.constants[1] = {global: 1, fields: [99, 2]}).bytes},
			{name: "an int index past the ints", bytes: stringsPatch(0, 1, 1, code -> code.constants[1] = {global: 1, fields: [4, 99]}).bytes},
			{name: "fewer fields than the object has", bytes: stringsPatch(0, 1, 1, code -> code.constants[1] = {global: 1, fields: [4]}).bytes},
			{name: "a read past the added globals", bytes: stringsPatch(0, 1, 2).bytes},
			{name: "more globals than were reserved", bytes: stringsPatch(0, 16385, 1).bytes}
		];
		for (defect in defects) {
			var target = loadStrings();
			if (!turnedAway(target, 1, defect.bytes))
				throw '${defect.name}: the patch was not rejected';
			Runtime.patchSet(target, new PatchSet(1, 2, valid.bytes, [70000]));
			if (Runtime.callInt(target, 70000) != 100)
				throw '${defect.name}: the module did not take a good patch after the rejection';
			Runtime.dispose(target);
		}

		// The reserve is the most a patch can add.
		var full = loadStrings(), reserve = stringsPatch(0, 16384, 16384);
		Runtime.patchSet(full, new PatchSet(1, 2, reserve.bytes, [70000]));
		if (Runtime.callInt(full, 70000) != 100 + 16383)
			throw "A patch adding the whole reserve should apply";
		Runtime.dispose(full);

		// A failure after the constants exist leaves the module as it was.
		var failing = loadStrings();
		for (stage in [1, 2, 3]) {
			Runtime.injectPatchFailure(failing, stage);
			if (!turnedAway(failing, 1, valid.bytes))
				throw 'An injected failure at stage $stage did not reject the patch';
		}
		Runtime.patchSet(failing, new PatchSet(1, 2, valid.bytes, [70000]));
		if (Runtime.callInt(failing, 70000) != 100)
			throw "A patch did not apply after injected failures";
		Runtime.dispose(failing);

		// The writer will not describe a global that has no constant to give it a value.
		var bare = false;
		try {
			stringsPatch(0, 1, 1, code -> code.constants.pop());
		} catch (error:String) {
			bare = true;
		}
		if (!bare)
			throw "A global without a constant cannot travel in a patch";
	}
}

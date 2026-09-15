import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlReader;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
import compiler.Compiler;
import haxe.io.Bytes as HaxeBytes;

function expect(condition:Bool, message:String):Void {
	if (!condition)
		throw message;
}

function expectFailure(action:Void->Void):Bool {
	try {
		action();
	} catch (error:Dynamic) {
		return true;
	}
	return false;
}

function withTrailingByte(bytes:HaxeBytes):HaxeBytes {
	var result = HaxeBytes.alloc(bytes.length + 1);
	result.blit(0, bytes, 0, bytes.length);
	result.set(bytes.length, 0);
	return result;
}

function main():Void {
	var code = new HlCode();
	code.ints = [41];
	code.floats = [1.5];
	code.strings = ["lib", "native", "Box", "value", "main.hx"];
	code.bytes = HaxeBytes.ofString("abc\x00xyz\x00");
	code.bytePositions = [0, 4];
	code.types = [
		Simple(HlType.I32),
		Function([0], 0),
		Method([0], 0),
		Object(2, -1, 0, [{name: 3, type: 0}], [], [])
	];
	code.globals = [2];
	code.natives = [
		{
			library: 0,
			name: 1,
			type: 1,
			functionIndex: 0
		}
	];
	code.functions = [
		new compiler.hl.HlFunction(1, 1, [0], [
			HlInstruction.LoadBytes(0, 1),
			HlInstruction.ThisGet(0, 0),
			HlInstruction.ThisSet(0, 0),
			HlInstruction.EnumAlloc(0, 0),
			HlInstruction.JumpTrue(0, "done"),
			HlInstruction.LoadInt(0, 0),
			HlInstruction.Label("done"),
			HlInstruction.Return(0)
		], [
			{
				path: "main.hx",
				line: 1,
				column: 1,
				endLine: 1,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			},
			{
				path: "main.hx",
				line: 2,
				column: 1,
				endLine: 2,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			},
			{
				path: "main.hx",
				line: 3,
				column: 1,
				endLine: 3,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			},
			{
				path: "main.hx",
				line: 4,
				column: 1,
				endLine: 4,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			},
			{
				path: "main.hx",
				line: 5,
				column: 1,
				endLine: 5,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			},
			{
				path: "main.hx",
				line: 6,
				column: 1,
				endLine: 6,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			},
			{
				path: "main.hx",
				line: 7,
				column: 1,
				endLine: 7,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			},
			{
				path: "main.hx",
				line: 8,
				column: 1,
				endLine: 8,
				endColumn: 1,
				sourceHash: 0,
				start: null,
				end: null,
				flags: 1
			}
		], [{name: 4, position: -1, scopeEnd: -1}])
	];
	code.constants = [{global: 0, fields: [0]}];
	code.debugSections = [
		{
			kind: 7,
			version: 1,
			flags: 0,
			payload: HaxeBytes.ofString("opaque")
		}
	];
	code.entryPoint = 1;

	var encoded = HlWriter.encode(code);
	var decoded = HlReader.decode(encoded);
	expect(HlWriter.encode(decoded).compare(encoded) == 0, "HLB reader/writer round trip changed canonical bytes");
	expect(decoded.ints[0] == 41 && decoded.floats[0] == 1.5 && decoded.strings[1] == "native", "HLB scalar pools did not decode");
	expect(decoded.bytes.compare(code.bytes) == 0 && decoded.bytePositions[1] == 4, "HLB byte pool did not decode");
	expect(decoded.types.length == 4 && decoded.globals[0] == 2 && decoded.natives[0].functionIndex == 0, "HLB metadata tables did not decode");
	switch decoded.types[2] {
		case Method(arguments, result):
			expect(arguments.length == 1 && arguments[0] == 0 && result == 0, "HLB method type did not decode");
		case _:
			throw "HLB method type did not decode as Method";
	}
	expect(decoded.constants.length == 1 && decoded.constants[0].global == 0 && decoded.constants[0].fields[0] == 0, "HLB constants did not decode");
	expect(decoded.debugSections.length == 1 && decoded.debugSections[0].payload.compare(HaxeBytes.ofString("opaque")) == 0,
		"HLB debug sections did not decode");
	switch decoded.functions[0].opcodes[1] {
		case HlInstruction.ThisGet(_, field):
			expect(field == 0, "HLB OGetThis did not preserve its field index");
		case _:
			throw "HLB OGetThis did not decode as ThisGet";
	}
	switch decoded.functions[0].opcodes[2] {
		case HlInstruction.ThisSet(field, source):
			expect(field == 0 && source == 0, "HLB OSetThis did not preserve its operands");
		case _:
			throw "HLB OSetThis did not decode as ThisSet";
	}
	switch decoded.functions[0].opcodes[3] {
		case HlInstruction.EnumAlloc(destination, constructor):
			expect(destination == 0 && constructor == 0, "HLB OEnumAlloc did not preserve its operands");
		case _:
			throw "HLB OEnumAlloc did not decode as EnumAlloc";
	}
	switch decoded.functions[0].opcodes[4] {
		case HlInstruction.JumpTrue(_, target):
			expect(target == "L6", "HLB relative jump did not become a symbolic label");
		case _:
			throw "HLB jump opcode did not decode as JumpTrue";
	}
	switch decoded.functions[0].opcodes[0] {
		case HlInstruction.LoadBytes(_, constant):
			expect(constant == 1, "HLB byte opcode did not preserve its byte-pool index");
		case _:
			throw "HLB byte opcode did not decode as LoadBytes";
	}
	expect(decoded.functions[0].debugLocations.length == 8
		&& decoded.functions[0].debugLocations[4].line == 5, "HLB debug locations did not decode");
	expect(decoded.functions[0].debugAssignments[0].position == -1 && decoded.functions[0].debugAssignments[0].scopeEnd == -1,
		"HLB debug assignments did not decode");
	var numeric = new HlCode();
	numeric.ints = [1];
	numeric.types = [Simple(HlType.I32)];
	numeric.functions = [
		new compiler.hl.HlFunction(0, 0, [0], [
			UnsignedDiv(0, 0, 0),
			UnsignedMod(0, 0, 0),
			Negate(0, 0),
			BitNot(0, 0),
			Increment(0),
			Decrement(0),
			ToUFloat(0, 0),
			UnsafeCast(0, 0),
			Return(0)
		])
	];
	numeric.entryPoint = 0;
	var numericBytes = HlWriter.encode(numeric),
		numericDecoded = HlReader.decode(numericBytes);
	expect(HlWriter.encode(numericDecoded).compare(numericBytes) == 0 && numericDecoded.functions[0].opcodes.length == 9,
		"HLB scalar opcode extensions did not round trip");
	var calls = new HlCode();
	calls.types = [Simple(HlType.I32)];
	calls.functions = [
		new compiler.hl.HlFunction(0, 0, [0], [
			Call3(0, 0, 0, 0, 0),
			Call4(0, 0, 0, 0, 0, 0),
			VirtualClosure(0, 0, 0),
			ThisCall(0, 0, [0, 0]),
			Return(0)
		])
	];
	calls.entryPoint = 0;
	var callBytes = HlWriter.encode(calls),
		callDecoded = HlReader.decode(callBytes);
	expect(HlWriter.encode(callDecoded).compare(callBytes) == 0 && callDecoded.functions[0].opcodes.length == 5,
		"HLB call and closure opcode extensions did not round trip");
	var branches = new HlCode();
	branches.types = [Simple(HlType.I32)];
	branches.functions = [
		new compiler.hl.HlFunction(0, 0, [0], [
			JumpTrue(0, "done"),
			JumpFalse(0, "done"),
			JumpNull(0, "done"),
			JumpNotNull(0, "done"),
			JumpSignedLess(0, 0, "done"),
			JumpSignedGreaterOrEqual(0, 0, "done"),
			JumpSignedGreater(0, 0, "done"),
			JumpSignedLessOrEqual(0, 0, "done"),
			JumpUnsignedLess(0, 0, "done"),
			JumpUnsignedGreaterOrEqual(0, 0, "done"),
			JumpNotLess(0, 0, "done"),
			JumpNotGreater(0, 0, "done"),
			JumpEqual(0, 0, "done"),
			JumpNotEqual(0, 0, "done"),
			Jump("done"),
			Label("done"),
			Return(0)
		])
	];
	branches.entryPoint = 0;
	var branchBytes = HlWriter.encode(branches),
		branchDecoded = HlReader.decode(branchBytes);
	expect(HlWriter.encode(branchDecoded).compare(branchBytes) == 0 && branchDecoded.functions[0].opcodes.length == 17,
		"HLB conditional branch family did not round trip");
	var references = new HlCode();
	references.types = [Simple(HlType.I32)];
	references.strings = ["field"];
	references.functions = [
		new compiler.hl.HlFunction(0, 0, [0], [
			NullCheck(0),
			GetType(0, 0),
			GetTID(0, 0),
			Ref(0, 0),
			Unref(0, 0),
			SetRef(0, 0),
			RefData(0, 0),
			RefOffset(0, 0, 0),
			DynamicGet(0, 0, 0),
			DynamicSet(0, 0, 0),
			Return(0)
		])
	];
	references.entryPoint = 0;
	var referenceBytes = HlWriter.encode(references),
		referenceDecoded = HlReader.decode(referenceBytes);
	expect(HlWriter.encode(referenceDecoded).compare(referenceBytes) == 0 && referenceDecoded.functions[0].opcodes.length == 11,
		"HLB reference and type opcode family did not round trip");
	var switches = new HlCode();
	switches.types = [Simple(HlType.I32)];
	switches.functions = [
		new compiler.hl.HlFunction(0, 0, [0], [
			Switch(0, ["case1", null, "case2"], "default"),
			Label("case1"),
			Return(0),
			Label("case2"),
			Return(0),
			Label("default"),
			Return(0)
		])
	];
	switches.entryPoint = 0;
	var switchBytes = HlWriter.encode(switches),
		switchDecoded = HlReader.decode(switchBytes);
	expect(HlWriter.encode(switchDecoded).compare(switchBytes) == 0
		&& switchDecoded.functions[0].opcodes.length == 7, "HLB switch opcode did not round trip");
	switch switchDecoded.functions[0].opcodes[0] {
		case Switch(value, targets, defaultTarget):
			expect(value == 0 && targets.length == 3 && targets[0] == null && targets[1] == null && targets[2] == "L3" && defaultTarget == "L5",
				"HLB switch labels did not decode");
		case _:
			throw "HLB switch opcode did not decode as Switch";
	}
	expect(expectFailure(() -> HlReader.decode(encoded.sub(0, encoded.length - 1))), "truncated HLB data was accepted");
	expect(expectFailure(() -> HlReader.decode(withTrailingByte(encoded))), "trailing HLB data was accepted");
	var compiler = new Compiler();
	compiler.update("Main.hx", "function main():Int return 42;");
	var compiled = compiler.compile("Main").module,
		compiledBytes = HlWriter.encode(compiled),
		compiledDecoded = HlReader.decode(compiledBytes);
	expect(compiledDecoded.functions.length == compiled.functions.length && HlWriter.encode(compiledDecoded).compare(compiledBytes) == 0,
		"HLB reader could not consume a compiler-produced module");
	Sys.println("PASS: HLB reader owns complete module metadata and rejects malformed input");
}

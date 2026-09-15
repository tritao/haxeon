import compiler.hl.HlCode;
import compiler.hl.HlCode.HlTypeDef;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlReader;
import compiler.hl.HlType;
import compiler.hl.HlWriter;
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
			HlInstruction.LoadInt(0, 0),
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
	expect(decoded.types.length == 3 && decoded.globals[0] == 2 && decoded.natives[0].functionIndex == 0, "HLB metadata tables did not decode");
	expect(decoded.constants.length == 1 && decoded.constants[0].global == 0 && decoded.constants[0].fields[0] == 0, "HLB constants did not decode");
	expect(decoded.debugSections.length == 1 && decoded.debugSections[0].payload.compare(HaxeBytes.ofString("opaque")) == 0,
		"HLB debug sections did not decode");
	switch decoded.functions[0].opcodes[1] {
		case HlInstruction.JumpTrue(_, target):
			expect(target == "L3", "HLB relative jump did not become a symbolic label");
		case _:
			throw "HLB jump opcode did not decode as JumpTrue";
	}
	expect(decoded.functions[0].debugLocations.length == 5
		&& decoded.functions[0].debugLocations[4].line == 5, "HLB debug locations did not decode");
	expect(decoded.functions[0].debugAssignments[0].position == -1 && decoded.functions[0].debugAssignments[0].scopeEnd == -1,
		"HLB debug assignments did not decode");
	expect(expectFailure(() -> HlReader.decode(encoded.sub(0, encoded.length - 1))), "truncated HLB data was accepted");
	expect(expectFailure(() -> HlReader.decode(withTrailingByte(encoded))), "trailing HLB data was accepted");
	Sys.println("PASS: HLB reader owns complete module metadata and rejects malformed input");
}

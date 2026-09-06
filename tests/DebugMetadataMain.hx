import compiler.Frontend;
import compiler.Source.SourceFile;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlWriter;
import compiler.ir.IrFunction;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.hl.HlLower;
import haxe.io.Bytes;
import haxe.io.BytesOutput;

/** Focused regression coverage for the source-local debug metadata pipeline. */
class DebugMetadataMain {
	static function main():Void {
		var program = Frontend.compileFile(new SourceFile("debug-metadata.hx",
			"function probe(input:Int):Int {\n"
			+ "  var result = input + 1;\n"
			+ "  result = result + 1;\n"
			+ "  return result;\n"
			+ "}\n"
			+ "function main():Int return probe(40);\n"));
		var irIndex = findFunctionIndex(program.functions, "probe"), ir = program.functions[irIndex];
		if (ir.debugBindings.length != 2)
			throw 'Expected two result bindings, got ${ir.debugBindings.length}';
		for (binding in ir.debugBindings) {
			if (binding.name != "result")
				throw 'Internal SSA local leaked into debugger metadata: ${binding.name}';
			if (StringTools.startsWith(binding.value.name, "$operand"))
				throw 'Compiler operand temporary became a source binding: ${binding.value.name}';
		}
		Sys.println("PASS: SSA preserves source local names and filters compiler temporaries");

		var encodedIr = IrFunctionStateCodec.encode(ir),
			restored = IrFunctionStateCodec.decode(encodedIr);
		if (restored.debugBindings.length != ir.debugBindings.length)
			throw "IR cache round trip lost debug bindings";
		for (index in 0...ir.debugBindings.length) {
			var expected = ir.debugBindings[index], actual = restored.debugBindings[index];
			if (actual.name != expected.name || actual.value.id != expected.value.id)
				throw "IR cache round trip changed a debug binding";
		}
		if (encodedIr.compare(IrFunctionStateCodec.encode(restored)) != 0)
			throw "IR debug binding encoding is not deterministic";
		Sys.println("PASS: IR cache round trip preserves debug bindings deterministically");

		var code = HlLower.lower(program),
			fn = code.functions[irIndex],
			argumentAssignments = 0,
			resultPositions:Array<Int> = [];
		for (assignment in fn.debugAssignments) {
			var name = code.strings[assignment.name];
			if (assignment.position == -1 && name == "input")
				argumentAssignments++;
			if (name == "result") {
				if (assignment.position <= 0 || assignment.position >= fn.opcodes.length)
					throw 'Invalid result assignment opcode position ${assignment.position}';
				switch fn.opcodes[assignment.position] {
					case Label(_): throw "Debug assignment points at a label instead of its defining opcode";
					default:
				}
				resultPositions.push(assignment.position);
			}
			if (assignment.scopeEnd != -1)
				throw "Open-ended source bindings unexpectedly acquired a scope end";
		}
		if (argumentAssignments != 1 || resultPositions.length != 2 || resultPositions[0] >= resultPositions[1])
			throw 'HL lowering lost or reordered argument/local assignments: arguments=$argumentAssignments, result positions=$resultPositions, all=${[
				for (assignment in fn.debugAssignments) code.strings[assignment.name] + "@" + assignment.position
			].join(",")}';
		if (!hasLabelBefore(fn.opcodes, resultPositions[0]))
			throw "Fixture did not verify assignment positions in the presence of encoded labels";
		Sys.println("PASS: HL assignments use encoded opcode positions, including labels");

		var bytes = HlWriter.encode(code), suffix = encodedAssignmentSuffix(fn.debugAssignments);
		if (!contains(bytes, suffix))
			throw "HLB output did not serialize canonical debug assignment triples";
		Sys.println("PASS: HLB serializes canonical local assignment metadata");
	}

	static function findFunctionIndex(functions:Array<IrFunction>, name:String):Int {
		for (index in 0...functions.length)
			if (functions[index].name == name)
				return index;
		throw 'Missing IR function $name';
	}

	static function hasLabelBefore(opcodes:Array<HlInstruction>, position:Int):Bool {
		for (index in 0...position)
			switch opcodes[index] {
				case Label(_): return true;
				default:
			}
		return false;
	}

	static function encodedAssignmentSuffix(assignments:Array<compiler.hl.HlFunction.HlDebugAssignment>):Bytes {
		var output = new BytesOutput();
		output.write(HlWriter.encodeIndex(assignments.length));
		for (assignment in assignments) {
			output.write(HlWriter.encodeIndex(assignment.name));
			output.write(HlWriter.encodeIndex(assignment.position + 1));
			output.write(HlWriter.encodeIndex(assignment.scopeEnd + 1));
		}
		return output.getBytes();
	}

	static function contains(bytes:Bytes, expected:Bytes):Bool {
		if (expected.length > bytes.length)
			return false;
		for (offset in 0...bytes.length - expected.length + 1) {
			var matches = true;
			for (index in 0...expected.length)
				if (bytes.get(offset + index) != expected.get(index)) {
					matches = false;
					break;
				}
			if (matches)
				return true;
		}
		return false;
	}
}

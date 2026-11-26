using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Frontend;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.core.Source.SourceFile;
import compiler.hl.HlBytecodeInput;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlWriter;
import compiler.hl.lower.HlLower;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.model.IrFunction;
import haxe.io.Bytes;
import haxe.io.BytesInput;
import haxe.io.BytesOutput;

/** Focused regression coverage for the source-local debug metadata pipeline. */
class DebugMetadataMain {
	static function main():Void {
		// The loop gives probe a label before its assignments (a loop header is entered again), which a straight-line body
		// no longer has; it counts down a static variable, so it adds no source local to the bindings checked below.
		var program = Frontend.compileFile(new SourceFile("debug-metadata.hx",
			"class Spin { public static var count = 0; }\n"
			+ "function probe(input:Int):Int {\n"
			+ "  while (Spin.count > 0) Spin.count--;\n"
			+ "  var result = input + 1;\n"
			+ "  result = result + 1;\n"
			+ "  return result;\n"
			+ "}\n"
			+ "function main():Int return probe(40);\n"));
		var irIndex = findFunctionIndex(program.functions, "probe"),
			ir = program.functions[irIndex];
		if (ir.debugBindings.length != 3)
			throw 'Expected one argument and two result bindings, got ${ir.debugBindings.length}';
		var resultBindingCount = 0;
		for (binding in ir.debugBindings) {
			if (binding.name != "input" && binding.name != "result")
				throw 'Internal SSA local leaked into debugger metadata: ${binding.name}';
			if (binding.name == "result")
				resultBindingCount++;
			if (StringTools.startsWith(binding.value.name, "$operand"))
				throw 'Compiler operand temporary became a source binding: ${binding.value.name}';
		}
		if (resultBindingCount != 2)
			throw 'Expected two result assignments, got $resultBindingCount';
		Sys.println("PASS: SSA preserves source local names and filters compiler temporaries");

		var encodedIr = IrFunctionStateCodec.encode(ir),
			restored = IrFunctionStateCodec.decode(encodedIr);
		if (restored.debugBindings.length != ir.debugBindings.length)
			throw "IR cache round trip lost debug bindings";
		for (index in 0...ir.debugBindings.length) {
			var expected = ir.debugBindings[index],
				actual = restored.debugBindings[index];
			if (actual.identity != expected.identity
				|| actual.name != expected.name
				|| actual.value.id != expected.value.id
				|| actual.anchor != expected.anchor
				|| actual.scopeStart != expected.scopeStart
				|| actual.scopeEnd != expected.scopeEnd)
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
					case Label(_):
						throw "Debug assignment points at a label instead of its defining opcode";
					default:
				}
				resultPositions.push(assignment.position);
			}
		}
		if (argumentAssignments != 1 || resultPositions.length != 2 || resultPositions[0] >= resultPositions[1])
			throw 'HL lowering lost or reordered argument/local assignments: arguments=$argumentAssignments, result positions=$resultPositions, all=${[for (assignment in fn.debugAssignments) code.strings[assignment.name] + "@" + assignment.position].join(",")}';
		if (!hasLabelBefore(fn.opcodes, resultPositions[0]))
			throw "Fixture did not verify assignment positions in the presence of encoded labels";
		Sys.println("PASS: HL assignments use encoded opcode positions, including labels");

		var bytes = HlWriter.encode(code).flatten(),
			suffix = encodedAssignmentSuffix(fn);
		if (bytes.get(3) != compiler.hl.HlCode.VERSION
			|| code.debugSections.length != 1
			|| code.debugSections[0].kind != HlWriter.OPCODE_SOURCE_SPANS
			|| code.debugSections[0].payload.length == 0)
			throw "The lowering did not attach its opcode source spans";
		var identities = [
			for (section in compiler.hl.HlModuleReader.read(bytes).sections)
				if (section.kind == HlWriter.FUNCTION_IDENTITIES)
				compiler.hl.HlModuleReader.functionIdentities(section.payload)
		];
		if (identities.length != 1 || identities[0].length != code.functions.length)
			throw "A dense module does not name its functions";
		for (index in 0...code.functions.length)
			if (identities[0][index].qualifiedName != code.functionNames[index]
				|| identities[0][index].stableId != code.functions[index].functionIndex)
				throw "A dense module names a function otherwise than the lowering";
		if (bytes.compare(HlWriter.encode(code).flatten()) != 0)
			throw "HLB debug section encoding is not deterministic";
		if (!contains(bytes, suffix))
			throw "HLB output did not serialize canonical debug assignment triples";
		Sys.println("PASS: HLB serializes deterministic local and function debug metadata");

		var spans = opcodeSpans(code.debugSections[0].payload.flatten());
		for (compiledFunction in code.functions) {
			var positions = HlWriter.layout(compiledFunction.opcodes),
				actual = spans.get(compiledFunction.functionIndex),
				// One span per instruction written: a label no jump lands on again is left out (HlWriter.layout).
				expected = [
					for (opcode in 0...compiledFunction.opcodes.length)
						if (positions[opcode + 1] != positions[opcode]) compiledFunction.debugLocations[opcode]
				];
			if (actual == null || actual.length != expected.length)
				throw "The opcode source spans lost a function's spans";
			// The module's locations count from their anchors (`HlDebugLocation`); the section has them placed in its sources.
			var sources = code.sources;
			for (opcode in 0...actual.length) {
				var location = expected[opcode],
					anchor = location.anchor,
					line = sources.line(anchor),
					offset = sources.offset(anchor);
				if (actual[opcode].file != sources.path(anchor)
					|| actual[opcode].line != line + location.line
					|| actual[opcode].column != location.column
					|| actual[opcode].endLine != line + location.endLine
					|| actual[opcode].endColumn != location.endColumn
					|| actual[opcode].sourceHash != (location.generatedText ? 0 : sources.hash(anchor))
					|| actual[opcode].start != (location.start < 0 ? -1 : offset + location.start)
					|| actual[opcode].end != (location.end < 0 ? -1 : offset + location.end)
					|| actual[opcode].flags != location.flags)
					throw "The opcode source spans changed a location";
			}
		}
		Sys.println("PASS: the opcode source spans place each location precisely");

		testSourceSnapshots();
		testShadowedScopes();
	}

	static function testSourceSnapshots():Void {
		var text = "// café 😀\nfunction main():Int {\n  return 42;\n}",
			source = new SourceFile("snapshot.hx", text),
			compiler = new compiler.Compiler();
		compiler.update(source.path, source.text);
		compiler.update("unused.hx", "function unused():Int return 0;");
		var result = compiler.compile("snapshot"),
			snapshots = result.artifact.hashLink().module.sourceSnapshots;
		if (snapshots.length != 1 || snapshots[0].sourceHash != source.contentHash()
			|| snapshots[0].content.toString() != text)
			throw "Compiler did not retain the reachable source snapshot";
		var sections = [
			for (section in result.artifact.hashLink().module.debugSections)
				if (section.kind == HlWriter.SOURCE_SNAPSHOTS) section
		];
		if (sections.length != 1 || sections[0].version != 1
			|| !sections[0].payload.equals(HlWriter.encodeSourceSnapshots(snapshots)))
			throw "Compiler did not emit the canonical source snapshot section";
		if (result.artifact.hashLink().hashLinkBytes().flatten()
			.compare(result.artifact.hashLink().hashLinkBytes().flatten()) != 0)
			throw "HLB source snapshot encoding is not deterministic";
		Sys.println("PASS: compiler emits deterministic content-addressed source snapshots");
	}

	static function testShadowedScopes():Void {
		var program = Frontend.compileFile(new SourceFile("debug-scopes.hx",
			"function scoped(flag:Bool):Int {\n"
			+ "  var value = 1;\n"
			+ "  if (flag) {\n"
			+ "    var value = 2;\n"
			+ "    value = value + 1;\n"
			+ "  }\n"
			+ "  return value;\n"
			+ "}\n"
			+ "function main():Int return scoped(true);\n"));
		var index = findFunctionIndex(program.functions, "scoped"),
			ir = program.functions[index],
			identities:Map<String, Bool> = [];
		for (binding in ir.debugBindings)
			if (binding.name == "value")
				identities.set(binding.identity, true);
		var identityCount = 0;
		for (_ in identities)
			identityCount++;
		if (identityCount != 2)
			throw 'Shadowed locals did not retain distinct identities: $identityCount';

		var code = HlLower.lower(program), fn = code.functions[index], bounded = 0, open = 0;
		assertAssignmentsSorted(fn.debugAssignments);
		for (assignment in fn.debugAssignments)
			if (code.strings[assignment.name] == "value") {
				if (assignment.scopeEnd < 0)
					open++;
				else {
					bounded++;
					if (assignment.scopeEnd <= assignment.position || assignment.scopeEnd >= fn.opcodes.length)
						throw 'Invalid nested scope range ${assignment.position}...${assignment.scopeEnd}';
				}
			}
		if (bounded != 2 || open != 1)
			throw 'Expected two bounded inner assignments and one function-scoped assignment, got bounded=$bounded open=$open';
		Sys.println("PASS: shadowed locals retain distinct identities and lexical opcode lifetimes");
	}

	/** By function index, the spans of an opcode source-span section (version 2, `HlWriter.encodeOpcodeSourceSpanGroups`). */
	static function opcodeSpans(payload:Bytes):Map<Int, Array<{
		file:String,
		start:Int,
		end:Int,
		line:Int,
		column:Int,
		endLine:Int,
		endColumn:Int,
		sourceHash:Int,
		flags:Int
	}>> {
		var input = new BytesInput(payload), files = [for (_ in 0...HlBytecodeInput.index(input)) {
			var length = HlBytecodeInput.index(input);
			input.readString(length);
		}], result = new Map();
		for (_ in 0...HlBytecodeInput.index(input)) {
			var index = HlBytecodeInput.index(input), written = HlBytecodeInput.index(input), spans = [];
			for (_ in 0...written) {
				HlBytecodeInput.index(input);
				var file = files[HlBytecodeInput.index(input)],
					start = HlBytecodeInput.index(input) - 1,
					end = HlBytecodeInput.index(input) - 1,
					line = HlBytecodeInput.index(input),
					column = HlBytecodeInput.index(input),
					endLine = HlBytecodeInput.index(input),
					endColumn = HlBytecodeInput.index(input),
					sourceHash = input.readInt32(),
					flags = HlBytecodeInput.index(input);
				spans.push({
					file: file,
					start: start,
					end: end,
					line: line,
					column: column,
					endLine: endLine,
					endColumn: endColumn,
					sourceHash: sourceHash,
					flags: flags
				});
			}
			result.set(index, spans);
		}
		return result;
	}

	static function assertAssignmentsSorted(assignments:Array<compiler.hl.HlFunction.HlDebugAssignment>):Void {
		var previous = -1;
		for (assignment in assignments)
			if (assignment.position >= 0) {
				if (assignment.position < previous)
					throw 'Debug assignments are not sorted: ${assignment.position} follows $previous';
				previous = assignment.position;
			}
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
				case Label(_):
					return true;
				default:
			}
		return false;
	}

	/** `fn`'s debug assignments as HlWriter writes them: each position is where its instruction lands (HlWriter.layout). */
	static function encodedAssignmentSuffix(fn:compiler.hl.HlFunction):Bytes {
		var output = new BytesOutput(), positions = HlWriter.layout(fn.opcodes);
		output.write(HlWriter.encodeIndex(fn.debugAssignments.length));
		for (assignment in fn.debugAssignments) {
			output.write(HlWriter.encodeIndex(assignment.name));
			output.write(HlWriter.encodeIndex(assignment.position < 0 ? 0 : positions[assignment.position] + 1));
			output.write(HlWriter.encodeIndex(assignment.scopeEnd < 0 ? 0 : positions[assignment.scopeEnd] + 1));
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

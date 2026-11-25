using compiler.compilation.BackendArtifact.BackendArtifacts;
import compiler.Frontend;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.core.Source.SourceFile;
import compiler.hl.HlFunction.HlInstruction;
import compiler.hl.HlWriter;
import compiler.hl.HlWriterCache;
import compiler.hl.lower.HlLower;
import compiler.hl.patch.HlPatchReader;
import compiler.hl.patch.HlPatchWriter;
import compiler.ir.codec.IrFunctionStateCodec;
import compiler.ir.model.IrFunction;
import haxe.io.Bytes;
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
			|| code.debugSections.length != 2
			|| code.debugSections[0].kind != HlWriter.FUNCTION_IDENTITIES
			|| code.debugSections[1].kind != HlWriter.OPCODE_SOURCE_SPANS
			|| code.debugSections[1].payload.length == 0)
			throw "HLB function identity and opcode source-span sections were not emitted";
		if (bytes.compare(HlWriter.encode(code).flatten()) != 0)
			throw "HLB debug section encoding is not deterministic";
		var writerCache = new HlWriterCache();
		for (_ in 0...2) {
			var streamed = new BytesOutput();
			HlWriter.writeTo(code, streamed, writerCache);
			if (bytes.compare(streamed.getBytes()) != 0)
				throw "Streamed HLB encoding differs from canonical bytes";
		}
		if (fn.debugLocations.length < 3)
			throw "Debug-file cache fixture needs three opcode locations";
		// A function never changes (the writer and HlFunction.anchors rely on it): the fixture's mixed paths are another function.
		var mixedLocations = fn.debugLocations.copy();
		for (index in 0...3) {
			var location = mixedLocations[index];
			mixedLocations[index] =
				new compiler.hl.HlFunction.HlDebugLocation(compiler.core.SourceAnchor.file(index == 1
				? "second-source.hx" : "first-source.hx"), location.line,
				location.column, location.endLine, location.endColumn, location.start, location.end, location.flags,
				location.generatedText);
		}
		var fnIndex = code.functions.indexOf(fn);
		code.functions[fnIndex] = new compiler.hl.HlFunction(fn.type, fn.functionIndex, fn.registers, fn.opcodes,
			mixedLocations, fn.debugAssignments);
		var mixedPaths = HlWriter.encode(code).flatten(),
			mixedCache = new HlWriterCache();
		for (_ in 0...2) {
			var streamed = new BytesOutput();
			HlWriter.writeTo(code, streamed, mixedCache);
			if (mixedPaths.compare(streamed.getBytes()) != 0)
				throw "Cached debug files changed non-contiguous source-file ordering";
		}
		code.functions[fnIndex] = fn;
		if (!contains(bytes, suffix))
			throw "HLB output did not serialize canonical debug assignment triples";
		Sys.println("PASS: HLB serializes deterministic local and function debug metadata");

		var stableBySlot:Map<Int, Int> = [
			for (compiledFunction in code.functions)
				compiledFunction.functionIndex => compiledFunction.functionIndex
		],
			patch = HlPatchReader.decode(HlPatchWriter.encode(code, haxe.io.Bytes.alloc(16),
				[for (compiledFunction in code.functions) compiledFunction.functionIndex], stableBySlot, 0, 1,
				code.ints.length, code.floats.length,
				code.strings.length, code.types.length));
		for (index in 0...patch.functions.length) {
			var compiledFunction = code.functions[index],
				positions = HlWriter.layout(compiledFunction.opcodes),
				actual = patch.functions[index].debug,
				// One span per instruction written: a label no jump lands on again is left out (HlWriter.layout).
				expected = [
					for (opcode in 0...compiledFunction.opcodes.length)
						if (positions[opcode + 1] != positions[opcode]) compiledFunction.debugLocations[opcode]
				];
			if (actual.length != expected.length)
				throw "HLP lost opcode source spans";
			// The module's locations count from their anchors (`HlDebugLocation`); the patch has them placed in its sources.
			var sources = code.sources;
			for (opcode in 0...actual.length) {
				var location = expected[opcode],
					anchor = location.anchor,
					line = sources.line(anchor),
					offset = sources.offset(anchor);
				if (patch.debugFiles[actual[opcode].file] != sources.path(anchor)
					|| actual[opcode].line != line + location.line
					|| actual[opcode].column != location.column
					|| actual[opcode].endLine != line + location.endLine
					|| actual[opcode].endColumn != location.endColumn
					|| actual[opcode].sourceHash != (location.generatedText ? 0 : sources.hash(anchor))
					|| actual[opcode].start != (location.start < 0 ? -1 : offset + location.start)
					|| actual[opcode].end != (location.end < 0 ? -1 : offset + location.end)
					|| actual[opcode].flags != location.flags)
					throw "HLP changed an opcode source span";
			}
		}
		Sys.println("PASS: HLP preserves precise opcode source spans");

		testSourceSnapshots();
		testShadowedScopes();
		testIdentitiesFollowStableIds();
	}

	/**
	 * A plain build assembles a fresh layout with the session's debug cache, which keeps each function's identity while the function
	 * is the same IR object: a layout that gives it another stable id at the same index must not keep the earlier identity.
	 */
	static function testIdentitiesFollowStableIds():Void {
		var compiler = new compiler.Compiler();
		compiler.update("Main.hx",
			"function add(a:Int, b:Int):Int { return a + b; } function main():Int { return add(20, 22); }");
		var program = compiler.compile("Main").ir,
			names = [for (fn in program.functions) fn.name];
		function identities(stableIds:Null<Map<String, Int>>, debug:compiler.hl.lower.HlDebugMetadataCache):Bytes {
			var assembler = new compiler.hl.incremental.HlModuleAssembler(stableIds, debug);
			assembler.irVerified = true;
			assembler.sources = compiler.sourceAnchors();
			assembler.loweredCache = new compiler.hl.incremental.HlLoweredCache(debug);
			var module = assembler.assemble(program, names, Patch).module;
			for (section in module.debugSections)
				if (section.kind == HlWriter.FUNCTION_IDENTITIES)
					return section.payload.flatten();
			throw "The module has no function identities";
		}
		var shared = new compiler.hl.lower.HlDebugMetadataCache();
		identities(null, shared);
		var moved = identities([for (index in 0...names.length) names[index] => 1000 + index], shared),
			fresh = identities([for (index in 0...names.length) names[index] => 1000 + index],
				new compiler.hl.lower.HlDebugMetadataCache());
		if (moved.compare(fresh) != 0)
			throw "A shared debug cache kept function identities whose stable ids moved";
		Sys.println("PASS: function identities follow the stable ids of a fresh layout");
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
		if (HlWriter.encode(result.artifact.hashLink().module).flatten()
			.compare(HlWriter.encode(result.artifact.hashLink().module).flatten()) != 0)
			throw "HLB source snapshot encoding is not deterministic";
		var stableBySlot:Map<Int, Int> =
			[for (fn in result.artifact.hashLink().module.functions) fn.functionIndex => fn.functionIndex],
			patch = HlPatchReader.decode(HlPatchWriter.encode(result.artifact.hashLink().module, Bytes.alloc(16),
				[for (fn in result.artifact.hashLink().module.functions) fn.functionIndex],
				stableBySlot, 0, 1, result.artifact.hashLink().module.ints.length,
				result.artifact.hashLink().module.floats.length,
				result.artifact.hashLink().module.strings.length, result.artifact.hashLink().module.types.length));
		if (patch.sourceSnapshots.length != 1
			|| patch.sourceSnapshots[0].sourceHash != source.contentHash()
			|| patch.sourceSnapshots[0].content.toString() != text)
			throw "HLP did not preserve the referenced source snapshot";
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

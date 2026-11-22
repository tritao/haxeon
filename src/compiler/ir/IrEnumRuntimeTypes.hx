package compiler.ir;

import compiler.ir.Ir;

/** Boxed enum descriptors are needed by boxed carriers and reflection, never by a nominal I32 tag alone. */
class IrEnumRuntimeTypes {
	/**
	 * The enums whose boxed descriptors the program needs. `memo` keeps each function's part (`functionNames`) while the function is
	 * the same object.
	 */
	public static function declarations(program:IrProgram, ?memo:IrFunctionMemo<Array<String>>):Array<IrEnum> {
		var candidates:Map<String, Bool> = [
			for (entry in program.enums)
				if (IrEnumTagStorage.eligible(entry)) entry.name => true
		];
		if (!candidates.keys().hasNext())
			return program.enums;
		var required:Map<String, Bool> = [];
		function note(name:String):Void
			if (candidates.exists(name))
				required.set(name, true);
		for (object in program.objects)
			for (field in object.fields)
				visit(field.type, note);
		for (field in program.staticFields)
			visit(field.type, note);
		for (entry in program.enums)
			for (constructor in entry.cases)
				for (parameter in constructor.params)
					visit(parameter, note);
		for (entry in program.interfaces)
			for (method in entry.methods) {
				for (argument in method.arguments)
					visit(argument, note);
				visit(method.result, note);
			}
		for (entry in program.natives) {
			for (argument in entry.arguments)
				visit(argument, note);
			visit(entry.result, note);
		}
		for (entry in program.cNatives) {
			for (argument in entry.arguments)
				visit(argument, note);
			visit(entry.result, note);
		}
		for (fn in program.functions) {
			var names = memo == null ? null : memo.get(fn);
			if (names == null) {
				names = functionNames(fn);
				if (memo != null)
					memo.set(fn, names);
			}
			for (name in names)
				note(name);
		}
		return [
			for (entry in program.enums)
				if (!candidates.exists(entry.name) || required.exists(entry.name)) entry
		];
	}

	/** The enums function `fn` may need a boxed descriptor of, which depends on nothing else: each once. */
	public static function functionNames(fn:IrFunction):Array<String> {
		var names:Array<String> = [], seen:Map<String, Bool> = [];
		function note(name:String):Void
			if (!seen.exists(name)) {
				seen.set(name, true);
				names.push(name);
			}
		function value(value:IrValue):Bool {
			visit(value.type, note);
			return false;
		}
		switch fn.kind {
			case ClosureAdapter(source, target):
				descriptor(source, note);
				descriptor(target, note);
			case ClosureCast(target), ClosureVarargs(target):
				descriptor(target, note);
			default:
		}
		for (argument in fn.arguments)
			visit(argument.type, note);
		visit(fn.result, note);
		// The inliner's output is read as its body; a function made after it, as objects.
		var body = fn.body;
		if (body != null) {
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					var output = body.output(row);
					if (output.exists())
						visit(body.valueType(output), note);
					for (operand in 0...body.operandCount(row))
						visit(body.valueType(body.operand(row, operand)), note);
					if (body.opcode(row) == IrOpcode.TypeValue)
						descriptor(body.typeOperand(row), note);
					row = body.nextRow(row);
				}
			}
			return names;
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				IrOperands.anyValue(located.value, value);
				switch located.value {
					case TypeValue(_, type):
						descriptor(type, note);
					default:
				}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(output), Throw(output), Rethrow(output):
						visit(output.type, note);
					case Branch(condition, _, _), Switch(condition, _, _):
						visit(condition.type, note);
					case Jump(_), Unreachable:
				}
		}
		return names;
	}

	/** Notes each enum a value of `type` carries boxed. */
	static function visit(type:IrType, note:String->Void):Void
		switch type {
			case Enum(name):
				note(name);
			case Array(inner), Iterator(inner), Nullable(inner):
				visit(inner, note);
			case Function(arguments, result):
				for (argument in arguments)
					visit(argument, note);
				visit(result, note);
			default:
		}

	/** Notes each enum a type value of `type` describes, its tags included. */
	static function descriptor(type:IrType, note:String->Void):Void
		switch type {
			case EnumTag(name):
				note(name);
			case Array(inner), Iterator(inner), Nullable(inner):
				descriptor(inner, note);
			case Function(arguments, result):
				for (argument in arguments)
					descriptor(argument, note);
				descriptor(result, note);
			default:
				visit(type, note);
		}

	/** This is a backend-only view, made after logical IR verification; the original keeps tag declarations for invariants. */
	public static function physical(program:IrProgram):IrProgram {
		var declarations = declarations(program);
		if (declarations.length == program.enums.length)
			return program;
		var result = new IrProgram(program.entryPoint);
		result.enums = declarations;
		result.functions = program.functions;
		result.objects = program.objects;
		result.interfaces = program.interfaces;
		result.staticFields = program.staticFields;
		result.natives = program.natives;
		result.cNatives = program.cNatives;
		result.positionalFingerprints = program.positionalFingerprints;
		result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		return result;
	}
}

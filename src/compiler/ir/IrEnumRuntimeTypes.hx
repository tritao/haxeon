package compiler.ir;

import compiler.ir.Ir;

/** Boxed enum descriptors are needed by boxed carriers and reflection, never by a nominal I32 tag alone. */
class IrEnumRuntimeTypes {
	public static function declarations(program:IrProgram):Array<IrEnum> {
		var candidates:Map<String, Bool> = [
			for (entry in program.enums)
				if (IrEnumTagStorage.eligible(entry)) entry.name => true
		];
		if (!candidates.keys().hasNext())
			return program.enums;
		var required:Map<String, Bool> = [];
		function visit(type:IrType):Void
			switch type {
				case Enum(name):
					if (candidates.exists(name))
						required.set(name, true);
				case Array(inner), Iterator(inner), Nullable(inner):
					visit(inner);
				case Function(arguments, result):
					for (argument in arguments)
						visit(argument);
					visit(result);
				default:
			}
		function descriptor(type:IrType):Void
			switch type {
				case EnumTag(name):
					if (candidates.exists(name))
						required.set(name, true);
				case Array(inner), Iterator(inner), Nullable(inner):
					descriptor(inner);
				case Function(arguments, result):
					for (argument in arguments)
						descriptor(argument);
					descriptor(result);
				default:
					visit(type);
			}
		function value(value:IrValue):Bool {
			visit(value.type);
			return false;
		}
		for (object in program.objects)
			for (field in object.fields)
				visit(field.type);
		for (field in program.staticFields)
			visit(field.type);
		for (entry in program.enums)
			for (constructor in entry.cases)
				for (parameter in constructor.params)
					visit(parameter);
		for (entry in program.interfaces)
			for (method in entry.methods) {
				for (argument in method.arguments)
					visit(argument);
				visit(method.result);
			}
		for (entry in program.natives) {
			for (argument in entry.arguments)
				visit(argument);
			visit(entry.result);
		}
		for (entry in program.cNatives) {
			for (argument in entry.arguments)
				visit(argument);
			visit(entry.result);
		}
		for (fn in program.functions) {
			for (argument in fn.arguments)
				visit(argument.type);
			visit(fn.result);
			for (block in fn.blocks) {
				for (located in block.instructions) {
					IrOperands.anyValue(located.value, value);
					switch located.value {
						case TypeValue(_, type):
							descriptor(type);
						default:
					}
				}
				if (block.terminator != null)
					switch block.terminator.value {
						case Return(output), Throw(output), Rethrow(output):
							visit(output.type);
						case Branch(condition, _, _):
							visit(condition.type);
						case Jump(_):
					}
			}
		}
		return [
			for (entry in program.enums)
				if (!candidates.exists(entry.name) || required.exists(entry.name)) entry
		];
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

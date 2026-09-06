package compiler.abi;

import compiler.ir.Ir;

/** Deterministic semantic descriptions of every runtime-visible declaration. */
typedef RuntimeAbiDescriptor = {
	final functions:Map<String, String>;
	final objects:Map<String, String>;
	final interfaces:Map<String, String>;
	final enums:Map<String, String>;
	final globals:Map<String, String>;
}

/** Canonical description of the runtime-visible ABI emitted to HashLink. */
class RuntimeAbi {
	public static function describe(program:IrProgram):RuntimeAbiDescriptor {
		var functions:Map<String, String> = [],
			objects:Map<String, String> = [],
			interfaces:Map<String, String> = [],
			enums:Map<String, String> = [],
			globals:Map<String, String> = [];
		for (fn in program.functions)
			functions.set(fn.name, signature([for (argument in fn.arguments) argument.type], fn.result));
		for (object in program.objects)
			objects.set(object.name,
				'base=${object.base};interfaces=${object.interfaces.join(",")};fields=${[for (field in object.fields) field.name + ":" + typeKey(field.type)].join(",")};methods=${[for (method in object.methods) method.name + ":" + method.functionName].join(",")}');
		for (declaration in program.interfaces)
			interfaces.set(declaration.name,
				'bases=${declaration.bases.join(",")};methods=${[for (method in declaration.methods) method.name + signature(method.arguments, method.result)].join(",")}');
		for (declaration in program.enums)
			enums.set(declaration.name, [
				for (constructor in declaration.cases)
					constructor.name + "(" + [for (parameter in constructor.params) typeKey(parameter)].join(",") + ")"
			].join(";"));
		for (field in program.staticFields)
			globals.set(field.name, typeKey(field.type));
		return {
			functions: functions,
			objects: objects,
			interfaces: interfaces,
			enums: enums,
			globals: globals
		};
	}

	static function signature(arguments:Array<IrType>, result:IrType):String
		return "(" + [for (argument in arguments) typeKey(argument)].join(",") + ")->" + typeKey(result);

	static function typeKey(type:IrType):String
		return switch type {
			case Array(element): 'Array<${typeKey(element)}>';
			case Function(arguments, result): signature(arguments, result);
			default: Std.string(type);
		};
}

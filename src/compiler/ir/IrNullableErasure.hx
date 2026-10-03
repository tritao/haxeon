package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrFunction.IrDebugBinding;
import compiler.ir.SourceProvenance.Located;

/**
 * Rewrites a program so that no type mentions `Nullable`: each becomes `Dyn`, which has the same representation. The Wasm
 * backends and the C header emitter have no use for the distinction, so they receive the erased program. A function that
 * never mentions a nullable primitive is returned as is, so its identity survives for the caches keyed on it.
 */
class IrNullableErasure {
	public static function run(program:IrProgram):IrProgram {
		if (!mentionsNullable(program))
			return program;
		var result = new IrProgram(program.entryPoint);
		result.natives = [for (native in program.natives) eraseNative(native)];
		result.cNatives = [for (native in program.cNatives) eraseCNative(native)];
		result.functions = [for (fn in program.functions) eraseFunction(fn)];
		result.objects = [
			for (object in program.objects)
				{
					name: object.name,
					isValue: object.isValue,
					base: object.base,
					interfaces: object.interfaces,
					fields: [
						for (field in object.fields)
							{name: field.name, type: IrTypeTools.erase(field.type)}
					],
					methods: object.methods
				}
		];
		result.interfaces = [
			for (entry in program.interfaces)
				{
					name: entry.name,
					bases: entry.bases,
					methods: [
						for (method in entry.methods)
							{
								name: method.name,
								arguments: [for (argument in method.arguments) IrTypeTools.erase(argument)],
								result: IrTypeTools.erase(method.result)
							}
					]
				}
		];
		result.enums = [
			for (entry in program.enums)
				{
					name: entry.name,
					cases: [
						for (enumCase in entry.cases)
							{name: enumCase.name, params: [for (type in enumCase.params) IrTypeTools.erase(type)]}
					]
				}
		];
		result.staticFields = [
			for (field in program.staticFields)
				{name: field.name, type: IrTypeTools.erase(field.type)}
		];
		return result;
	}

	/** Whether any type anywhere in the program is or contains a nullable primitive. */
	public static function mentionsNullable(program:IrProgram):Bool {
		for (fn in program.functions)
			if (functionMentionsNullable(fn))
				return true;
		for (object in program.objects)
			for (field in object.fields)
				if (IrTypeTools.containsNullable(field.type))
					return true;
		for (native in program.natives) {
			if (IrTypeTools.containsNullable(native.result))
				return true;
			for (argument in native.arguments)
				if (IrTypeTools.containsNullable(argument))
					return true;
		}
		for (native in program.cNatives) {
			if (IrTypeTools.containsNullable(native.result))
				return true;
			for (argument in native.arguments)
				if (IrTypeTools.containsNullable(argument))
					return true;
		}
		for (entry in program.interfaces) {
			for (method in entry.methods) {
				if (IrTypeTools.containsNullable(method.result))
					return true;
				for (argument in method.arguments)
					if (IrTypeTools.containsNullable(argument))
						return true;
			}
		}
		for (entry in program.enums)
			for (enumCase in entry.cases)
				for (type in enumCase.params)
					if (IrTypeTools.containsNullable(type))
						return true;
		for (field in program.staticFields)
			if (IrTypeTools.containsNullable(field.type))
				return true;
		return false;
	}

	public static function functionMentionsNullable(fn:IrFunction):Bool {
		if (IrTypeTools.containsNullable(fn.result))
			return true;
		for (argument in fn.arguments)
			if (IrTypeTools.containsNullable(argument.type))
				return true;
		var found = false;
		for (block in fn.blocks)
			for (located in block.instructions) {
				switch located.value {
					case TypeValue(_, type):
						if (IrTypeTools.containsNullable(type))
							found = true;
					default:
				}
				var output = IrOperands.output(located.value);
				if (output != null && IrTypeTools.containsNullable(output.type))
					found = true;
				for (input in IrOperands.inputs(located.value))
					if (IrTypeTools.containsNullable(input.type))
						found = true;
				if (found)
					return true;
			}
		return found;
	}

	public static function eraseFunction(fn:IrFunction):IrFunction {
		if (!functionMentionsNullable(fn))
			return fn;
		var values:Map<Int, IrValue> = [];
		function use(value:IrValue):IrValue {
			var known = values.get(value.id);
			if (known != null)
				return known;
			var replacement = IrTypeTools.containsNullable(value.type) ? new IrValue(value.id, value.name, IrTypeTools.erase(value.type)) : value;
			values.set(value.id, replacement);
			return replacement;
		}
		var arguments = [for (argument in fn.arguments) use(argument)];
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = IrInliner.remap(located.value, use, id -> id);
				switch instruction {
					case TypeValue(output, type) if (IrTypeTools.containsNullable(type)):
						instruction = TypeValue(output, IrTypeTools.erase(type));
					default:
				}
				copy.instructions.push(new Located(instruction, located.provenance));
			}
			var terminator = block.terminator;
			if (terminator != null)
				copy.terminator = new Located(switch terminator.value {
					case Return(value): Return(use(value));
					case Throw(value): Throw(use(value));
					case Rethrow(value): Rethrow(use(value));
					case Jump(target): Jump(target);
					case Branch(condition, whenTrue, whenFalse): Branch(use(condition), whenTrue, whenFalse);
				}, terminator.provenance);
			blocks.push(copy);
		}
		var bindings:Array<IrDebugBinding> = [
			for (binding in fn.debugBindings)
				{
					identity: binding.identity,
					name: binding.name,
					value: use(binding.value),
					path: binding.path,
					scopeStart: binding.scopeStart,
					scopeEnd: binding.scopeEnd
				}
		];
		return new IrFunction(fn.name, arguments, IrTypeTools.erase(fn.result), blocks, bindings, fn.inlineHint, fn.retention);
	}

	static function eraseNative(native:IrNative):IrNative
		return {
			name: native.name,
			library: native.library,
			symbol: native.symbol,
			arguments: [for (argument in native.arguments) IrTypeTools.erase(argument)],
			result: IrTypeTools.erase(native.result),
			generatedFunctionDependencies: native.generatedFunctionDependencies
		};

	static function eraseCNative(native:IrCNative):IrCNative
		return {
			name: native.name,
			library: native.library,
			symbol: native.symbol,
			signature: native.signature,
			pointerOwnership: native.pointerOwnership,
			pointerRelease: native.pointerRelease,
			pointerLength: native.pointerLength,
			pointerNullable: native.pointerNullable,
			pointerSize: native.pointerSize,
			fixedResult: native.fixedResult,
			arguments: [for (argument in native.arguments) IrTypeTools.erase(argument)],
			argumentModes: native.argumentModes,
			result: IrTypeTools.erase(native.result)
		};
}

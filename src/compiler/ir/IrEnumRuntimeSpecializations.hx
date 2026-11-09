package compiler.ir;

import compiler.ir.Ir;
import compiler.types.typing.EnumRuntimeType;

/** Select concrete runtime descriptors from current and cached IR, never from an erased template. */
class IrEnumRuntimeSpecializations {
	public static function materialize(enums:Array<IrEnum>, functions:Array<IrFunction>, objects:Array<IrObject>,
			staticFields:Array<IrStaticField>, natives:Array<IrNative>, interfaces:Array<IrInterface>, cNatives:Array<IrCNative>):Array<IrEnum> {
		var declarations:Map<String, IrEnum> = [for (item in enums) item.name => item], required:Map<String, Bool> = [], pending:Array<String> = [];
		function visit(type:IrType):Void switch type {
			case Enum(name), EnumTag(name):
				var base = EnumRuntimeType.declaration(name);
				if (base != name && !required.exists(name)) { required.set(name, true); pending.push(name); }
			case Array(element), Iterator(element), Nullable(element): visit(element);
			case Function(arguments, result): for (argument in arguments) visit(argument); visit(result);
			default:
		}
		for (fn in functions) {
			for (argument in fn.arguments) visit(argument.type);
			visit(fn.result);
			for (block in fn.blocks) for (located in block.instructions) {
				var instruction = located.value, output = IrOperands.output(instruction);
				if (output != null) visit(output.type);
				for (input in IrOperands.inputs(instruction)) visit(input.type);
				switch instruction { case TypeValue(_, type): visit(type); default: }
			}
		}
		for (declaration in enums) if (EnumRuntimeType.declaration(declaration.name) == declaration.name)
			for (constructor in declaration.cases) for (parameter in constructor.params) visit(parameter);
		for (object in objects) for (field in object.fields) visit(field.type);
		for (contract in interfaces) for (method in contract.methods) { for (argument in method.arguments) visit(argument); visit(method.result); }
		for (field in staticFields) visit(field.type);
		for (native in natives) { for (argument in native.arguments) visit(argument); visit(native.result); }
		for (native in cNatives) { for (argument in native.arguments) visit(argument); visit(native.result); }
		var index = 0;
		while (index < pending.length) {
			var name = pending[index++], declaration = declarations.get(name);
			if (declaration == null) throw 'Missing concrete enum declaration "$name"';
			for (constructor in declaration.cases) for (parameter in constructor.params) visit(parameter);
		}
		return [for (declaration in enums) if (EnumRuntimeType.declaration(declaration.name) == declaration.name
			|| required.exists(declaration.name)) declaration];
	}
}

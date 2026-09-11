package compiler.ir;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrValue;
import compiler.ir.IrFunction;

/** Reference executor for the semantic SSA IR, independent of any target ABI. */
class IrInterpreter {
	final program:IrProgram;
	final functions:Map<String, IrFunction> = [];
	final globals:Map<String, Dynamic> = [];
	var steps:Int;
	var maxSteps:Int;

	public function new(program:IrProgram, ?maxSteps:Int = 1000000) {
		this.program = program;
		this.maxSteps = maxSteps;
		for (fn in program.functions)
			functions.set(fn.name, fn);
		for (field in program.staticFields)
			globals.set(field.name, null);
	}

	public function run(?functionName:String, ?arguments:Array<Dynamic>):Dynamic {
		var name = functionName == null ? program.entryPoint : functionName;
		if (!functions.exists(name))
			throw 'IR interpreter cannot find function "$name"';
		steps = 0;
		return execute(functions.get(name), arguments == null ? [] : arguments);
	}

	function execute(fn:IrFunction, arguments:Array<Dynamic>):Dynamic {
		if (arguments.length != fn.arguments.length)
			throw 'IR interpreter call to ${fn.name} expected ${fn.arguments.length} arguments, got ${arguments.length}';
		var blocks:Map<Int, IrBlock> = [], values:Map<Int, Dynamic> = [];
		for (block in fn.blocks)
			blocks.set(block.id, block);
		for (index in 0...fn.arguments.length)
			values.set(fn.arguments[index].id, arguments[index]);
		var current = fn.blocks[0].id,
			predecessor:Null<Int> = null,
			activeCatch:Null<Int> = null,
			thrown:Dynamic = null;
		while (true) {
			if (++steps > maxSteps)
				throw 'IR interpreter exceeded the ${maxSteps} step limit in ${fn.name}';
			var block = blocks.get(current);
			if (block == null)
				throw 'IR interpreter reached unknown block $current in ${fn.name}';
			try {
				for (located in block.instructions)
					switch located.value {
						case Phi(output, inputs):
							if (predecessor == null)
								throw 'IR interpreter reached phi ${output.id} without a predecessor';
							var found = false;
							for (input in inputs)
								if (input.block == predecessor) {
									values.set(output.id, value(values, input.value));
									found = true;
									break;
								}
							if (!found)
								throw 'IR interpreter has no phi input from block $predecessor';
						case BeginTry(catchBlock, _):
							activeCatch = catchBlock;
						case EndTry(_):
							activeCatch = null;
						case Catch(output):
							values.set(output.id, thrown);
							thrown = null;
						default:
							var output = outputOf(located.value),
								result = executeInstruction(located.value, values);
							if (output != null)
								values.set(output.id, result);
					}
				if (block.terminator == null)
					throw 'IR interpreter reached unterminated block $current';
				switch block.terminator.value {
					case Return(result):
						return value(values, result);
					case Throw(result), Rethrow(result):
						throw value(values, result);
					case Jump(target):
						predecessor = current;
						current = target;
					case Branch(condition, yes, no):
						predecessor = current;
						current = value(values, condition) ? yes : no;
				}
			} catch (failure:Dynamic) {
				if (activeCatch == null)
					throw failure;
				thrown = failure;
				predecessor = current;
				current = activeCatch;
				activeCatch = null;
			}
		}
	}

	function executeInstruction(instruction:IrInstruction, values:Map<Int, Dynamic>):Dynamic {
		return switch instruction {
			case ConstVoid(_): null;
			case ConstInt(_, value): value;
			case ConstFloat(_, value): value;
			case ConstString(_, value): value;
			case ConstBool(_, value): value;
			case ConstNull(_): null;
			case TypeValue(_, type): new InterpTypeRef(type);
			case ToDyn(_, input), SafeCast(_, input): value(values, input);
			case Add(_, left, right): value(values, left) + value(values, right);
			case Sub(_, left, right): value(values, left) - value(values, right);
			case Mul(_, left, right): value(values, left) * value(values, right);
			case Div(_, left, right): value(values, left) / value(values, right);
			case Mod(_, left, right): Std.int(value(values, left)) % Std.int(value(values, right));
			case BitAnd(_, left, right): Std.int(value(values, left)) & Std.int(value(values, right));
			case BitXor(_, left, right): Std.int(value(values, left)) ^ Std.int(value(values, right));
			case BitOr(_, left, right): Std.int(value(values, left)) | Std.int(value(values, right));
			case ShiftLeft(_, left, right): Std.int(value(values, left)) << Std.int(value(values, right));
			case ShiftRight(_, left, right): Std.int(value(values, left)) >> Std.int(value(values, right));
			case UnsignedShiftRight(_, left, right): Std.int(value(values, left)) >>> Std.int(value(values, right));
			case Less(_, left, right): value(values, left) < value(values, right);
			case LessEqual(_, left, right): value(values, left) <= value(values, right);
			case Equal(_, left, right): value(values, left) == value(values, right);
			case IntToFloat(_, input): value(values, input);
			case GlobalGet(_, name): globals.get(name);
			case GlobalSet(name, input):
				globals.set(name, value(values, input));
				null;
			case NewObject(_, typeName): newObject(typeName);
			case FieldGet(_, object, fieldName): objectField(value(values, object), fieldName);
			case FieldSet(object, fieldName, input):
				setObjectField(value(values, object), fieldName, value(values, input));
				null;
			case ArrayGet(_, array, index): arrayGet(value(values, array), Std.int(value(values, index)));
			case ArraySet(array, index, input):
				arraySet(value(values, array), Std.int(value(values, index)), value(values, input));
				null;
			case ArraySize(_, array): interpArray(value(values, array)).values.length;
			case Call(_, name, arguments):
				var args = [for (argument in arguments) value(values, argument)];
				functions.exists(name) ? execute(functions.get(name), args) : executeNative(name, args);
			case StaticClosure(_, name): new InterpClosure(functions.get(name), null);
			case InstanceClosure(_, name, receiver): new InterpClosure(functions.get(name), value(values, receiver));
			case CallClosure(_, closure, arguments):
				var callable:InterpClosure = cast value(values, closure),
					args = [for (argument in arguments) value(values, argument)];
				if (callable.receiver != null)
					args.unshift(callable.receiver);
				execute(callable.target, args);
			case MethodCall(_, object, methodName, arguments):
				var receiver = value(values, object),
					functionName = methodFunction(interpObject(receiver).type, methodName),
					args = [receiver];
				for (argument in arguments)
					args.push(value(values, argument));
				execute(functions.get(functionName), args);
			case ToVirtual(_, input): value(values, input);
			case MakeEnum(_, typeName, constructor, arguments):
				new InterpEnum(typeName, constructor, [for (argument in arguments) value(values, argument)]);
			case EnumIndex(_, input): cast(value(values, input), InterpEnum).constructor;
			case EnumField(_, input, _, field): cast(value(values, input), InterpEnum).fields[field];
			default: throw 'IR interpreter does not yet execute ${Std.string(instruction)}';
		};
	}

	function executeNative(name:String, arguments:Array<Dynamic>):Dynamic {
		return switch name {
			case "__exit": null;
			case "__array_alloc_i32", "__array_alloc_bool", "__array_alloc_f64", "__array_alloc_bytes", "__array_alloc_ref":
				new InterpArray([for (_ in 0...Std.int(arguments[0])) null], Std.int(arguments[0]) + 8);
			case "__array_copy_i32", "__array_copy_bool", "__array_copy_f64", "__array_copy_bytes", "__array_copy_ref":
				var source = interpArray(arguments[0]);
				new InterpArray(source.values.copy(), source.capacity);
			case "__array_concat_i32", "__array_concat_bool", "__array_concat_f64", "__array_concat_bytes", "__array_concat_ref":
				var left = interpArray(arguments[0]),
					right = interpArray(arguments[1]);
				new InterpArray(left.values.concat(right.values), left.values.length + right.values.length + 8);
			case "__array_push_i32", "__array_push_bool", "__array_push_f64", "__array_push_bytes", "__array_push_ref":
				var pushed = interpArray(arguments[0]);
				pushed.values.push(arguments[1]);
				pushed.capacity = pushed.values.length + 8;
				pushed.values.length;
			case "__array_pop_i32", "__array_pop_bool", "__array_pop_f64", "__array_pop_bytes", "__array_pop_ref":
				var popped = interpArray(arguments[0]);
				popped.values.length == 0 ? null : popped.values.pop();
			case "__string_length": Std.string(arguments[0]).length;
			case "__string_concat": Std.string(arguments[0]) + Std.string(arguments[1]);
			case "__string_equal": Std.string(arguments[0]) == Std.string(arguments[1]);
			case "__string_char_code_at": Std.string(arguments[0]).charCodeAt(Std.int(arguments[1]));
			case "__std_int_f64": Std.int(arguments[0]);
			case "__std_string": Std.string(arguments[0]);
			case "__dynamic_equal": arguments[0] == arguments[1];
			default: throw 'IR interpreter cannot execute native "$name"';
		};
	}

	function newObject(typeName:String):InterpObject {
		var object = new InterpObject(typeName),
			declaration = objectDeclaration(typeName);
		initializeObjectFields(object, declaration);
		return object;
	}

	function initializeObjectFields(object:InterpObject, declaration:Null<compiler.ir.Ir.IrObject>):Void {
		if (declaration == null)
			return;
		if (declaration.base != null)
			initializeObjectFields(object, objectDeclaration(declaration.base));
		for (field in declaration.fields)
			object.fields.set(field.name, defaultValue(field.type));
	}

	function objectDeclaration(typeName:String):Null<compiler.ir.Ir.IrObject> {
		for (object in program.objects)
			if (object.name == typeName)
				return object;
		return null;
	}

	function objectField(object:Dynamic, name:String):Dynamic {
		var value:InterpObject = cast object;
		if (value == null)
			throw "IR interpreter field access on null";
		if (value.fields.exists(name))
			return value.fields.get(name);
		throw 'IR interpreter unknown field "$name"';
	}

	function setObjectField(object:Dynamic, name:String, input:Dynamic):Void {
		var value:InterpObject = cast object;
		if (value == null)
			throw "IR interpreter field write on null";
		value.fields.set(name, input);
	}

	function arrayGet(array:Dynamic, index:Int):Dynamic {
		var value = interpArray(array);
		if (index < 0 || index >= value.values.length)
			throw 'IR interpreter array index $index is out of bounds';
		return value.values[index];
	}

	function arraySet(array:Dynamic, index:Int, input:Dynamic):Void {
		var value = interpArray(array);
		if (index < 0 || index >= value.values.length)
			throw 'IR interpreter array index $index is out of bounds';
		value.values[index] = input;
	}

	function interpArray(value:Dynamic):InterpArray {
		var array:InterpArray = cast value;
		if (array == null)
			throw "IR interpreter array access on null";
		return array;
	}

	function interpObject(value:Dynamic):InterpObject {
		var object:InterpObject = cast value;
		if (object == null)
			throw "IR interpreter object access on null";
		return object;
	}

	function methodFunction(typeName:String, name:String):String {
		var declaration = objectDeclaration(typeName);
		if (declaration != null) {
			for (method in declaration.methods)
				if (method.name == name)
					return method.functionName;
			if (declaration.base != null)
				return methodFunction(declaration.base, name);
		}
		throw 'IR interpreter unknown method "$typeName.$name"';
	}

	static function defaultValue(type:compiler.ir.Ir.IrType):Dynamic
		return switch type {
			case I32, Bool: 0;
			case F64: 0.0;
			default: null;
		};

	static function value(values:Map<Int, Dynamic>, value:IrValue):Dynamic {
		if (!values.exists(value.id))
			throw 'IR interpreter read of undefined value ${value.id}';
		return values.get(value.id);
	}

	static function outputOf(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Phi(output, _), ConstVoid(output), ConstInt(output, _), ConstFloat(output, _), ConstString(output, _), ConstBool(output, _),
				ConstNull(output), TypeValue(output, _), ToDyn(output, _), IntToFloat(output, _), SafeCast(output, _), Catch(output), GlobalGet(output, _),
				Add(output, _, _), Sub(output, _, _), Mul(output, _, _), Div(output, _, _), Mod(output, _, _), BitAnd(output, _, _), BitXor(output, _, _),
				BitOr(output, _, _), ShiftLeft(output, _, _), ShiftRight(output, _, _), UnsignedShiftRight(output, _, _), Less(output, _, _),
				LessEqual(output, _, _), Equal(output, _, _), Call(output, _, _), StaticClosure(output, _), InstanceClosure(output, _, _),
				CallClosure(output, _, _), ToVirtual(output, _), MethodCall(output, _, _, _), NewObject(output, _), FieldGet(output, _, _),
				ArrayGet(output, _, _), ArraySize(output, _), MakeEnum(output, _, _, _), EnumIndex(output, _), EnumField(output, _, _, _): output;
			case BeginTry(_, _), EndTry(_), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _): null;
		};
}

private class InterpObject {
	public final type:String;
	public final fields:Map<String, Dynamic> = [];

	public function new(type:String)
		this.type = type;
}

private class InterpArray {
	public final values:Array<Dynamic>;
	public var capacity:Int;

	public function new(values:Array<Dynamic>, ?capacity:Int) {
		this.values = values;
		this.capacity = capacity == null ? values.length : capacity;
	}
}

private class InterpEnum {
	public final type:String;
	public final constructor:Int;
	public final fields:Array<Dynamic>;

	public function new(type:String, constructor:Int, fields:Array<Dynamic>) {
		this.type = type;
		this.constructor = constructor;
		this.fields = fields;
	}
}

private class InterpTypeRef {
	public final type:compiler.ir.Ir.IrType;

	public function new(type:compiler.ir.Ir.IrType)
		this.type = type;
}

private class InterpClosure {
	public final target:IrFunction;
	public final receiver:Dynamic;

	public function new(target:IrFunction, receiver:Dynamic) {
		this.target = target;
		this.receiver = receiver;
	}
}

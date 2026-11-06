package compiler.ir;

import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrType;
import compiler.ir.IrFunction;

/** Reference executor for the semantic SSA IR, independent of any target ABI. */
class IrInterpreter {
	final program:IrProgram;
	final functions:Map<String, IrFunction> = [];
	final globals:Map<String, Dynamic> = [];
	var steps:Int;
	var maxSteps:Int;
	var reactiveHashState:Int = 0x6d2b79f5;
	final reactiveHashes:haxe.ds.ObjectMap<InterpObject, Int> = new haxe.ds.ObjectMap();

	public function new(program:IrProgram, ?maxSteps:Int = 1000000) {
		this.program = program;
		this.maxSteps = maxSteps;
		for (fn in program.functions)
			functions.set(fn.name, fn);
		for (field in program.staticFields)
			globals.set(field.name, defaultValue(field.type));
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
						case BeginTry(catchBlock, _, _):
							activeCatch = catchBlock;
						case EndTry(_, _):
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
			case ConstInt(output, value): output.type == I64 ? haxe.Int64.ofInt(value) : (value:Dynamic);
			case ConstFloat(_, value): value;
			case ConstString(_, value): value;
			case StaticDataAddress(_, _): throw "IR interpreter cannot execute target static data addresses";
			case PointerOffset(_, _, _), MemoryLoad(_, _, _, _), MemoryStore(_, _, _):
				throw "IR interpreter cannot execute unmanaged native memory operations";
			case ConstBool(_, value): value;
			case ConstNull(_): null;
			case TypeValue(_, type): new InterpTypeRef(type);
			case ToDyn(_, input): value(values, input);
			case IntToInt64(_, input): haxe.Int64.ofInt(value(values, input));
			case SafeCast(output, input):
				var actual:Dynamic = value(values, input);
				switch output.type {
					case Function(_, _) if (actual != null):
						actual = closureView(actual, output.type);
					case Array(element) if (actual != null):
						checkArrayCast(actual, element);
					case Obj(target) if (actual != null && !objectIsOfType(actual, target)):
						throw 'Cannot cast to "$target"';
					case TypeRef if (actual != null && !Std.isOfType(actual, InterpTypeRef)):
						throw "Cannot cast to a type handle";
					case I32 if (input.type == Dyn && actual != null):
						if (!numericValue(actual)) throw "Cannot cast to Int";
						actual = Std.int(actual);
					default:
				}
				actual;
			case Add(output, left, right), Sub(output, left, right), Mul(output, left, right), Div(output, left, right),
				Mod(output, left, right), BitAnd(output, left, right), BitXor(output, left, right), BitOr(output, left, right) if (output.type == I64):
				var a:haxe.Int64 = cast value(values, left), b:haxe.Int64 = cast value(values, right);
				switch instruction {
					case Add(_, _, _): a + b;
					case Sub(_, _, _): a - b;
					case Mul(_, _, _): a * b;
					case Div(_, _, _): a / b;
					case Mod(_, _, _): a % b;
					case BitAnd(_, _, _): a & b;
					case BitXor(_, _, _): a ^ b;
					case BitOr(_, _, _): a | b;
					default: throw "Invalid Int64 binary operation";
				}
			case ShiftLeft(output, left, right), ShiftRight(output, left, right), UnsignedShiftRight(output, left, right) if (output.type == I64):
				var a:haxe.Int64 = cast value(values, left), shift:Int = value(values, right);
				switch instruction {
					case ShiftLeft(_, _, _): a << shift;
					case ShiftRight(_, _, _): a >> shift;
					case UnsignedShiftRight(_, _, _): a >>> shift;
					default: throw "Invalid Int64 shift operation";
				}
			case Less(_, left, right) if (left.type == I64): haxe.Int64.compare(cast value(values, left), cast value(values, right)) < 0;
			case LessEqual(_, left, right) if (left.type == I64): haxe.Int64.compare(cast value(values, left), cast value(values, right)) <= 0;
			case Equal(_, left, right) if (left.type == I64 && right.type == I64):
				haxe.Int64.compare(cast value(values, left), cast value(values, right)) == 0;
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
			case Equal(_, left, right):
				switch [left.type, right.type] {
					case [F32 | F64, F32 | F64]:
						var leftFloat:Float = value(values, left), rightFloat:Float = value(values, right);
						leftFloat == rightFloat;
					default: value(values, left) == value(values, right);
				}
			case IntToFloat(_, input): value(values, input);
			case FloatToInt(_, input): Std.int(value(values, input));
			case FloatToFloat(output, input):
				var floatValue:Float = value(values, input);
				output.type == F32 ? haxe.io.FPHelper.i32ToFloat(haxe.io.FPHelper.floatToI32(floatValue)) : floatValue;
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
				var initial = switch array.type {
					case Array(element): defaultValue(element);
					default: null;
				};
				arraySet(value(values, array), Std.int(value(values, index)), value(values, input), initial);
				null;
			case ArraySize(_, array): interpArray(value(values, array)).values.length;
			case IteratorNew(_, array): new InterpIterator(interpArray(value(values, array)));
			case IteratorHasNext(_, iterator):
				var cursor = interpIterator(value(values, iterator));
				cursor.position < cursor.values.values.length;
			case IteratorNext(_, iterator):
				var cursor = interpIterator(value(values, iterator));
				if (cursor.position >= cursor.values.values.length)
					throw "Iterator has no next value";
				cursor.values.values[cursor.position++];
			case Call(_, name, arguments) if (name == IrHlScalarRef.ADDRESS):
				new InterpScalarRef(values, arguments[0].id);
			case Call(_, name, arguments) if (name == IrHlScalarRef.LOAD):
				var reference:InterpScalarRef = cast value(values, arguments[0]);
				reference.values.get(reference.id);
			case Call(_, name, arguments) if (name == IrHlScalarRef.STORE):
				var reference:InterpScalarRef = cast value(values, arguments[0]);
				reference.values.set(reference.id, value(values, arguments[1]));
				null;
			case Call(_, name, arguments) if (name == IrReferenceIdentity.NAME):
				value(values,arguments[0]) == value(values,arguments[1]);
			case Call(_, name, arguments) if (name == IrReceiverCheck.NAME):
				if (value(values, arguments[0]) == null) throw "Null access";
				null;
			case Call(_, name, arguments) if (name == IrValueLaneReference.PACK || name == IrValueLaneReference.UNPACK):
				value(values, arguments[0]);
			case Call(output, name, arguments):
				var args = [for (argument in arguments) value(values, argument)];
				if (functions.exists(name)) execute(functions.get(name), args);
				else {
					var result = executeNative(name, args);
					if (StringTools.startsWith(name, "__array_alloc_") && name != "__array_alloc_typed_ref" && Std.isOfType(result, InterpArray))
						switch output.type {
							case Array(element):
								var array:InterpArray = cast result;
								array.elementType = element;
								for (index in 0...array.values.length) array.values[index] = defaultValue(element);
							default:
						}
					if (arguments.length > 0 && (StringTools.startsWith(name, "__array_copy_")
							|| StringTools.startsWith(name, "__array_slice_") || StringTools.startsWith(name, "__array_concat_")))
						switch arguments[0].type {
							case Array(element): copyArrayRangeValues(interpArray(result), element);
							default:
						}
					result;
				}
			case CNativeCall(_, name, _):
				throw 'IR interpreter cannot execute ordinary C native "$name" without a host binding';
			case StaticClosure(out, name): new InterpClosure(functions.get(name), null, out.type, null, functions.exists(name) ? null : name);
			case InstanceClosure(out, name, receiver): new InterpClosure(functions.get(name), value(values, receiver), out.type);
			case CallClosure(_, closure, arguments):
				var callable:InterpClosure = cast value(values, closure),
					args = [for (argument in arguments) value(values, argument)];
				invokeClosure(callable, args);
			case MethodCall(_, object, methodName, arguments, _):
				var receiver = value(values, object),
					functionName = methodFunction(interpObject(receiver).type, methodName),
					target = functions.get(functionName), args = [receiver];
				for (index in 0...arguments.length) {
					var argument = arguments[index], item = value(values, argument);
					// The interpreter has no non-null native pointer values; a Dynamic value cannot
					// satisfy a pointer parameter merely because its host representation is an Int.
					if (item != null && Type.enumEq(argument.type, Dyn) && Type.enumEq(target.arguments[index + 1].type, RawPtr))
						throw "Invalid cast to hl.Bytes";
					args.push(item);
				}
				execute(target, args);
			case ToVirtual(_, input), Upcast(_, input): value(values, input);
			case MakeEnum(_, typeName, constructor, arguments):
				new InterpEnum(typeName, constructor, [for (argument in arguments) value(values, argument)]);
			case EnumIndex(_, input): cast(value(values, input), InterpEnum).constructor;
			case EnumField(_, input, _, field): cast(value(values, input), InterpEnum).fields[field];
			default: throw 'IR interpreter does not yet execute ${Std.string(instruction)}';
		};
	}

	function executeNative(name:String, arguments:Array<Dynamic>):Dynamic {
		if (StringTools.startsWith(name, "$scalar-closure:receiver:") || StringTools.startsWith(name, "$wasm:closure-receiver:")) {
			var value = arguments[0], probe = arguments[1];
			if (!Std.isOfType(value, InterpClosure) || !Std.isOfType(probe, InterpClosure)) return null;
			var closure:InterpClosure = cast value, expected:InterpClosure = cast probe;
			return closure.target == expected.target && closure.nativeName == expected.nativeName ? closure.receiver : null;
		}

		return switch name {
			case "__exit": null;
			case "__dynamic_object_type_id":
				Std.isOfType(arguments[0], InterpObject) ? IrTypeIdentity.id(Obj(cast(arguments[0], InterpObject).type)) : 0;
			case "__std_is_exact_type":
				var reference:InterpTypeRef = cast arguments[1], input:Dynamic = arguments[0];
				switch reference.type {
					case Obj(target): Std.isOfType(input, InterpObject) && cast(input, InterpObject).type == target;
					case Enum(target): Std.isOfType(input, InterpEnum) && cast(input, InterpEnum).type == target;
					default: false;
				};
			case "__std_is_of_type":
				var reference:InterpTypeRef = cast arguments[1], input = arguments[0];
				switch reference.type {
					case Obj(target): objectIsOfType(input, target);
					case Enum(target): Std.isOfType(input, InterpEnum) && cast(input, InterpEnum).type == target;
					case Virtual(target): objectImplements(input, target);
					case I32: switch Type.typeof(input) { case TInt: true; default: false; };
					case F64: switch Type.typeof(input) { case TFloat: true; default: false; };
					case Bool: switch Type.typeof(input) { case TBool: true; default: false; };
					case I64: haxe.Int64.isInt64(input);
					case TypeRef: Std.isOfType(input, InterpTypeRef);
					case Bytes: Std.isOfType(input, String);
					case ManagedBytes: Std.isOfType(input, haxe.io.Bytes);
					case Array(_): Std.isOfType(input, InterpArray);
					case Iterator(element): Std.isOfType(input, InterpIterator)
						&& IrVerifier.sameType(cast(input, InterpIterator).values.elementType, element);
					default: false;
				};
			case "__closure_is_of_type":
				Std.isOfType(arguments[0], InterpClosure) && IrVerifier.sameType(cast(arguments[0], InterpClosure).type, cast(arguments[1], InterpTypeRef).type);
			case "__array_alloc_typed_ref":
				new InterpArray([for (_ in 0...Std.int(arguments[0])) null], Std.int(arguments[0]) + 8, cast(arguments[1], InterpTypeRef).type);
			case "__array_check_cast":
				checkArrayCast(arguments[0], cast(arguments[1], InterpTypeRef).type);
			case "__array_alloc_i32", "__array_alloc_i64", "__array_alloc_bool", "__array_alloc_f64", "__array_alloc_bytes", "__array_alloc_ref":
				new InterpArray([for (_ in 0...Std.int(arguments[0])) null], Std.int(arguments[0]) + 8);
			case "__array_copy_i32", "__array_copy_i64", "__array_copy_bool", "__array_copy_f64", "__array_copy_bytes", "__array_copy_ref", "__array_copy_any":
				var source = interpArray(arguments[0]);
				new InterpArray(source.values.copy(), source.capacity, source.elementType);
			case "__array_slice_i32", "__array_slice_i64", "__array_slice_bool", "__array_slice_f64", "__array_slice_bytes", "__array_slice_ref", "__array_slice_any":
				var source = interpArray(arguments[0]), sliced = source.values.slice(Std.int(arguments[1]), Std.int(arguments[2]));
				new InterpArray(sliced, sliced.length + 8, source.elementType);
			case "__array_concat_i32", "__array_concat_i64", "__array_concat_bool", "__array_concat_f64", "__array_concat_bytes", "__array_concat_ref", "__array_concat_any":
				var left = interpArray(arguments[0]),
					right = interpArray(arguments[1]);
				new InterpArray(left.values.concat(right.values), left.values.length + right.values.length + 8, left.elementType);
			case "__array_push_i32", "__array_push_i64", "__array_push_bool", "__array_push_f64", "__array_push_bytes", "__array_push_ref":
				var pushed = interpArray(arguments[0]);
				pushed.values.push(arguments[1]);
				pushed.capacity = pushed.values.length + 8;
				pushed.values.length;
			case "__array_pop_i32", "__array_pop_i64", "__array_pop_bool", "__array_pop_f64", "__array_pop_bytes", "__array_pop_ref":
				var popped = interpArray(arguments[0]);
				popped.values.length == 0 ? null : popped.values.pop();
			case "__string_length": Std.string(arguments[0]).length;
			case "__string_concat": Std.string(arguments[0]) + Std.string(arguments[1]);
			case "__string_equal": arguments[0] == null || arguments[1] == null ? arguments[0] == arguments[1] : Std.string(arguments[0]) == Std.string(arguments[1]);
			case "__string_char_code_at": Std.string(arguments[0]).charCodeAt(Std.int(arguments[1]));
			case "__string_to_lower_case": Std.string(arguments[0]).toLowerCase();
			case "__string_to_upper_case": Std.string(arguments[0]).toUpperCase();
			case "__f32_to_i32_bits": haxe.io.FPHelper.floatToI32(arguments[0]);
			case "__i32_to_f32_bits": haxe.io.FPHelper.i32ToFloat(arguments[0]);
			case "runtime.FloatBits.toInt64", "__f64_to_i64_bits": haxe.io.FPHelper.doubleToI64(arguments[0]);
			case "runtime.FloatBits.fromInt64", "__i64_to_f64_bits":
				var bits:haxe.Int64 = cast arguments[0];
				haxe.io.FPHelper.i64ToDouble(bits.low, bits.high);
			case "haxe.Int64.make": haxe.Int64.make(arguments[0], arguments[1]);
			case "haxe.Int64.ofInt": haxe.Int64.ofInt(arguments[0]);
			case "haxe.Int64.ushr": haxe.Int64.ushr(cast arguments[0], Std.int(arguments[1]));
			case "haxe.Int64.xor": haxe.Int64.xor(cast arguments[0], cast arguments[1]);
			case "haxe.Int64.toInt":
				var bits:haxe.Int64 = cast arguments[0];
				haxe.Int64.toInt(haxe.Int64.shr(haxe.Int64.shl(bits, 32), 32));
			case "__std_int_f64": Std.int(arguments[0]);
			case "__std_int_dynamic": Std.int(arguments[0]);
			case "__math_ceil": Std.int(Math.ceil(arguments[0]));
			case "__math_floor": Std.int(Math.floor(arguments[0]));
			case "__std_string": Std.string(arguments[0]);
			case "__dynamic_equal": dynamicEqual(arguments[0], arguments[1]);
			case "__reactive_hash", "haxeon.reactive.ReactiveHash.reactiveHash":
				var source:InterpObject = cast arguments[0];
				if (reactiveHashes.exists(source)) reactiveHashes.get(source) else {
					var hash = reactiveHashState;
					hash ^= hash << 13;
					hash ^= hash >>> 17;
					hash ^= hash << 5;
					reactiveHashState = hash;
					reactiveHashes.set(source, hash);
					hash;
				}
			case "__reflect_is_object":
				arguments[0] != null
				&& !Std.isOfType(arguments[0], Bool)
				&& !Std.isOfType(arguments[0], Int)
				&& !Std.isOfType(arguments[0], Float)
				&& !Std.isOfType(arguments[0], String)
				&& !Reflect.isFunction(arguments[0]);
			default: throw 'IR interpreter cannot execute native "$name"';
		};
	}

	function dynamicEqual(left:Dynamic, right:Dynamic):Bool {
		if (haxe.Int64.isInt64(left) && haxe.Int64.isInt64(right))
			return haxe.Int64.compare(cast left, cast right) == 0;
		if (left == right)
			return true;
		if (Std.isOfType(left, InterpEnum) && Std.isOfType(right, InterpEnum)) {
			var leftEnum:InterpEnum = cast left,
				rightEnum:InterpEnum = cast right;
			if (leftEnum.type != rightEnum.type
				|| leftEnum.constructor != rightEnum.constructor
				|| leftEnum.fields.length != rightEnum.fields.length)
				return false;
			for (index in 0...leftEnum.fields.length)
				if (!dynamicEqual(leftEnum.fields[index], rightEnum.fields[index]))
					return false;
			return true;
		}
		return false;
	}

	function newObject(typeName:String):InterpObject {
		var object = new InterpObject(typeName),
			declaration = objectDeclaration(typeName);
		initializeObjectFields(object, declaration);
		return object;
	}

	/** Targetless IR stores values as interpreter objects, so range copies must copy those values. */
	function copyArrayRangeValues(array:InterpArray, element:IrType):Void {
		if (!isInlineValue(element)) return;
		for (index in 0...array.values.length) array.values[index] = copyInlineValue(array.values[index], element);
	}

	function isInlineValue(type:IrType):Bool return switch type {
		case Nullable(element): isInlineValue(element);
		case Obj(name):
			var declaration = objectDeclaration(name);
			declaration != null && declaration.isValue;
		default: false;
	};

	function copyInlineValue(input:Dynamic, type:IrType):Dynamic {
		if (input == null) return null;
		return switch type {
			case Nullable(element): copyInlineValue(input, element);
			case Obj(name):
				var declaration = objectDeclaration(name);
				if (declaration == null || !declaration.isValue) input;
				else {
					var original = interpObject(input), copy = newObject(name);
					for (field in declaration.fields) copy.fields.set(field.name, copyInlineValue(original.fields.get(field.name), field.type));
					copy;
				}
			default: input;
		};
	}

	function initializeObjectFields(object:InterpObject, declaration:Null<compiler.ir.Ir.IrObject>):Void {
		if (declaration == null)
			return;
		if (declaration.base != null)
			initializeObjectFields(object, objectDeclaration(declaration.base));
		for (field in declaration.fields)
			object.fields.set(field.name, switch field.type {
				case Obj(name):
					var nested = objectDeclaration(name);
					nested != null && nested.isValue ? newObject(name) : null;
				default: defaultValue(field.type);
			});
	}

	function objectDeclaration(typeName:String):Null<compiler.ir.Ir.IrObject> {
		for (object in program.objects)
			if (object.name == typeName)
				return object;
		return null;
	}

	function objectIsOfType(input:Dynamic, target:String):Bool {
		if (!Std.isOfType(input, InterpObject)) return false;
		var current = objectDeclaration(cast(input, InterpObject).type);
		while (current != null) {
			if (current.name == target) return true;
			current = current.base == null ? null : objectDeclaration(current.base);
		}
		return false;
	}

	function objectImplements(input:Dynamic, target:String):Bool {
		if (!Std.isOfType(input, InterpObject)) return false;
		function reaches(name:String, visited:Map<String, Bool>):Bool {
			if (name == target) return true;
			if (visited.exists(name)) return false;
			visited.set(name, true);
			for (entry in program.interfaces) if (entry.name == name)
				for (base in entry.bases) if (reaches(base, visited)) return true;
			return false;
		}
		var current = objectDeclaration(cast(input, InterpObject).type);
		while (current != null) {
			for (name in current.interfaces) if (reaches(name, [])) return true;
			current = current.base == null ? null : objectDeclaration(current.base);
		}
		return false;
	}

	static function numericValue(input:Dynamic):Bool
		return switch Type.typeof(input) { case TInt, TFloat: true; default: false; };

	function closureView(input:Dynamic, type:IrType):InterpClosure {
		if (!Std.isOfType(input, InterpClosure)) throw "Cannot cast to a function";
		var source:InterpClosure = cast input;
		if (IrVerifier.sameType(source.type, type)) return source;
		var sourceArity = switch source.type { case Function(args, _): args.length; default: -1; };
		var targetArity = switch type { case Function(args, _): args.length; default: -1; };
		if (sourceArity < 0 || sourceArity != targetArity) throw "Cannot cast function with a different arity";
		return new InterpClosure(source.target, source.receiver, type, source, source.nativeName);
	}

	function invokeClosure(closure:InterpClosure, args:Array<Dynamic>):Dynamic {
		if (closure.source == null) {
			if (closure.receiver != null) args.unshift(closure.receiver);
			if (closure.target == null) return executeNative(closure.nativeName, args);
			return execute(closure.target, args);
		}
		var source = closure.source;
		var sourceSignature = switch source.type { case Function(arguments, result): {arguments: arguments, result: result}; default: throw "Invalid function type"; };
		var targetSignature = switch closure.type { case Function(arguments, result): {arguments: arguments, result: result}; default: throw "Invalid function type"; };
		var converted = [for (index in 0...args.length) closureConvert(args[index], targetSignature.arguments[index], sourceSignature.arguments[index])];
		var result = invokeClosure(source, converted);
		return closureConvert(result, sourceSignature.result, targetSignature.result);
	}

	function closureConvert(input:Dynamic, from:IrType, to:IrType):Dynamic {
		if (IrVerifier.sameType(from, to)) return input;
		return switch [from, to] {
			case [_, Void]: null;
			case [Void, I32]: 0;
			case [Void, I64]: haxe.Int64.ofInt(0);
			case [Void, Bool]: false;
			case [Void, F32 | F64]: 0.0;
			case [Void, _]: null;
			case [I32, Bool]: input != 0;
			case [_, Dyn]: input;
			case [_, Array(element)]: checkArrayCast(input, element);
			case [_, Function(_, _)] if (input != null): closureView(input, to);
			case [_, I32] if (input != null && numericValue(input)): Std.int(input);
			case [_, F32] if (input != null && numericValue(input)): haxe.io.FPHelper.i32ToFloat(haxe.io.FPHelper.floatToI32(input));
			case [_, F64] if (input != null && numericValue(input)): (input:Float);
			case [_, _] if (matchesArrayElement(input, to)): input;
			default: throw 'Cannot convert closure value from ${Std.string(from)} to ${Std.string(to)}';
		};
	}

	function checkArrayCast(input:Dynamic, element:IrType):Dynamic {
		if (input == null) return null;
		if (!Std.isOfType(input, InterpArray)) throw "Cannot cast to Array";
		var array:InterpArray = cast input;
		if (Type.enumEq(element, Dyn) || IrVerifier.sameType(element, array.elementType)) return array;
		if (!Type.enumEq(array.elementType, Dyn)) throw "Array element type mismatch";
		for (item in array.values) if (!matchesArrayElement(item, element)) throw "Array element type mismatch";
		array.elementType = element;
		return array;
	}

	function matchesArrayElement(input:Dynamic, type:IrType):Bool {
		if (input == null) return switch type {
			case Nullable(_) | Bytes | Array(_) | Enum(_) | Virtual(_) | Function(_, _) | Dyn: true;
			case Obj(name): var object = objectDeclaration(name); object == null || !object.isValue;
			default: false;
		};
		return switch type {
			case Nullable(element): matchesArrayElement(input, element);
			case Dyn: true;
			case I32: switch Type.typeof(input) { case TInt: true; default: false; };
			case F64: switch Type.typeof(input) { case TFloat: true; default: false; };
			case Bool: switch Type.typeof(input) { case TBool: true; default: false; };
			case I64: haxe.Int64.isInt64(input);
			case Bytes: Std.isOfType(input, String);
			case ManagedBytes: Std.isOfType(input, haxe.io.Bytes);
			case Obj(name): objectIsOfType(input, name);
			case Virtual(name): objectImplements(input, name);
			case Enum(name): Std.isOfType(input, InterpEnum) && cast(input, InterpEnum).type == name;
			case Array(_): Std.isOfType(input, InterpArray);
			case Function(_, _): Std.isOfType(input, InterpClosure) && IrVerifier.sameType(cast(input, InterpClosure).type, type);
			default: false;
		};
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
		var declaration = objectDeclaration(value.type);
		while (declaration != null) {
			var found = false;
			for (field in declaration.fields) if (field.name == name) {
				found = true;
				var scalar = IrFieldStorage.scalar(field), narrowInteger = switch field.type {
					case I32: true;
					case Nullable(I32) if (input != null): scalar = field.nullableScalarStorage; true;
					default: false;
				};
				if (narrowInteger && scalar != null && scalar.size > 0 && scalar.size < 4) {
					var shift = 32 - scalar.size * 8, truncated = Std.int(input) << shift;
					input = scalar.signed ? truncated >> shift : truncated >>> shift;
				} else if (field.type == F32)
					input = haxe.io.FPHelper.i32ToFloat(haxe.io.FPHelper.floatToI32(input));
				break;
			}
			if (found || declaration.base == null) break;
			declaration = objectDeclaration(declaration.base);
		}
		value.fields.set(name, input);
	}

	function arrayGet(array:Dynamic, index:Int):Dynamic {
		var value = interpArray(array);
		if (index < 0 || index >= value.values.length)
			throw 'IR interpreter array index $index is out of bounds';
		return value.values[index];
	}

	function arraySet(array:Dynamic, index:Int, input:Dynamic, initial:Dynamic):Void {
		var value = interpArray(array);
		if (index < 0)
			throw 'IR interpreter array index $index is out of bounds';
		// Haxe array writes grow the array. Iterator comprehensions start with
		// an empty result because their final length is not known in advance.
		while (value.values.length <= index)
			value.values.push(initial);
		if (value.capacity < value.values.length)
			value.capacity = value.values.length + 8;
		value.values[index] = input;
	}

	function interpArray(value:Dynamic):InterpArray {
		var array:InterpArray = cast value;
		if (array == null)
			throw "IR interpreter array access on null";
		return array;
	}

	function interpIterator(value:Dynamic):InterpIterator {
		var iterator:InterpIterator = cast value;
		if (iterator == null)
			throw "IR interpreter iterator access on null";
		return iterator;
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
			case I32: 0;
			case I64: haxe.Int64.ofInt(0);
			case Bool: false;
			case F32, F64: 0.0;
			default: null;
		};

	static function value(values:Map<Int, Dynamic>, value:IrValue):Dynamic {
		if (!values.exists(value.id))
			throw 'IR interpreter read of undefined value ${value.id}';
		return values.get(value.id);
	}

	static function outputOf(instruction:IrInstruction):Null<IrValue>
		return switch instruction {
			case Phi(output, _), ConstVoid(output), ConstInt(output, _), ConstFloat(output, _), ConstString(output, _), StaticDataAddress(output, _),
				PointerOffset(output, _, _), MemoryLoad(output, _, _, _), ConstBool(output, _), ConstNull(output), TypeValue(output, _), ToDyn(output, _),
				IntToFloat(output, _), IntToInt64(output, _), FloatToInt(output, _), FloatToFloat(output, _), SafeCast(output, _), Catch(output),
				GlobalGet(output, _), Add(output, _, _), Sub(output, _, _), Mul(output, _, _), Div(output, _, _), Mod(output, _, _), BitAnd(output, _, _),
				BitXor(output, _, _), BitOr(output, _, _), ShiftLeft(output, _, _), ShiftRight(output, _, _), UnsignedShiftRight(output, _, _),
				Less(output, _, _), LessEqual(output, _, _), Equal(output, _, _), Call(output, _, _), CNativeCall(output, _, _), StaticClosure(output, _),
				InstanceClosure(output, _, _), CallClosure(output, _, _), ToVirtual(output, _), Upcast(output, _), MethodCall(output, _, _, _, _), NewObject(output, _),
				FieldGet(output, _, _), ArrayGet(output, _, _), ArraySize(output, _), IteratorNew(output, _), IteratorHasNext(output, _),
				IteratorNext(output, _), MakeEnum(output, _, _, _), EnumIndex(output, _), EnumField(output, _, _, _): output;
			case BeginTry(_, _, _), EndTry(_, _), GlobalSet(_, _), FieldSet(_, _, _), ArraySet(_, _, _), MemoryStore(_, _, _): null;
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
	public var elementType:IrType;

	public function new(values:Array<Dynamic>, ?capacity:Int, ?elementType:IrType) {
		this.values = values;
		this.capacity = capacity == null ? values.length : capacity;
		this.elementType = elementType == null ? Dyn : elementType;
	}
}

private class InterpIterator {
	public final values:InterpArray;
	public var position:Int = 0;

	public function new(values:InterpArray)
		this.values = values;
}

private class InterpScalarRef {
	public final values:Map<Int, Dynamic>;
	public final id:Int;
	public function new(values:Map<Int, Dynamic>, id:Int) { this.values = values; this.id = id; }
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
	public final target:Null<IrFunction>;
	public final receiver:Dynamic;
	public final type:IrType;
	public final source:Null<InterpClosure>;
	public final nativeName:Null<String>;

	public function new(target:Null<IrFunction>, receiver:Dynamic, type:IrType, ?source:InterpClosure, ?nativeName:String) {
		this.target = target;
		this.receiver = receiver;
		this.type = type;
		this.source = source;
		this.nativeName = nativeName;
	}
}

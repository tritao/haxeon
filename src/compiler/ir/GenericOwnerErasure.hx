package compiler.ir;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.Ir;
import compiler.semantic.GeneratedNames;

/** Operations through G<Dynamic> dispatch to the physical owner without changing object identity. */
class GenericOwnerErasure {
	static inline final TYPE_TEST_PREFIX = "$generic-type-test:";
	/** Whether `name` is an operation through an erased generic owner (`$generic-erased:Owner:get|set|call:member`). */
	public static inline function isOperation(name:String):Bool
		return GeneratedNames.isErasedOperation(name);

	/** The erased-generic call a bound method of an erased owner makes (see IrMethodReferences). */
	public static inline function erasedCallName(owner:String, member:String):String
		return GeneratedNames.erasedOperation(owner, "call", member);

	public static function typeTestName(owner:String, exact:Bool):String
		return TYPE_TEST_PREFIX + (exact ? "exact:" : "instance:") + owner;

	/** Generate only the operations that occur in typed code, before value-field lowering. */
	public static function generate(facts:ProgramFacts, functions:Array<IrFunction>, objects:Array<IrObject>):Void {
		generateTypeTests(facts, functions, objects);
		var requests:Map<String, {arguments:Array<IrType>, result:IrType}> = [];
		for (fn in functions) for (block in fn.blocks) for (instruction in block.instructions)
			switch instruction.value {
			case Call(output, name, arguments) if (GeneratedNames.isErasedOperation(name.name)):
				var signature = {arguments: [for (argument in arguments) argument.type], result: output.type},
					previous = requests.get(name.name);
				if (previous != null && (!Type.enumEq(previous.result, signature.result)
					|| !sameTypes(previous.arguments, signature.arguments)))
					throw new InternalError('Conflicting erased generic operation "$name"');
				requests.set(name.name, signature);
			default:
		}
		var byName = [for (object in objects) object.name => object],
			byFunction = new IrFunctionIndex("generic-owner-erasure", functions);
		var names = [for (name in requests.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var parts = GeneratedNames.erasedOperationPath(name).split(":"), signature = requests.get(name);
			if (parts.length != 3 || signature == null || signature.arguments.length == 0
				|| (switch (signature.arguments[0]) {
					case Dyn: false;
					default: true;
				}))
					throw new InternalError('Invalid erased generic operation "$name"');
			var owner = parts[0],
				operation = parts[1],
				member = parts[2],
				candidates =
					[for (object in objects) if (!object.isValue && derivesFrom(facts, object, owner, byName)) object];
			candidates.sort((a, b) -> depth(b, byName) - depth(a, byName));
			var builder = new IrBuilder(),
				receiver = builder.argument("receiver", Dyn),
				arguments = [for (index in 1...signature.arguments.length) builder.argument('argument$index',
					signature.arguments[index])];
			// The operation on one candidate class, its receiver already cast to it, emitted by `b` with its arguments `values`.
			function arm(b:IrBuilder, values:Array<IrValue>, field:Null<IrObjectField>, method:Null<IrFunction>,
					target:IrValue):Void
				switch operation {
					case "get" if (field != null):
						b.returnValue(convert(b, b.fieldGet(target, member, field.type), signature.result, byName));
					case "set" if (field != null && values.length == 1):
						b.fieldSet(target, member, convert(b, values[0], field.type, byName));
						b.returnValue(b.constVoid());
					case "call" if (method != null):
						if (method.arguments.length != values.length + 1)
							throw new InternalError('Incompatible erased method "$name"');
						var adapted = [
							for (index in 0...values.length)
								convert(b, values[index], method.arguments[index + 1].type, byName)
						],
							result = b.methodCall(target, member, adapted, method.result);
						b.returnValue((switch (signature.result) {
							case Void: true;
							default: false;
						}) ? result : convert(b, result, signature.result, byName));
					default:
						throw new InternalError('Invalid erased generic operation "$name"');
				}
			// First an exact-class arm per candidate, the owner's own layout first: a type compare and a cast that cannot fail
			// (IrExactTypeFacts). Then the checked arms, most derived first, for what no exact arm matched: an object reached
			// through a virtual, or a class the exact arms do not list.
			var exact = candidates.copy();
			exact.sort((a, b) -> (a.name == owner ? 0 : 1) - (b.name == owner ? 0 : 1));
			for (candidate in exact) {
				var field = operation == "call" ? null : findField(candidate, member, byName),
					method = operation == "call" ? findMethod(candidate, member, byName, byFunction) : null;
				if (field == null && method == null)
					continue;
				var matched = builder.createBlock(), next = builder.createBlock(), type:IrType = Obj(candidate.name);
				builder.branch(builder.call(IrExactTypeFacts.TEST, [receiver, builder.typeValue(type)], Bool), matched,
					next);
				builder.select(matched);
				arm(builder, arguments, field, method, builder.safeCast(receiver, type));
				builder.select(next);
			}
			for (candidate in candidates) {
				var field = operation == "call" ? null : findField(candidate, member, byName),
					method = operation == "call" ? findMethod(candidate, member, byName, byFunction) : null;
				if (field == null && method == null)
					continue;
				var matched = builder.createBlock(), next = builder.createBlock(), type:IrType = Obj(candidate.name);
				builder.branch(builder.call("__std_is_of_type", [receiver, builder.typeValue(type)], Bool), matched,
					next);
				builder.select(matched);
				arm(builder, arguments, field, method, builder.safeCast(receiver, type));
				builder.select(next);
			}
			builder.throwValue(builder.toDyn(builder.constString('Invalid receiver for $owner.$member')));
			// When the owner's own class has the member, the operation's name is a fast path the inliner places at each call
			// site: its own class's arm, else a call to the full accessor (the dispatch). An erased owner of a reference type
			// argument is almost always its own class, so a read is a type compare and a field load.
			var own = byName.get(owner),
				ownField = own == null || operation == "call" ? null : findField(own, member, byName),
				ownMethod = own == null || operation != "call" ? null : findMethod(own, member, byName, byFunction);
			if (own == null || own.isValue || (ownField == null && ownMethod == null)) {
				functions.push(new IrFunction(name, builder.arguments, signature.result, builder.blocks,
					Provider(TypeKey.of(Obj(owner)),
					ProviderOperations.detailed(ProviderOperation.GenericErased, operation + ":" + member))));
				continue;
			}
			var dispatch = GeneratedNames.erasedDispatch(owner, operation, member);
			functions.push(new IrFunction(dispatch, builder.arguments, signature.result, builder.blocks,
				Provider(TypeKey.of(Obj(owner)),
				ProviderOperations.detailed(ProviderOperation.GenericErased, operation + ":" + member + ":dispatch"))));
			var fast = new IrBuilder(),
				fastReceiver = fast.argument("receiver", Dyn),
				fastArguments = [
					for (index in 1...signature.arguments.length)
						fast.argument('argument$index', signature.arguments[index])
				],
				matched = fast.createBlock(),
				other = fast.createBlock(),
				ownType:IrType = Obj(owner);
			fast.branch(fast.call(IrExactTypeFacts.TEST, [fastReceiver, fast.typeValue(ownType)], Bool), matched,
				other);
			fast.select(matched);
			arm(fast, fastArguments, ownField, ownMethod, fast.safeCast(fastReceiver, ownType));
			fast.select(other);
			fast.returnValue(fast.call(dispatch, [fastReceiver].concat(fastArguments), signature.result));
			functions.push(new IrFunction(name, fast.arguments, signature.result, fast.blocks,
				Provider(TypeKey.of(Obj(owner)),
				ProviderOperations.detailed(ProviderOperation.GenericErased, operation + ":" + member)), null, true));
		}
	}

	/** Regenerate type tests from the current layouts, including layouts added by an incremental edit. */
	static function generateTypeTests(facts:ProgramFacts, functions:Array<IrFunction>, objects:Array<IrObject>):Void {
		var requests:Map<String, Bool> = [];
		for (fn in functions) for (block in fn.blocks) for (instruction in block.instructions)
			switch instruction.value {
			case Call(_, name, _) if (StringTools.startsWith(name.name, TYPE_TEST_PREFIX)): requests.set(name.name,
				true);
			default:
		}
		var names = [for (name in requests.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var parts = name.substr(TYPE_TEST_PREFIX.length).split(":"), exact = parts[0] == "exact";
			if (parts.length != 2
				|| (!exact && parts[0] != "instance")) throw new InternalError('Invalid generic type test "$name"');
			var owner = parts[1],
				candidates = [for (object in objects) if (facts.genericOwnerOrigin(object.name) == owner) object.name];
			candidates.sort(Reflect.compare);
			var builder = new IrBuilder(), value = builder.argument("value", Dyn), matched = builder.createBlock();
			for (candidate in candidates) {
				var next = builder.createBlock();
				builder.branch(builder.call(exact ? "__std_is_exact_type" : "__std_is_of_type", [
					value,
					builder.typeValue(Obj(candidate))
				], Bool), matched, next);
				builder.select(next);
			}
			builder.returnValue(builder.constBool(false));
			builder.select(matched);
			builder.returnValue(builder.constBool(true));
			functions.push(new IrFunction(name, builder.arguments, Bool, builder.blocks,
				Provider(TypeKey.of(Obj(owner)),
				ProviderOperations.detailed(ProviderOperation.GenericTypeTest, exact ? "exact" : "instance"))));
		}
	}

	public static function convert(builder:IrBuilder, value:IrValue, type:IrType,
			objects:Map<String, IrObject>):IrValue {
		if (Type.enumEq(value.type, type)) return value;
		if ((switch (type) {
			case Dyn: true;
			default: false;
		})) return builder.toDyn(value);
		// This boundary accepts a Dynamic value supplied through an erased owner. Check it
		// before the backend cast so failure is a catchable language exception on every target.
		if ((switch (value.type) {
			case Dyn: true;
			default: false;
		})) {
			var target = switch type {
				case Nullable(inner): inner;
				default: type;
			},
				checks:Array<IrType> = switch target {
				case Obj(_) | Virtual(_) | Enum(_) | Bytes | ManagedBytes | Abstract(_) | Iterator(_)
					| TypeRef: [target];
				case Array(_): [Array(Dyn)];
				case Function(_, _): [target];
				case I32 | F64 | Bool | I64 | RawPtr: [target];
				default: [];
			};
			if (checks.length > 0) {
				var nullable = switch type {
					case Nullable(_): true;
					case Obj(name): var declaration = objects.get(name);
						declaration == null || !declaration.isValue;
					case Virtual(_) | Enum(_) | Bytes | ManagedBytes | RawPtr | TypeRef | Abstract(_) | Iterator(_)
						| Array(_) | Function(_, _): true;
					default: false;
				}, accepted = builder.createBlock(), checkType = builder.createBlock(),
					rejected = builder.createBlock();
				builder.branch(builder.equal(value, builder.constNull(Dyn)), nullable ? accepted : rejected, checkType);
				builder.select(checkType);
				for (index in 0...checks.length) {
					var next = index == checks.length - 1 ? rejected : builder.createBlock();
					var test = switch checks[index] {
						case Function(_, _): "__closure_is_of_type";
						default: "__std_is_of_type";
					};
					builder.branch(builder.call(test, [value, builder.typeValue(checks[index])], Bool), accepted, next);
					if (next != rejected) builder.select(next);
				}
				builder.select(rejected);
				builder.throwValue(builder.toDyn(builder.constString('Invalid value for ${Std.string(type)}')));
				builder.select(accepted);
			}
		}
		var dynamicValue = IrTypeTools.isDynamic(value.type) ? value : builder.toDyn(value);
		return switch type {
			case Array(element) if (!Type.enumEq(element, Dyn) && !isLaneElement(element, objects)):
				var array = builder.safeCast(dynamicValue, Array(Dyn));
				var checked = builder.call("__array_check_cast", [array, builder.typeValue(element)], Array(Dyn));
				builder.safeCast(builder.toDyn(checked), type);
			default: builder.safeCast(dynamicValue, type);
		};
	}

	static function isLaneElement(type:IrType, objects:Map<String, IrObject>):Bool {
		var element = switch type {
			case Nullable(inner): inner;
			default: type;
		};
		return switch element {
			case Obj(name): var object = objects.get(name);
				object != null && object.isValue;
			default: false;
		};
	}

	static function sameTypes(a:Array<IrType>, b:Array<IrType>):Bool {
		if (a.length != b.length) return false;
		for (index in 0...a.length) if (!Type.enumEq(a[index], b[index])) return false;
		return true;
	}

	static function derivesFrom(facts:ProgramFacts, object:IrObject, owner:String, objects:Map<String, IrObject>):Bool {
		var current:Null<IrObject> = object;
		while (current != null) {
			if (facts.genericOwnerOrigin(current.name) == owner) return true;
			current = current.base == null ? null : objects.get(current.base);
		}
		return false;
	}

	static function depth(object:IrObject, objects:Map<String, IrObject>):Int {
		var result = 0, current:Null<IrObject> = object;
		while (current != null) {
			result++;
			current = current.base == null ? null : objects.get(current.base);
		}
		return result;
	}

	static function findField(object:IrObject, name:String, objects:Map<String, IrObject>):Null<IrObjectField> {
		var current:Null<IrObject> = object;
		while (current != null) {
			for (field in current.fields) if (field.name == name) return field;
			current = current.base == null ? null : objects.get(current.base);
		}
		return null;
	}

	public static function findMethod(object:IrObject, name:String, objects:Map<String, IrObject>,
			functions:IrFunctionIndex):Null<IrFunction> {
		var current:Null<IrObject> = object;
		while (current != null) {
			for (method in current.methods) if (method.name == name) return functions.get(method.functionName);
			IrEntryPrune.noteMethodLookup(current.name, name);
			current = current.base == null ? null : objects.get(current.base);
		}
		return null;
	}
}

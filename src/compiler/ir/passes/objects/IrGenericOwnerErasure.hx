package compiler.ir.passes.objects;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.analysis.IrEntryPrune;
import compiler.ir.analysis.IrExactTypeFacts;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeTools;
import compiler.ir.model.TypeKey;
import compiler.ir.pipeline.IrDerivedHelpers;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.ProgramFacts;
import compiler.ir.verify.IrVerifier;
import compiler.semantic.GeneratedNames;

/**
 * What one function asks the generic owner stage for (`IrGenericOwnerErasure.requestsOf`): a method reference
 * (`METHOD_REFERENCE`: its receiver type as the one argument, its closure type as the result), an erased operation (`ERASED`: its
 * call's argument and result types) or an erased owner's type test (`TYPE_TEST`: the name alone).
 */
typedef IrErasureRequest = {
	final kind:Int;
	final name:String;
	final arguments:Array<IrType>;
	final result:IrType;
}

/** Operations through G<Dynamic> dispatch to the physical owner without changing object identity. */
@:nullSafety(Strict)
class IrGenericOwnerErasure {
	/** The method references, erased operations and type tests each function asks for (`requestsOf`). */
	@:processWide("a contribution memo's key, only ever read")
	public static final REQUESTS =
		new compiler.ir.reuse.IrStageMemo.IrContributionKey<Array<IrErasureRequest>>("erasure-requests");

	public static inline final METHOD_REFERENCE = 0;
	public static inline final ERASED = 1;
	public static inline final TYPE_TEST = 2;

	@:processWide("a shared empty list of requests, only ever read")
	static final NO_REQUESTS:Array<IrErasureRequest> = [];

	/**
	 * What `fn` asks for, in the order it asks: kept by the session for `fn`'s version with `lineage`
	 * (`IrStageMemos.erasureRequests`), else read now, from the function's body when it is one, without decoding it.
	 */
	public static function requestsOf(fn:IrFunction,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>):Array<IrErasureRequest> {
		var version = lineage == null ? 0 : lineage.versionOf(fn);
		if (lineage == null || version == 0)
			return readRequests(fn);
		var memo = lineage.memos.contribution(REQUESTS), known = memo.get(version);
		if (known == null) {
			known = readRequests(fn);
			memo.keep(version, known);
		} else if (lineage.checks && !sameRequests(readRequests(fn), known))
			throw new InternalError('--check-reuse: the generic owner requests reused for ${fn.name} differ from its code');
		return known;
	}

	static function sameRequests(left:Array<IrErasureRequest>, right:Array<IrErasureRequest>):Bool {
		if (left.length != right.length)
			return false;
		for (index in 0...left.length) {
			var a = left[index], b = right[index];
			if (a.kind != b.kind || a.name != b.name || !IrVerifier.sameType(a.result, b.result)
				|| a.arguments.length != b.arguments.length)
				return false;
			for (position in 0...a.arguments.length)
				if (!IrVerifier.sameType(a.arguments[position], b.arguments[position]))
					return false;
		}
		return true;
	}

	static function readRequests(fn:IrFunction):Array<IrErasureRequest> {
		var found:Null<Array<IrErasureRequest>> = null;
		function add(kind:Int, name:String, arguments:Array<IrType>, result:IrType):Void {
			var list = found;
			if (list == null)
				found = list = [];
			list.push({kind: kind, name: name, arguments: arguments, result: result});
		}
		function call(name:String, arguments:Array<IrType>, result:IrType):Void
			if (GeneratedNames.isErasedOperation(name))
				add(ERASED, name, arguments, result);
			else if (StringTools.startsWith(name, TYPE_TEST_PREFIX))
				add(TYPE_TEST, name, [], Void);
		var body = fn.body;
		if (body != null)
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case compiler.ir.model.IrOpcode.Call:
							var name = body.symbol(row).name;
							if (GeneratedNames.isErasedOperation(name)
								|| StringTools.startsWith(name, TYPE_TEST_PREFIX))
								call(name, [for (index in 0...body.operandCount(row)) body.valueType(body.operand(row,
									index))],
									body.valueType(body.output(row)));
						case compiler.ir.model.IrOpcode.InstanceClosure:
							var name = body.symbol(row).name;
							if (compiler.ir.gen.IrMethodReferences.isReference(name))
								add(METHOD_REFERENCE, name, [body.valueType(body.operand(row, 0))],
									body.valueType(body.output(row)));
						default:
					}
					row = body.nextRow(row);
				}
			}
				else
				for (block in fn.blocks)
					for (instruction in block.instructions)
						switch instruction.value {
							case Call(output, name, arguments):
								if (GeneratedNames.isErasedOperation(name.name)
									|| StringTools.startsWith(name.name, TYPE_TEST_PREFIX))
									call(name.name, [for (argument in arguments) argument.type], output.type);
							case InstanceClosure(output, name,
								receiver) if (compiler.ir.gen.IrMethodReferences.isReference(name.name)):
								add(METHOD_REFERENCE, name.name, [receiver.type], output.type);
							default:
						}
		return found == null ? NO_REQUESTS : found;
	}

	static inline final TYPE_TEST_PREFIX = "$generic-type-test:";
	/** Whether `name` is an operation through an erased generic owner (`$generic-erased:Owner:get|set|call:member`). */
	public static inline function isOperation(name:String):Bool
		return GeneratedNames.isErasedOperation(name);

	/** The erased-generic call a bound method of an erased owner makes (see IrMethodReferences). */
	public static inline function erasedCallName(owner:String, member:String):String
		return GeneratedNames.erasedOperation(owner, "call", member);

	public static function typeTestName(owner:String, exact:Bool):String
		return TYPE_TEST_PREFIX + (exact ? "exact:" : "instance:") + owner;

	/** What an operation reads (`IrDerivedHelpers`): what it dispatches to (`operationText`), by its name. */
	static inline final OPERATION = 0;

	/** What a type test reads: the classes whose generic owner it is, by the owner's name. */
	static inline final TESTED = 1;

	/**
	 * Generate only the operations that occur in typed code, before value-field lowering. Each is made through `helpers`
	 * (`IrDerivedHelpers`), reading what it dispatches to, so a session's operation whose classes are unchanged is last build's.
	 */
	public static function generate(facts:ProgramFacts, functions:Array<IrFunction>, objects:Array<IrObject>,
			?lineage:compiler.ir.reuse.IrStageMemo.IrLineage, ?helpers:IrDerivedHelpers):Void {
		var derived = helpers ?? new IrDerivedHelpers(STAGE),
			byName = [for (object in objects) object.name => object],
			plans:Map<String, ErasedPlan> = [],
			tested:Map<String, Array<String>> = [];
		derived.print = (kind, key) -> switch kind {
			case OPERATION:
				var plan = plans.get(key);
				plan == null ? "" : operationText(plan, byName);
			case TESTED: (tested.get(key) ?? []).join("\n");
			case _: "";
		};
		generateTypeTests(facts, functions, objects, lineage, tested, derived);
		var requests:Map<String, {arguments:Array<IrType>, result:IrType}> = [];
		for (fn in functions)
			for (request in requestsOf(fn, lineage))
				if (request.kind == ERASED) {
					var name = request.name,
						signature = {arguments: request.arguments, result: request.result},
						previous = requests.get(name);
					if (previous != null && (!IrVerifier.sameType(previous.result, signature.result)
						|| !sameTypes(previous.arguments, signature.arguments)))
						throw new InternalError('Conflicting erased generic operation "$name"');
					requests.set(name, signature);
				}
		var byFunction = new IrFunctionIndex(STAGE, functions);
		var sorted = [for (name => signature in requests) {
			name: name, signature: signature
		}];
		sorted.sort((a, b) -> Reflect.compare(a.name, b.name));
		for (entry in sorted) {
			var name = entry.name,
				signature = entry.signature,
				parts = GeneratedNames.erasedOperationPath(name).split(":");
			if (parts.length != 3 || signature.arguments.length == 0
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
			// The checked arms, most derived first, after an exact-class arm per candidate, the owner's own layout first.
			var checked = [for (candidate in candidates) armOf(candidate, operation, member, byName, byFunction)],
				exact = checked.copy();
			exact.sort((a, b) -> (a.object == owner ? 0 : 1) - (b.object == owner ? 0 : 1));
			var own = byName.get(owner),
				ownArm = own == null ? null : armOf(own, operation, member, byName, byFunction),
				fast = own != null && !own.isValue && ownArm != null && (ownArm.field != null || ownArm.method != null);
			var plan:ErasedPlan = {
				owner: owner,
				operation: operation,
				member: member,
				arguments: signature.arguments,
				result: signature.result,
				exact: exact,
				checked: checked,
				own: fast ? ownArm : null
			};
			plans.set(name, plan);
			if (!fast) {
				functions.push(derived.make(name, reader -> {
					reader.read(OPERATION, name);
					dispatchOf(plan, name, name, byName, ProviderOperations.detailed(ProviderOperation.GenericErased,
						operation + ":" + member));
				}));
				continue;
			}
			// When the owner's own class has the member, the operation's name is a fast path the inliner places at each call
			// site: its own class's arm, else a call to the full accessor (the dispatch). An erased owner of a reference type
			// argument is almost always its own class, so a read is a type compare and a field load.
			var dispatch = GeneratedNames.erasedDispatch(owner, operation, member);
			functions.push(derived.make(dispatch, reader -> {
				reader.read(OPERATION, name);
				dispatchOf(plan, name, dispatch, byName,
					ProviderOperations.detailed(ProviderOperation.GenericErased,
					operation + ":" + member + ":dispatch"));
			}));
			functions.push(derived.make(name, reader -> {
				reader.read(OPERATION, name);
				fastPathOf(plan, name, dispatch, byName);
			}));
		}
	}

	public static inline final STAGE = "generic-owner-erasure";

	/** The arm of `operation` on `object`: the field it reads or writes, or the method it calls, found along its bases. */
	static function armOf(object:IrObject, operation:String, member:String, byName:Map<String, IrObject>,
			byFunction:IrFunctionIndex):ErasedArm
		return {
			object: object.name,
			field: operation == "call" ? null : findField(object, member, byName),
			method: operation == "call" ? findMethod(object, member, byName, byFunction) : null
		};

	/** The text of what an operation's functions are made of: its signature, its arms and the conversions they make. */
	static function operationText(plan:ErasedPlan, byName:Map<String, IrObject>):String {
		var parts = [
			'${plan.owner} ${plan.operation} ${plan.member}',
			[for (argument in plan.arguments) IrTypeIdentity.text(argument)].join(" "),
			conversionText(plan.result, byName)
		];
		function arm(label:String, arm:ErasedArm):Void {
			var field = arm.field, method = arm.method;
			if (field != null)
				parts.push('$label ${arm.object} field ${conversionText(field.type, byName)}');
			else if (method != null)
				parts.push('$label ${arm.object} method ${IrTypeIdentity.text(method.result)} '
					+ [for (argument in method.arguments) conversionText(argument.type, byName)].join(" "));
			else
				parts.push('$label ${arm.object} none');
		}
		for (entry in plan.exact)
			arm("exact", entry);
		for (entry in plan.checked)
			arm("checked", entry);
		var own = plan.own;
		if (own != null)
			arm("own", own);
		return parts.join("\n");
	}

	/** The operation on one class, its receiver already cast to it, emitted by `b` with its arguments `values`. */
	static function emitArm(b:IrBuilder, plan:ErasedPlan, name:String, values:Array<IrValue>, arm:ErasedArm,
			target:IrValue,
			byName:Map<String, IrObject>):Void {
		var field = arm.field, method = arm.method;
		switch plan.operation {
			case "get" if (field != null):
				b.returnValue(convert(b, b.fieldGet(target, plan.member, field.type), plan.result, byName));
			case "set" if (field != null && values.length == 1):
				b.fieldSet(target, plan.member, convert(b, values[0], field.type, byName));
				b.returnValue(b.constVoid());
			case "call" if (method != null):
				if (method.arguments.length != values.length + 1)
					throw new InternalError('Incompatible erased method "$name"');
				var adapted = [
					for (index in 0...values.length)
						convert(b, values[index], method.arguments[index + 1].type, byName)
				],
					result = b.methodCall(target, plan.member, adapted, method.result);
				b.returnValue((switch (plan.result) {
					case Void: true;
					default: false;
				}) ? result : convert(b, result, plan.result, byName));
			default:
				throw new InternalError('Invalid erased generic operation "$name"');
		}
	}

	/**
	 * The full accessor of the operation `name`, as the function `functionName`: an exact-class arm per class, a type compare and a
	 * cast that cannot fail (IrExactTypeFacts), then the checked arms for what no exact arm matched: an object reached through a
	 * virtual, or a class the exact arms do not list.
	 */
	static function dispatchOf(plan:ErasedPlan, name:String, functionName:String, byName:Map<String, IrObject>,
			detail:ProviderOperation):IrFunction {
		var builder = new IrBuilder(),
			receiver = builder.argument("receiver", Dyn),
			arguments = [for (index in 1...plan.arguments.length) builder.argument('argument$index',
				plan.arguments[index])];
		function arms(list:Array<ErasedArm>, test:String):Void
			for (arm in list) {
				if (arm.field == null && arm.method == null)
					continue;
				var matched = builder.createBlock(), next = builder.createBlock(), type:IrType = Obj(arm.object);
				builder.branch(builder.call(test, [receiver, builder.typeValue(type)], Bool), matched, next);
				builder.select(matched);
				emitArm(builder, plan, name, arguments, arm, builder.safeCast(receiver, type), byName);
				builder.select(next);
			}
		arms(plan.exact, IrExactTypeFacts.TEST);
		arms(plan.checked, "__std_is_of_type");
		builder.throwValue(builder.toDyn(builder.constString('Invalid receiver for ${plan.owner}.${plan.member}')));
		return new IrFunction(functionName, builder.arguments, plan.result, builder.blocks,
			Provider(TypeKey.of(Obj(plan.owner)), detail));
	}

	/** The fast path `name` of an operation whose owner's own class has the member: that class's arm, else `dispatch`. */
	static function fastPathOf(plan:ErasedPlan, name:String, dispatch:String, byName:Map<String, IrObject>):IrFunction {
		var own = plan.own;
		if (own == null)
			throw new InternalError('The erased operation "$name" has no fast path');
		var fast = new IrBuilder(),
			fastReceiver = fast.argument("receiver", Dyn),
			fastArguments = [
				for (index in 1...plan.arguments.length)
					fast.argument('argument$index', plan.arguments[index])
			],
			matched = fast.createBlock(),
			other = fast.createBlock(),
			ownType:IrType = Obj(plan.owner);
		fast.branch(fast.call(IrExactTypeFacts.TEST, [fastReceiver, fast.typeValue(ownType)], Bool), matched, other);
		fast.select(matched);
		emitArm(fast, plan, name, fastArguments, own, fast.safeCast(fastReceiver, ownType), byName);
		fast.select(other);
		fast.returnValue(fast.call(dispatch, [fastReceiver].concat(fastArguments), plan.result));
		return new IrFunction(name, fast.arguments, plan.result, fast.blocks,
			Provider(TypeKey.of(Obj(plan.owner)),
			ProviderOperations.detailed(ProviderOperation.GenericErased, plan.operation + ":" + plan.member)), null,
			true);
	}

	/** Regenerate type tests from the current layouts, including layouts added by an incremental edit. */
	static function generateTypeTests(facts:ProgramFacts, functions:Array<IrFunction>, objects:Array<IrObject>,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>, tested:Map<String, Array<String>>,
			derived:IrDerivedHelpers):Void {
		var requests:Map<String, Bool> = [];
		for (fn in functions)
			for (request in requestsOf(fn, lineage))
				if (request.kind == TYPE_TEST)
					requests.set(request.name, true);
		var names = [for (name in requests.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var parts = name.substr(TYPE_TEST_PREFIX.length).split(":"), exact = parts[0] == "exact";
			if (parts.length != 2
				|| (!exact && parts[0] != "instance")) throw new InternalError('Invalid generic type test "$name"');
			var owner = parts[1], candidates = tested.get(owner);
			if (candidates == null) {
				candidates = [for (object in objects) if (facts.genericOwnerOrigin(object.name) == owner) object.name];
				candidates.sort(Reflect.compare);
				tested.set(owner, candidates);
			}
			var classes = candidates;
			functions.push(derived.make(name, reader -> {
				reader.read(TESTED, owner);
				var builder = new IrBuilder(), value = builder.argument("value", Dyn), matched = builder.createBlock();
				for (candidate in classes) {
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
				new IrFunction(name, builder.arguments, Bool, builder.blocks,
					Provider(TypeKey.of(Obj(owner)),
					ProviderOperations.detailed(ProviderOperation.GenericTypeTest, exact ? "exact" : "instance")));
			}));
		}
	}

	/**
	 * What `convert` reads of `objects` to convert a value to `type`, as text: the type, and whether the object it names, or the
	 * element of the array it is, is a value.
	 */
	public static function conversionText(type:IrType, objects:Map<String, IrObject>):String {
		var named = switch type {
			case Obj(name), Array(Obj(name)), Array(Nullable(Obj(name))): name;
			default: null;
		}, text = IrTypeIdentity.text(type);
		if (named == null)
			return text;
		var object = objects.get(named);
		return text + (object == null ? " -" : object.isValue ? " value" : " object");
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
		for (index in 0...a.length) if (!IrVerifier.sameType(a[index], b[index])) return false;
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
			for (method in current.methods) if (method.name == name) return functions.get(method.functionName.name);
			IrEntryPrune.noteMethodLookup(current.name, name);
			current = current.base == null ? null : objects.get(current.base);
		}
		return null;
	}
}

/** One class an erased operation dispatches to: the field it reads or writes, or the method it calls. */
private typedef ErasedArm = {
	final object:String;
	final field:Null<IrObjectField>;
	final method:Null<IrFunction>;
}

/** What an erased operation's functions are made of (`IrGenericOwnerErasure.generate`). */
private typedef ErasedPlan = {
	final owner:String;
	final operation:String;
	final member:String;
	final arguments:Array<IrType>;
	final result:IrType;
	final exact:Array<ErasedArm>;
	final checked:Array<ErasedArm>;

	/** The owner's own arm, when the operation has a fast path. */
	final own:Null<ErasedArm>;
}

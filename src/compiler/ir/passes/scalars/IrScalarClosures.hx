package compiler.ir.passes.scalars;

import compiler.ir.model.IrBody;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrPassScratch;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.passes.objects.IrCheckedDynamicCasts;
import compiler.ir.passes.values.IrInlineValueLayout;
import compiler.ir.passes.values.IrValueInterfaceBoxes;

import compiler.core.InternalError;
import compiler.ir.model.Ir;
import compiler.ir.passes.values.IrInlineValueLayout.IrInlineValueSlot;

/** HashLink's scalar argument/result convention applied to typed, non-erased closures. */
@:nullSafety(Strict)
class IrScalarClosures implements compiler.ir.pipeline.IrFunctionPass {
	/** What each function's rows do with closures (`IrClosureUses`). */
	@:processWide("a contribution memo's key, only ever read")
	public static final USES = new compiler.ir.reuse.IrStageMemo.IrContributionKey<IrClosureUses>("closure-uses");

	static inline final STAGE = "scalar-closures";

	/** The stages the adapters' interface boxes and checked casts are derived in. */
	static inline final BOX_STAGE = "scalar-closure-boxes";

	static inline final CAST_STAGE = "scalar-closure-casts";

	/**
	 * The fact of a function type, by its key: 0 when it is no candidate, else its scalar ABI as text (`abi`), the physical type
	 * and the fields its value arguments and result pass as, interned.
	 */
	static inline final CANDIDATE = 0;

	/** The fact of an object name: the inline enum stored as that object, interned; 0 for none. */
	static inline final INLINE_ENUM = 1;

	// Summary bits: the function does something with closures; it is not only reachable, so its signature is seen outside.
	static inline final USES_CLOSURES = 1;

	static inline final EXPOSED = 2;

	// Helper kinds (`request`): each is made for a closure type.
	static inline final ERASURE = 0;
	static inline final RESTORATION = 1;
	static inline final SIGNATURE_CHECK = 2;

	final program:IrProgram;
	final objects:Map<String, IrObject>;
	final inlineEnums:Map<String, String> = [];
	final layouts:IrInlineValueLayout;
	final candidates:Map<String, IrType> = [];
	final excluded:Map<String, Bool> = [];
	final erasures:Map<String, {maker:String, environment:String}> = [];
	final restorations:Map<String, String> = [];
	final signatureChecks:Map<String, String> = [];

	/** The erased-call adapters asked for, by closure type, each made and rewritten in `finish`. */
	final erasedCalls:Array<IrType> = [];

	final generatedMakers:Array<IrFunction> = [];
	final generatedObjects:Array<IrObject> = [];

	/** By closure type key, the digest its helpers are named by. */
	final suffixes:Map<String, String> = [];

	/** How many operands read each value id of the function `IrClosureUses.read` is reading, its storage kept from one to the next. */
	final useCounts:Array<Int> = [];

	final types:IrTypeIds;
	final scratch:IrPassScratch;
	final lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>;

	/** By type id, the keys of the function types the type names where `changesType` looks, or null when not known yet. */
	final functionKeys:Array<Null<Array<String>>> = [];

	/** By value id, the type a `TypeValue` row of the function being rewritten names, before the rewrite. */
	final typeValues:Map<Int, IrType> = [];

	/**
	 * Rewrites `program`'s functions as bodies (docs/design/IR_CORE_COLUMNS.md, migration), made with `types` (those of the
	 * program's bodies when not given, `IrTypeIds.ofFunctions`). A function that changes becomes its edited body: owned by the
	 * next stage: edited in place, or a copy when a cache holds the body.
	 */
	public static function rewrite(program:IrProgram, ?types:IrTypeIds, ?scratch:IrPassScratch):Void
		program.functions = compiler.ir.pipeline.IrFunctionStages.apply(STAGE,
			new IrScalarClosures(program, types == null ? IrTypeIds.ofFunctions(program.functions) : types,
			scratch == null ? new IrPassScratch() : scratch),
			program.functions);

	/**
	 * The scalar closure ABI per function (`IrFunctionPass`). The candidate closure types are chosen over the whole program from
	 * what each function's rows do with closures (`IrClosureUses`, one record per version in a session); the rewrite of a function
	 * reads, for each function type its types name, the type's scalar ABI (`CANDIDATE`), and asks for the adapters it calls
	 * (`request`), so a session keeps it while those ABIs hold. The adapters are derived (`IrFunctionStages.derived`) from the
	 * closure type their name digests, reading its ABI and the inline enums they box (`INLINE_ENUM`); the interface boxes and
	 * checked casts they need are derived from them in stages of their own.
	 */
	public function new(program:IrProgram, types:IrTypeIds, scratch:IrPassScratch,
			?lineage:compiler.ir.reuse.IrStageMemo.IrLineage) {
		this.program = program;
		this.lineage = lineage;
		this.types = types;
		this.scratch = scratch;
		objects = [for (object in program.objects) object.name => object];
		for (declaration in program.enums)
			if (declaration.inlineStorage != null)
				inlineEnums.set(declaration.inlineStorage, declaration.name);
		layouts = new IrInlineValueLayout(IrObjectTable.of(objects));
	}

	/** `fn`'s body, encoded when it has none; in a compile that keeps no session its objects go. */
	function bodyOf(fn:IrFunction):IrBody {
		var body = fn.bodyIn(types, scratch.bodyBuilder);
		return body;
	}

	/** What the choice reads of a function: what it does with closures (`USES`), and its signature when it is not only reachable (`EXPOSED`). */
	public function summarize(fn:IrFunction):Int
		return (IrClosureUses.of(fn, types, scratch, useCounts, lineage).events.length > 0 ? USES_CLOSURES : 0)
			| (fn.retention != Reachable ? EXPOSED : 0);

	/** The candidate closure types: what each function does with closures (by its summary), decided against the program. */
	public function prepare(inputs:Array<IrFunction>, summaries:Array<Int>,
			names:compiler.ir.pipeline.IrFunctionIndex):Void {
		for (native in program.natives) {
			for (type in native.arguments)
				excludeNested(type);
			excludeNested(native.result);
		}
		for (native in program.cNatives) {
			for (type in native.arguments)
				excludeNested(type);
			excludeNested(native.result);
		}
		var entry = names.get(program.entryPoint);
		if (entry != null)
			excludeSignature(entry);
		for (position in 0...inputs.length) {
			var fn = inputs[position], summary = summaries[position];
			if (summary & EXPOSED != 0)
				excludeSignature(fn);
			if (summary & USES_CLOSURES == 0)
				continue;
			var uses = IrClosureUses.of(fn, types, scratch, useCounts, lineage), events = uses.events, index = 0;
			while (index < events.length) {
				var type = types.type(events[index + 1]);
				switch events[index] {
					case IrClosureUses.NOTE:
						note(type);
					case IrClosureUses.EXCLUDE:
						excludeNested(type);
					case IrClosureUses.STATIC:
						if (note(type) && !names.exists(IrScalarArguments.PREFIX + uses.names[events[index + 2]]))
							excluded.set(key(type), true);
					default:
						if (note(type)
							&& (isValue(types.type(events[index + 3]))
							|| !names.exists(IrScalarArguments.PREFIX + uses.names[events[index + 2]])))
							excluded.set(key(type), true);
				}
				index += events[index] == IrClosureUses.INSTANCE ? 4 : events[index] == IrClosureUses.STATIC ? 3 : 2;
			}
		}
		for (name in excluded.keys())
			candidates.remove(name);
	}

	public function fact(kind:Int, key:String):Int {
		if (kind == INLINE_ENUM) {
			var name = inlineEnums.get(key);
			return name == null ? 0 : intern(name);
		}
		var type = candidates.get(key);
		return type == null ? 0 : intern(abi(type));
	}

	/** A number for `text` in the session's facts; without a session nothing is checked again, so any number does. */
	function intern(text:String):Int {
		var known = lineage;
		return known == null ? 1 : known.memos.facts.intern(text);
	}

	/**
	 * What a rewrite or an adapter reads of the candidate `type`: its physical type, and for each value argument and a value result
	 * the slots it passes as, each with its path and the physical types of the fields along it.
	 */
	function abi(type:IrType):String {
		var text = new StringBuf();
		text.add(key(mapType(type)));
		switch type {
			case Function(arguments, result):
				for (index in 0...arguments.length)
					if (isValue(arguments[index])) {
						text.add("|" + index);
						addSlots(text, arguments[index]);
					}
				if (isValue(result)) {
					text.add("|result");
					addSlots(text, result);
				}
			default:
		}
		return text.toString();
	}

	function addSlots(text:StringBuf, type:IrType):Void
		for (slot in slots(type)) {
			text.add(":" + slot.path.join(".") + "=" + key(mapType(slot.type)));
			var logical = type;
			for (part in slot.path) {
				var field = fieldOf(logical, part);
				text.add("," + key(mapType(field.type)));
				logical = field.type;
			}
		}

	/** Reads the ABI of every function type `type` names where `mapType` looks. */
	function readTypeKeys(type:IrType, reader:compiler.ir.reuse.IrFactReader):Void {
		var keys = [];
		addFunctionKeys(type, keys);
		for (name in keys)
			reader.read(CANDIDATE, name);
	}

	static function addFunctionKeys(type:IrType, keys:Array<String>):Void
		switch type {
			case Abstract(_):
				var element = IrHlScalarRef.element(type);
				if (element != null)
					addFunctionKeys(element, keys);
			case Function(arguments, result):
				var name = key(type);
				if (keys.indexOf(name) < 0)
					keys.push(name);
				for (argument in arguments)
					addFunctionKeys(argument, keys);
				addFunctionKeys(result, keys);
			case Array(element), Iterator(element), Nullable(element):
				addFunctionKeys(element, keys);
			default:
		}

	function readTypeFacts(id:Int, reader:compiler.ir.reuse.IrFactReader):Void {
		if (id < 0)
			return;
		var keys = id < functionKeys.length ? functionKeys[id] : null;
		if (keys == null) {
			keys = [];
			addFunctionKeys(types.type(id), keys);
			while (functionKeys.length <= id)
				functionKeys.push(null);
			functionKeys[id] = keys;
		}
		for (name in keys)
			reader.read(CANDIDATE, name);
	}

	public function transform(fn:IrFunction, summary:Int, reader:compiler.ir.reuse.IrFactReader):IrFunction {
		var body = bodyOf(fn);
		readTypeFacts(body.result, reader);
		for (value in 0...body.valueLimit())
			readTypeFacts(body.valueTypeId(IrValueId.of(value)), reader);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.TypeValue)
					readTypeFacts(body.aux(row), reader);
				row = body.nextRow(row);
			}
		}
		return candidates.keys().hasNext() ? rewriteFunction(fn, body, reader) : fn;
	}

	public function request(kind:Int, type:IrType, name:Null<String>):Void
		switch kind {
			case ERASURE:
				ensureErasure(type);
			case RESTORATION:
				ensureRestoration(type);
			case SIGNATURE_CHECK:
				ensureSignatureCheck(type);
			default:
				throw new InternalError('Unknown scalar closure helper kind $kind');
		}

	function note(type:IrType):Bool {
		return switch type {
			case Function(arguments, result): var found = isValue(result),
				valid = scalarizable(result);
				for (argument in arguments) {
					if (isValue(argument))
						found = true;
					if (!scalarizable(argument))
						valid = false;
				}
				if (found && valid) candidates.set(key(type), type);
				found && valid;
			default: false;
		};
	}

	/** Excludes the closure types of `fn`'s signature, which callers outside the program may see. */
	function excludeSignature(fn:IrFunction):Void {
		for (argument in fn.arguments)
			excludeNested(argument.type);
		excludeNested(fn.result);
	}

	function excludeNested(type:IrType):Void {
		switch type {
			case Function(arguments, result):
				excluded.set(key(type), true);
				for (argument in arguments)
					excludeNested(argument);
				excludeNested(result);
			case Array(element), Iterator(element), Nullable(element):
				excludeNested(element);
			default:
		}
	}

	function scalarizable(type:IrType):Bool {
		if (!isValue(type))
			return true;
		for (slot in slots(type)) {
			if (slot.isPresence)
				return false;
			// A recursively self-referential closure layout needs a recursive ABI type, not an eager expansion.
			switch slot.type {
				case Function(_, _):
					return false;
				default:
			}
		}
		return true;
	}

	/** The program with the candidates' types mapped, the adapters made and the rewritten functions. */
	public function finish(rewritten:Array<IrFunction>):Array<IrFunction> {
		if (!candidates.keys().hasNext())
			return rewritten;
		var generated:Array<IrFunction> = [],
			generatedIndex = 0;
		// Rewriting an adapter can ask for more.
		while (generatedIndex < erasedCalls.length)
			generated.push(erasedCall(erasedCalls[generatedIndex++]));
		var mappedObjects:Array<IrObject> = [for (object in program.objects)
			{
				name:object.name,
					isValue:object.isValue,
					nativeLayout:object.nativeLayout,
					base:object.base,
					interfaces:object.interfaces,
					fields:[for (field in object.fields)
					{
						name:field.name,
							type:mapType(field.type),
							nativeLayout:field.nativeLayout,
							scalarStorage:field.scalarStorage,
							nullableScalarStorage:field.nullableScalarStorage
					}],
						methods:object.methods
			}];
		for (object in generatedObjects)
			mappedObjects.push(object);
		program.objects = mappedObjects;
		program.interfaces = [for (interfaceDecl in program.interfaces)
			{
				name:interfaceDecl.name,
					bases:interfaceDecl.bases,
					methods:[for (method in interfaceDecl.methods)
					{
						name:method.name,
							arguments:[for (argument in method.arguments) mapType(argument)],
							result:mapType(method.result)
					}]
			}];
		program.enums = [for (entry in program.enums)
			{
				name:entry.name,
					isRecursive:entry.isRecursive,
					inlineStorage:entry.inlineStorage,
					cases:[for (item in entry.cases)
					{
						name:item.name, params:[for (type in item.params) mapType(type)]
					}]
			}];
		program.staticFields = [for (field in program.staticFields)
			{
				name:field.name, type:mapType(field.type)
			}];
		// The adapters' interface boxes and checked casts are derived from each adapter's version, so a kept adapter keeps them.
		var checks = lineage != null && lineage.checks;
		generated = IrValueInterfaceBoxes.rewriteDerived(BOX_STAGE, generated.concat(generatedMakers), program.objects,
			program.interfaces, rewritten, lineage, checks, types, scratch.bodyBuilder);
		generated = IrCheckedDynamicCasts.rewriteBodies(CAST_STAGE, generated, program.objects, false, rewritten, false,
			false, types, scratch.bodyBuilder, lineage, checks);
		var result = rewritten.concat(generated);
		program.functions = result;
		var hasTypeTest = false;
		for (native in program.natives)
			if (native.name == "__std_is_of_type")
				hasTypeTest = true;
		if (!hasTypeTest && generated.length > 0)
			program.natives.push({
				name: "__std_is_of_type",
				library: "haxeon_runtime",
				symbol: "__std_is_of_type",
				arguments: [Dyn, TypeRef],
				result: Bool
			});
		return result;
	}

	/** An ordinary function can still need a boundary bridge for scalar callback arguments/results. */
	function needsBoundaryAdapter(type:IrType):Bool
		return switch type {
			case Function(arguments, result): candidates.exists(key(type))
				|| Lambda.exists(arguments, needsBoundaryAdapter) || needsBoundaryAdapter(result);
			case Nullable(inner): needsBoundaryAdapter(inner);
			default: false;
		};

	function inlineEnum(type:IrType, reader:compiler.ir.reuse.IrFactReader):Null<String>
		return switch type {
			case Obj(name): reader.read(INLINE_ENUM, name) == 0 ? null : inlineEnums.get(name);
			default: null;
		};

	function toDynamic(builder:IrBuilder, value:IrValue, type:IrType, reader:compiler.ir.reuse.IrFactReader):IrValue {
		switch type {
			case EnumTag(name):
				return builder.intrinsic(EnumTagBox(EnumTag(name)), [value], Dyn);
			default:
		}
		var enumName = inlineEnum(type, reader);
		return enumName == null ? builder.toDyn(value) : builder.intrinsic(InlineEnumBox(Enum(enumName)), [value], Dyn);
	}

	function fromDynamic(builder:IrBuilder, value:IrValue, type:IrType, reader:compiler.ir.reuse.IrFactReader):IrValue {
		switch type {
			case EnumTag(name):
				return builder.intrinsic(EnumTagUnbox(EnumTag(name)), [value], type);
			default:
		}
		var enumName = inlineEnum(type, reader);
		return enumName == null ? builder.safeCast(value, type) : builder.intrinsic(InlineEnumUnbox(Enum(enumName)),
			[value], type);
	}

	function mapType(type:IrType):IrType
		return switch type {
			case Abstract(_):
				var element = IrHlScalarRef.element(type);
				element == null ? type : IrHlScalarRef.type(mapType(element));
			case Function(arguments, result) if (candidates.exists(key(type))):
				var physical:Array<IrType> = [];
				for (argument in arguments)
					if (isValue(argument))
						for (slot in slots(argument))
							physical.push(mapType(slot.type));
						else
							physical.push(mapType(argument));
				if (isValue(result))
					for (slot in slots(result))
						physical.push(IrHlScalarRef.type(mapType(slot.type)));
				Function(physical, isValue(result) ? Void : mapType(result));
			case Function(arguments, result): Function([for (argument in arguments) mapType(argument)],
				mapType(result));
			case Array(element): Array(mapType(element));
			case Iterator(element): Iterator(mapType(element));
			case Nullable(element): Nullable(mapType(element));
			default: type;
		};

	/** The exact recursive type boundary rewritten by mapType. */
	function changesType(type:IrType):Bool
		return switch type {
			case Abstract(_):
				var element = IrHlScalarRef.element(type);
				element != null && changesType(element);
			case Function(arguments, result): candidates.exists(key(type)) || Lambda.exists(arguments, changesType)
				|| changesType(result);
			case Array(element), Iterator(element), Nullable(element): changesType(element);
			default: false;
		};

	/** Whether a type `body` holds changes: a value's (an argument's, a row's, a binding's), the result, a `TypeValue`'s. */
	function needsRewrite(body:IrBody):Bool {
		if (changesType(body.types.type(body.result)))
			return true;
		for (value in 0...body.valueLimit())
			if (body.valueTypeId(IrValueId.of(value)) >= 0 && changesType(body.valueType(IrValueId.of(value))))
				return true;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.TypeValue && changesType(body.typeOperand(row)))
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	function rewriteFunction(fn:IrFunction, source:IrBody, reader:compiler.ir.reuse.IrFactReader):IrFunction {
		if (!needsRewrite(source))
			return fn;
		var body = source.forEditing(scratch.bodyBuilder), limit = body.valueLimit();
		typeValues.clear();
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.TypeValue)
					typeValues.set(body.output(row), body.typeOperand(row));
				row = body.nextRow(row);
			}
		}
		// The rows read the types as they were; the values' types change once every row is rewritten.
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row), where = body.provenance(row);
				switch body.opcode(row) {
					case IrOpcode.Call if (body.operandCount(row) == 2
						&& body.symbol(row).name == "__closure_is_of_type"):
						var tested = typeValues.get(body.operand(row, 1));
						if (tested != null && needsBoundaryAdapter(tested)) {
							reader.request(SIGNATURE_CHECK, tested);
							body.beginRow();
							body.pushOperand(body.operand(row, 0));
							var check = body.endRow(IrOpcode.Call, body.output(row),
								IrSymbol.of(signatureCheckName(tested)).id,
								where);
							body.linkAfter(block, row, check);
							body.removeRow(block, row);
						}
					case IrOpcode.ToDyn if (needsBoundaryAdapter(body.valueType(body.operand(row, 0)))):
						var input = body.operand(row, 0),
							type = body.valueType(input),
							boxed = body.newValue("$scalar-closure:erased", body.typeId(erasedType(type)));
						reader.request(ERASURE, type);
						body.beginRow();
						body.pushOperand(input);
						body.linkBefore(block, row,
							body.endRow(IrOpcode.Call, boxed, IrSymbol.of(erasureName(type)).id, where));
						body.setOperand(row, 0, boxed);
					case IrOpcode.SafeCast if (restoresFromDynamic(body, row)):
						var type = body.valueType(body.output(row));
						reader.request(RESTORATION, type);
						body.setOperation(row, IrOpcode.Call, IrSymbol.of(restorationName(type)).id);
					case IrOpcode.StaticClosure if (candidates.exists(key(body.valueType(body.output(row))))):
						body.setAux(row, IrSymbol.of(IrScalarArguments.PREFIX + body.symbol(row).name).id);
					case IrOpcode.InstanceClosure if (candidates.exists(key(body.valueType(body.output(row))))):
						body.setAux(row, IrSymbol.of(IrScalarArguments.PREFIX + body.symbol(row).name).id);
					case IrOpcode.CallClosure if (candidates.exists(key(body.valueType(body.operand(row, 0))))):
						expandCall(body, block, row);
					case IrOpcode.TypeValue:
						body.setAux(row, body.typeId(mapType(body.typeOperand(row))));
					default:
				}
				row = following;
			}
		}
		for (value in 0...limit) {
			var id = IrValueId.of(value), type = body.valueTypeId(id);
			if (type >= 0)
				body.setValueType(id, body.typeId(mapType(body.types.type(type))));
		}
		body.setResult(body.typeId(mapType(body.types.type(body.result))));
		return IrFunction.ofOwnedBody(body);
	}

	/** Whether the cast at `row` takes a closure that needs a boundary adapter back from `Dyn`. */
	function restoresFromDynamic(body:IrBody, row:Int):Bool
		return switch body.valueType(body.operand(row, 0)) {
			case Dyn: needsBoundaryAdapter(body.valueType(body.output(row)));
			default: false;
		};

	/**
	 * Replaces the closure call at `row` by one that passes each value argument's fields and, for a value result, a reference
	 * per field that the callee stores through, the result made again from them after it.
	 */
	function expandCall(body:IrBody, block:Int, row:Int):Void {
		var where = body.provenance(row),
			out = body.output(row),
			closure = body.operand(row, 0),
			outType = body.valueType(out),
			expanded:Array<IrValueId> = [];
		for (index in 1...body.operandCount(row)) {
			var argument = body.operand(row, index), argumentType = body.valueType(argument);
			if (!isValue(argumentType)) {
				expanded.push(argument);
				continue;
			}
			for (slot in slots(argumentType)) {
				var current = argument, logical = argumentType;
				for (part in slot.path) {
					var field = fieldOf(logical, part),
						leaf = body.newValue("$scalar-closure:field", body.typeId(mapType(field.type)));
					body.beginRow();
					body.pushOperand(current);
					body.linkBefore(block, row, body.endRow(IrOpcode.FieldGet, leaf, IrSymbol.of(part).id, where));
					current = leaf;
					logical = field.type;
				}
				expanded.push(current);
			}
		}
		var resultSlots = isValue(outType) ? slots(outType) : [], references:Array<IrValueId> = [];
		for (slot in resultSlots) {
			var type = mapType(slot.type),
				zero = body.newValue("$scalar-closure:zero", body.typeId(type)),
				reference = body.newValue("$scalar-closure:reference", body.typeId(IrHlScalarRef.type(type)));
			body.beginRow();
			var initial = switch type {
				case I32 | I64: body.endRow(IrOpcode.ConstInt, zero, 0, where);
				case F32 | F64: body.endRow(IrOpcode.ConstFloat, zero, body.addFloat(0.0), where);
				case Bool: body.endRow(IrOpcode.ConstBool, zero, 0, where);
				default: body.endRow(IrOpcode.ConstNull, zero, 0, where);
			};
			body.linkBefore(block, row, initial);
			body.beginRow();
			body.pushOperand(zero);
			body.linkBefore(block, row,
				body.endRow(IrOpcode.Call, reference, IrSymbol.of(IrHlScalarRef.ADDRESS).id, where));
			references.push(reference);
			expanded.push(reference);
		}
		var output = out;
		if (resultSlots.length > 0)
			output = body.newValue("$scalar-closure:call", body.typeId(Void));
		body.beginRow();
		body.pushOperand(closure);
		for (value in expanded)
			body.pushOperand(value);
		var call = body.endRow(IrOpcode.CallClosure, output, 0, where);
		body.linkAfter(block, row, call);
		body.removeRow(block, row);
		if (resultSlots.length == 0)
			return;
		var after = call;
		inline function add(made:Int):Void {
			body.linkAfter(block, after, made);
			after = made;
		}
		body.beginRow();
		add(body.endRow(IrOpcode.ValueInit, out, 0, where));
		for (index in 0...resultSlots.length) {
			var slot = resultSlots[index],
				leaf = body.newValue("$scalar-closure:result", body.typeId(mapType(slot.type))),
				current = out,
				logical = outType;
			body.beginRow();
			body.pushOperand(references[index]);
			add(body.endRow(IrOpcode.Call, leaf, IrSymbol.of(IrHlScalarRef.LOAD).id, where));
			for (position in 0...slot.path.length - 1) {
				var part = slot.path[position],
					field = fieldOf(logical, part),
					child = body.newValue(part, body.typeId(mapType(field.type)));
				body.beginRow();
				body.pushOperand(current);
				add(body.endRow(IrOpcode.FieldGet, child, IrSymbol.of(part).id, where));
				current = child;
				logical = field.type;
			}
			body.beginRow();
			body.pushOperand(current);
			body.pushOperand(leaf);
			add(body.endRow(IrOpcode.FieldSet, IrValueId.of(-1), IrSymbol.of(slot.path[slot.path.length - 1]).id,
				where));
		}
	}

	/** The digest the adapters of the closure type whose key is `signature` are named by. */
	function suffixOf(signature:String):String {
		var known = suffixes.get(signature);
		if (known == null) {
			known = compiler.core.TextDigest.sha256(signature).substr(0, 32);
			suffixes.set(signature, known);
		}
		return known;
	}

	/**
	 * The adapter `name`, which `make` makes from the closure type the name digests: derived (`IrFunctionStages.derived`), so a
	 * session keeps it while the ABIs and inline enums it read hold. What it adds to the program besides itself (objects, natives,
	 * the adapters it calls) is added by its caller, every run.
	 */
	function helper(name:String, make:compiler.ir.reuse.IrFactReader->IrFunction):IrFunction {
		var known = lineage;
		return compiler.ir.pipeline.IrFunctionStages.derived(STAGE, name, this,
			compiler.ir.pipeline.IrFunctionStages.FROM_NAME, known, known != null && known.checks, types,
			scratch.bodyBuilder, make);
	}

	static function callableOf(type:IrType):IrType
		return switch type {
			case Nullable(inner): inner;
			default: type;
		};

	function signatureCheckName(type:IrType):String
		return "$scalar-closure:signature-check:" + suffixOf(key(callableOf(type)));

	function erasureName(type:IrType):String
		return switch type {
			case Nullable(_): "$scalar-closure:erase-nullable:" + suffixOf(key(type));
			default: "$scalar-closure:erase:" + suffixOf(key(type));
		};

	function restorationName(type:IrType):String
		return switch type {
			case Nullable(_): "$scalar-closure:restore-nullable:" + suffixOf(key(type));
			default: "$scalar-closure:restore:" + suffixOf(key(type));
		};

	static function logicalOf(type:IrType, what:String):{arguments:Array<IrType>, result:IrType} {
		switch type {
			case Function(arguments, result):
				return {arguments: arguments, result: result};
			default:
				throw new InternalError('Scalar closure $what requires a function');
		}
	}

	/** The closure type a receiver query compares with: `type` taking the environment `environment` first. */
	static function probeOf(type:IrType, environment:String, what:String):IrType
		return switch type {
			case Function(args, result): Function([Obj(environment)].concat(args), result);
			default: throw new InternalError('Expected $what closure');
		};

	/** A scalar closure escapes through a signature-specific adapter; only that target proves its original type. */
	function ensureSignatureCheck(type:IrType):String {
		var callable = callableOf(type), signatureKey = key(callable), existing = signatureChecks.get(signatureKey);
		if (existing != null)
			return existing;
		var suffix = suffixOf(signatureKey),
			name = "$scalar-closure:signature-check:" + suffix,
			environment = "$scalar-closure:environment:" + suffix,
			wrapper = "$scalar-closure:erased-call:" + suffix;
		signatureChecks.set(signatureKey, name);
		ensureErasure(callable);
		var probeType = probeOf(erasedType(callable), environment, "erased"),
			query = receiverQuery("$scalar-closure:receiver:signature:" + suffix, Dyn, probeType);
		generatedMakers.push(helper(name, reader -> {
			var b = new IrBuilder(),
				closure = b.argument("closure", Dyn),
				probe = b.staticClosure(wrapper, probeType),
				found = b.call(query, [closure, probe], Dyn);
			b.returnValue(b.equal(b.equal(found, b.constNull(Dyn)), b.constBool(false)));
			new IrFunction(name, b.arguments, Bool, b.blocks, GeneratedHelper);
		}));
		return name;
	}

	/** Materialize a boxed closure only at a real Dynamic escape, keeping null and ordinary typed calls unchanged. */
	function ensureErasure(type:IrType):{maker:String, environment:String} {
		var signature = key(type), existing = erasures.get(signature);
		if (existing != null)
			return existing;
		switch type {
			case Nullable(inner):
				if (!(switch inner {
					case Function(_, _): true;
					default: false;
				}))
					throw new InternalError("Nullable scalar closure erasure requires a function");
				var innerErasure = ensureErasure(inner),
					maker = "$scalar-closure:erase-nullable:" + suffixOf(signature),
					result = {
						maker: maker,
						environment: innerErasure.environment
					};
				erasures.set(signature, result);
				generatedMakers.push(helper(maker, reader -> {
					var outputType = erasedType(type),
						b = new IrBuilder(),
						source = b.argument("closure", type),
						absent = b.createBlock(),
						present = b.createBlock();
					b.branch(b.equal(source, b.constNull(type)), absent, present);
					b.select(absent);
					b.returnValue(b.constNull(outputType));
					b.select(present);
					b.returnValue(b.safeCast(b.call(innerErasure.maker, [b.safeCast(source, inner)], erasedType(inner)),
						outputType));
					new IrFunction(maker, b.arguments, outputType, b.blocks, GeneratedHelper);
				}));
				return result;
			case Function(_, _):
			default:
				throw new InternalError("Scalar closure erasure requires a function");
		}
		var suffix = suffixOf(signature),
			environment = "$scalar-closure:environment:" + suffix,
			maker = "$scalar-closure:erase:" + suffix,
			result = {
				maker: maker,
				environment: environment
			};
		erasures.set(signature, result);
		ensureRestoration(type);
		erasedCalls.push(type);
		generatedObjects.push({
			name: environment,
			isValue: false,
			base: null,
			interfaces: [],
			fields: [{name: "closure", type: mapType(type)}],
			methods: []
		});
		var restoredEnvironment = "$scalar-closure:restored-environment:" + suffix,
			restoredWrapper = IrScalarArguments.PREFIX + "$scalar-closure:restored-call:" + suffix,
			query = receiverQuery("$scalar-closure:receiver:typed:" + suffix, mapType(type),
				probeOf(mapType(type), restoredEnvironment, "scalar"));
		generatedMakers.push(helper(maker, reader -> {
			readTypeKeys(type, reader);
			var physical = mapType(type),
				make = new IrBuilder(),
				source = make.argument("closure", physical),
				missing = make.createBlock(),
				present = make.createBlock();
			make.branch(make.equal(source, make.constNull(physical)), missing, present);
			make.select(missing);
			make.returnValue(make.constNull(erasedType(type)));
			make.select(present);
			var probe = make.staticClosure(restoredWrapper, probeOf(physical, restoredEnvironment, "scalar")),
				found = make.call(query, [source, probe], Dyn),
				allocate = make.createBlock(),
				unwrap = make.createBlock();
			make.branch(make.equal(found, make.constNull(Dyn)), allocate, unwrap);
			make.select(unwrap);
			make.returnValue(make.fieldGet(make.safeCast(found, Obj(restoredEnvironment)), "closure",
				erasedType(type)));
			make.select(allocate);
			var captured = make.newObject(environment);
			make.fieldSet(captured, "closure", source);
			make.returnValue(make.instanceClosure("$scalar-closure:erased-call:" + suffix, captured,
				erasedType(type)));
			new IrFunction(maker, make.arguments, erasedType(type), make.blocks, GeneratedHelper);
		}));
		return result;
	}

	/** The erased-call adapter of the closure type `type`: it takes its arguments as `Dyn`, rewritten to the type's ABI. */
	function erasedCall(type:IrType):IrFunction {
		var suffix = suffixOf(key(type)),
			wrapper = "$scalar-closure:erased-call:" + suffix,
			environment = "$scalar-closure:environment:" + suffix;
		return helper(wrapper, reader -> {
			readTypeKeys(type, reader);
			var logical = logicalOf(type, "erasure"),
				body = new IrBuilder(),
				receiver = body.argument("receiver", Obj(environment)),
				arguments = [for (index in 0...logical.arguments.length) body.argument('argument$index', Dyn)],
				adapted = [for (index in 0...logical.arguments.length)
					(switch (logical.arguments[index]) {
						case Dyn: true;
						default: false;
					})
						? arguments[index] : fromDynamic(body, arguments[index], logical.arguments[index], reader)],
						closure = body.fieldGet(receiver, "closure", type),
						call = body.callClosure(closure, adapted, logical.result);
			body.returnValue((switch (logical.result) {
				case Void: true;
				default: false;
			}) ? body.constNull(Dyn) : (switch (logical.result) {
				case Dyn: true;
				default: false;
			}) ? call : toDynamic(body, call, logical.result, reader));
			var fn = new IrFunction(wrapper, body.arguments, Dyn, body.blocks, GeneratedHelper);
			rewriteFunction(fn, bodyOf(fn), reader);
		});
	}

	function receiverQuery(name:String, first:IrType, second:IrType):String {
		if (!Lambda.exists(program.natives, native -> native.name == name))
			program.natives.push({
				name: name,
				library: "haxeon_runtime",
				symbol: "__closure_receiver_if_match",
				arguments: [first, second],
				result: Dyn
			});
		return name;
	}

	function erasedType(type:IrType):IrType
		return switch type {
			case Function(arguments, _): Function([for (_ in arguments) Dyn], Dyn);
			case Nullable(inner): Nullable(erasedType(inner));
			default: throw new InternalError("Scalar closure erasure requires a function");
		};

	/** A function arriving from Dynamic keeps its boxed ABI behind one scalar-call adapter. */
	function ensureRestoration(type:IrType):String {
		var signatureKey = key(type),
			existing = restorations.get(signatureKey);
		if (existing != null)
			return existing;
		switch type {
			case Nullable(inner):
				if (!(switch inner {
					case Function(_, _): true;
					default: false;
				}))
					throw new InternalError("Nullable scalar closure restoration requires a function");
				var innerMaker = ensureRestoration(inner),
					maker = "$scalar-closure:restore-nullable:" + suffixOf(signatureKey);
				restorations.set(signatureKey, maker);
				generatedMakers.push(helper(maker, reader -> {
					var b = new IrBuilder(),
						original = b.argument("closure", Dyn),
						missing = b.createBlock(),
						present = b.createBlock();
					b.branch(b.equal(original, b.constNull(Dyn)), missing, present);
					b.select(missing);
					b.returnValue(b.constNull(type));
					b.select(present);
					b.returnValue(b.safeCast(b.call(innerMaker, [original], inner), type));
					new IrFunction(maker, b.arguments, type, b.blocks, GeneratedHelper);
				}));
				return maker;
			case Function(_, _):
			default:
				throw new InternalError("Scalar closure restoration requires a function");
		}
		var suffix = suffixOf(signatureKey),
			environment = "$scalar-closure:restored-environment:" + suffix,
			wrapper = IrScalarArguments.PREFIX + "$scalar-closure:restored-call:" + suffix,
			maker = "$scalar-closure:restore:" + suffix,
			logical = logicalOf(type, "restoration");
		restorations.set(signatureKey, maker);
		ensureErasure(type);
		generatedObjects.push({
			name: environment,
			isValue: false,
			base: null,
			interfaces: [],
			fields: [{name: "closure", type: erasedType(type)}],
			methods: []
		});
		// The adapters the restored call passes its arguments and result through.
		for (argument in logical.arguments)
			if (needsBoundaryAdapter(argument))
				ensureErasure(argument);
		if (needsBoundaryAdapter(logical.result))
			ensureRestoration(logical.result);
		generatedMakers.push(helper(wrapper, reader -> restoredCall(type, wrapper, environment, reader)));
		var erasedEnvironment = "$scalar-closure:environment:" + suffix,
			erasedWrapper = "$scalar-closure:erased-call:" + suffix,
			probeType = probeOf(erasedType(type), erasedEnvironment, "erased"),
			query = receiverQuery("$scalar-closure:receiver:erased:" + suffix, Dyn, probeType);
		generatedMakers.push(helper(maker, reader -> {
			readTypeKeys(type, reader);
			var make = new IrBuilder(),
				boxed = make.argument("closure", Dyn),
				missing = make.createBlock(),
				present = make.createBlock(),
				physical = mapType(type);
			make.branch(make.equal(boxed, make.constNull(Dyn)), missing, present);
			make.select(missing);
			make.returnValue(make.constNull(physical));
			make.select(present);
			var probe = make.staticClosure(erasedWrapper, probeType),
				found = make.call(query, [boxed, probe], Dyn),
				allocate = make.createBlock(),
				unwrap = make.createBlock();
			make.branch(make.equal(found, make.constNull(Dyn)), allocate, unwrap);
			make.select(unwrap);
			make.returnValue(make.fieldGet(make.safeCast(found, Obj(erasedEnvironment)), "closure", physical));
			make.select(allocate);
			var decoded = make.safeCast(boxed, erasedType(type)),
				captured = make.newObject(environment);
			make.fieldSet(captured, "closure", decoded);
			make.returnValue(make.instanceClosure(wrapper, captured, physical));
			new IrFunction(maker, make.arguments, physical, make.blocks, GeneratedHelper);
		}));
		return maker;
	}

	/** The restored-call adapter of the closure type `type`: the scalar ABI's call, made on the boxed closure it holds. */
	function restoredCall(type:IrType, wrapper:String, environment:String,
			reader:compiler.ir.reuse.IrFactReader):IrFunction {
		readTypeKeys(type, reader);
		var scalarOwn = candidates.exists(key(type)),
			logical = logicalOf(type, "restoration"),
			call = new IrBuilder(),
			receiver = call.argument("receiver", Obj(environment)),
			arguments:Array<IrValue> = [];
		for (index in 0...logical.arguments.length) {
			var argument = logical.arguments[index];
			if (!scalarOwn || !isValue(argument)) {
				arguments.push(call.argument('argument$index', mapType(argument)));
				continue;
			}
			var name = switch argument {
				case Obj(value): value;
				default: throw new InternalError("Invalid scalar closure argument");
			}, record = call.valueInit(name);
			for (slot in slots(argument)) {
				var scalar = call.argument('argument$index.' + slot.path.join("."), mapType(slot.type)),
					current = record,
					currentType = argument;
				for (position in 0...slot.path.length - 1) {
					var part = slot.path[position],
						field = fieldOf(currentType, part);
					current = call.fieldGet(current, part, mapType(field.type));
					currentType = field.type;
				}
				call.fieldSet(current, slot.path[slot.path.length - 1], scalar);
			}
			arguments.push(record);
		}
		var resultSlots = scalarOwn && isValue(logical.result) ? slots(logical.result) : [],
			references:Array<IrValue> = [];
		for (slot in resultSlots)
			references.push(call.argument("result." + slot.path.join("."), IrHlScalarRef.type(mapType(slot.type))));
		var closure = call.fieldGet(receiver, "closure", erasedType(type)),
			erasedArguments = [for (index in 0...arguments.length) {
				var argument = arguments[index], logicalType = logical.arguments[index];
				if (needsBoundaryAdapter(logicalType)) {
					var erased = call.call(erasureName(logicalType), [argument], erasedType(logicalType));
					call.toDyn(erased);
				} else (switch (argument.type) {
					case Dyn: true;
					default: false;
				}) ? argument : toDynamic(call, argument, logicalType, reader);
			}],
				erasedResult = call.callClosure(closure, erasedArguments, Dyn),
				result = (switch (logical.result) {
			case Void: true;
			default: false;
		}) ? call.constVoid() : (switch (logical.result) {
			case Dyn: true;
			default: false;
		}) ? erasedResult : needsBoundaryAdapter(logical.result) ? call.call(restorationName(logical.result),
			[erasedResult],
			mapType(logical.result)) : fromDynamic(call, erasedResult, logical.result, reader);
		if (resultSlots.length == 0)
			call.returnValue(result);
		else {
			for (index in 0...resultSlots.length) {
				var slot = resultSlots[index],
					current = result,
					currentType = logical.result;
				for (part in slot.path) {
					var field = fieldOf(currentType, part);
					current = call.fieldGet(current, part, mapType(field.type));
					currentType = field.type;
				}
				call.call(IrHlScalarRef.STORE, [references[index], current], Void);
			}
			call.returnValue(call.constVoid());
		}
		return new IrFunction(wrapper, call.arguments, resultSlots.length == 0 ? mapType(logical.result) : Void,
			call.blocks, ScalarArguments);
	}

	function isValue(type:IrType):Bool
		return switch type {
			case Obj(name):
				var object = objects.get(name);
				object != null && object.isValue;
			default: false;
		};

	function slots(type:IrType):Array<IrInlineValueSlot>
		return layouts.slots(type);

	function fieldOf(type:IrType, name:String):IrObjectField {
		var objectName = switch type {
			case Obj(value): value;
			default: throw new InternalError("Invalid scalar closure field owner");
		}, object = objects.get(objectName);
		if (object != null)
			for (field in object.fields)
				if (field.name == name)
					return field;
		throw new InternalError('Missing scalar closure field $objectName.$name');
	}

	public static function functionType(type:IrType):Null<IrType>
		return switch type {
			case Function(_, _): type;
			case Nullable(inner): switch inner {
					case Function(_, _): inner;
					default: null;
				};
			default: null;
		};

	static function key(type:IrType):String
		return IrTypeIdentity.text(type);
}

/**
 * What one function's rows do with closures, for the scalar closure ABI's choice (`IrScalarClosures.prepare`), by type ids of the
 * body's table: the types it notes as candidates (`NOTE`: closures it calls, turns `Dyn` or takes back from `Dyn`), the types it
 * excludes with what they nest (`EXCLUDE`), and the closures it makes of functions by name (`STATIC`, `INSTANCE` with the
 * receiver's type), whose candidacy depends on the program. It depends on the body alone, so a session keeps it by the function's
 * version (`IrStageMemos.closureUses`).
 */
@:nullSafety(Strict)
class IrClosureUses {
	public static inline final NOTE = 0;
	public static inline final EXCLUDE = 1;
	public static inline final STATIC = 2;
	public static inline final INSTANCE = 3;

	/** Entries: kind, type id, then for `STATIC` a name's index in `names`, for `INSTANCE` that and the receiver's type id. */
	public final events:Array<Int> = [];

	public final names:Array<String> = [];

	/** The record of a function that does nothing with closures, shared. */
	@:processWide("an empty record, only ever read")
	static final NONE = new IrClosureUses();

	function new() {}

	public static function of(fn:IrFunction, types:IrTypeIds, scratch:IrPassScratch, useCounts:Array<Int>,
			lineage:Null<compiler.ir.reuse.IrStageMemo.IrLineage>):IrClosureUses {
		var version = lineage == null ? 0 : lineage.versionOf(fn);
		if (lineage == null || version == 0)
			return read(fn.bodyIn(types, scratch.bodyBuilder), useCounts);
		var memo = lineage.memos.contribution(IrScalarClosures.USES), known = memo.get(version);
		if (known == null) {
			known = read(fn.bodyIn(types, scratch.bodyBuilder), useCounts);
			memo.keep(version, known);
		} else if (lineage.checks) {
			var now = read(fn.bodyIn(types, scratch.bodyBuilder), useCounts);
			if (now.events.join(",") != known.events.join(",") || now.names.join(",") != known.names.join(","))
				throw new InternalError('--check-reuse: the closure uses reused for ${fn.name} differ from its body');
		}
		return known;
	}

	function event(kind:Int, type:Int):Void {
		events.push(kind);
		events.push(type);
	}

	function named(name:String):Int {
		var index = names.indexOf(name);
		if (index < 0) {
			index = names.length;
			names.push(name);
		}
		return index;
	}

	static function read(body:IrBody, useCounts:Array<Int>):IrClosureUses {
		var uses = new IrClosureUses(), types = body.types;
		// Most functions make no signature query, and need no map of them.
		var signatureQueries:Null<Map<Int, Bool>> = null,
			counts = IrPassScratch.filledInts(useCounts, body.valueLimit(), 0);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				for (input in 0...body.operandCount(row))
					counts[body.operand(row, input)]++;
				if (body.opcode(row) == IrOpcode.Call && body.operandCount(row) == 2
					&& body.symbol(row).name == "__closure_is_of_type") {
					if (signatureQueries == null)
						signatureQueries = [];
					signatureQueries.set(body.operand(row, 1), true);
				}
				row = body.nextRow(row);
			}
		}
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.StaticClosure:
						uses.event(STATIC, body.valueTypeId(body.output(row)));
						uses.events.push(uses.named(body.symbol(row).name));
					case IrOpcode.InstanceClosure:
						uses.event(INSTANCE, body.valueTypeId(body.output(row)));
						uses.events.push(uses.named(body.symbol(row).name));
						uses.events.push(body.valueTypeId(body.operand(row, 0)));
					case IrOpcode.CallClosure:
						uses.event(NOTE, body.valueTypeId(body.operand(row, 0)));
					case IrOpcode.ToDyn:
						var input = body.valueType(body.operand(row, 0)),
							callable = IrScalarClosures.functionType(input);
						if (callable != null)
							uses.event(NOTE, types.id(callable));
						else
							uses.event(EXCLUDE, body.valueTypeId(body.operand(row, 0)));
					case IrOpcode.SafeCast:
						var output = body.valueType(body.output(row)),
							input = body.valueType(body.operand(row, 0)),
							callable = IrScalarClosures.functionType(output);
						if (callable != null && (switch (input) {
							case Dyn: true;
							default: false;
						}))
							uses.event(NOTE, types.id(callable));
						else
							uses.event(EXCLUDE, body.valueTypeId(body.output(row)));
						uses.event(EXCLUDE, body.valueTypeId(body.operand(row, 0)));
					case IrOpcode.TypeValue:
						var out:Int = body.output(row);
						if (signatureQueries == null || !signatureQueries.exists(out) || out >= counts.length
							|| counts[out] != 1)
							uses.event(EXCLUDE, body.aux(row));
					default:
				}
				row = body.nextRow(row);
			}
		}
		return uses.events.length == 0 ? NONE : uses;
	}
}

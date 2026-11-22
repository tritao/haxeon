package compiler.ir.passes.enums;

import compiler.core.InternalError;
import compiler.core.Provides.ProviderOperation;
import compiler.core.Provides.ProviderOperations;
import compiler.ir.gen.IrGenerator;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrObjectTable;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrSymbol;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.TypeKey;
import compiler.ir.passes.objects.IrTypedInterfaceDispatch;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.passes.values.IrValueLaneReference;

/**
 * Select one program-wide representation, then lower eligible enum values to their lane packets. On IR bodies
 * (docs/design/IR_CORE_COLUMNS.md, migration): a function that mentions a selected enum is edited in place, on a copy when a cache
 * holds its body; the helpers, dispatchers and escape adapters it adds are built as functions and encoded.
 */
class IrInlineEnumLowering {
	final planner:IrInlineEnumLayout;
	final eligibility:IrInlineEnumEligibility;
	final types:IrTypeIds;
	final helper:(name:String, enumName:String, constructor:Int, field:Int) -> String;
	final values:Map<String, Bool>;
	final contracts:Map<String, Bool>;
	final mapped:IrType->IrType;
	final containsMapped:IrType->Bool;
	final nulls:Map<Int, Bool> = [];

	/** By type id: 1 when the type contains a selected enum, 0 when not, -1 not known yet. */
	final mentions:Array<Int> = [];

	/** By type id: the id of the type with its selected enums as their value packets, or -1 not known yet. */
	final mappedIds:Array<Int> = [];

	function new(planner:IrInlineEnumLayout, eligibility:IrInlineEnumEligibility, types:IrTypeIds,
			helper:(name:String, enumName:String, constructor:Int, field:Int) -> String, values:Map<String, Bool>,
			contracts:Map<String, Bool>, mapped:IrType->IrType, containsMapped:IrType->Bool) {
		this.planner = planner;
		this.eligibility = eligibility;
		this.types = types;
		this.helper = helper;
		this.values = values;
		this.contracts = contracts;
		this.mapped = mapped;
		this.containsMapped = containsMapped;
	}

	/**
	 * `program` with its selected enums lowered, reading the functions' bodies made with `types` (those of the functions' bodies
	 * when not given) and encoding a function that has none; a function it changes or makes is owned by the next
	 * stage.
	 */
	public static function run(program:IrProgram, target:IrValueLaneTarget, canonicalObjects:Array<IrObject>,
			?reflectableObjects:Array<String>, ?types:IrTypeIds, ?builder:IrBodyBuilder,
			?lineage:compiler.ir.reuse.IrStageMemo.IrLineage):IrProgram {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		var planner = new IrInlineEnumLayout(program.enums, program.objects, target == HashLink ? 64 : 32, target,
			canonicalObjects);
		var eligibility = new IrInlineEnumEligibility(program, planner, reflectableObjects, types, builder, lineage);
		if (!eligibility.allowed.keys().hasNext())
			return program;
		planner = new IrInlineEnumLayout(program.enums, program.objects, target == HashLink ? 64 : 32, target,
			canonicalObjects, false, eligibility.allowed);
		function storage(name:String):compiler.ir.passes.enums.IrInlineEnumLayout.IrInlineEnumShape {
			var shape = planner.shape(name);
			if (shape == null)
				throw new InternalError('Missing selected inline enum storage "$name"');
			return shape;
		}
		var selectedStorage:Map<String, String> = [];
		for (entry in program.enums)
			if (eligibility.allowed.exists(entry.name))
				selectedStorage.set(entry.name, storage(entry.name).valueObject.name);
		function containsMapped(type:IrType):Bool
			return switch type {
				case Enum(name): planner.shape(name) != null;
				case Array(inner), Iterator(inner), Nullable(inner): containsMapped(inner);
				case Function(arguments, result): Lambda.exists(arguments, containsMapped) || containsMapped(result);
				default: false;
			};
		function mapped(type:IrType):IrType
			return switch type {
				case Enum(name):
					var shape = planner.shape(name);
					shape == null ? type : Obj(shape.valueObject.name);
				case Array(_), Iterator(_): type;
				case Function(arguments, result): Function([for (argument in arguments) mapped(argument)],
					mapped(result));
				case Nullable(inner): Nullable(mapped(inner));
				default: type;
			};
		var result = new IrProgram(program.entryPoint);
		result.enums = [for (entry in program.enums)
			{
				name:entry.name,
					cases:entry.cases,
					isRecursive:entry.isRecursive,
					inlineStorage:selectedStorage.get(entry.name)
			}];
		result.natives = program.natives.copy();
		result.cNatives = program.cNatives;
		result.positionalFingerprints = program.positionalFingerprints;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		result.parameterDefaults = program.parameterDefaults;
		result.interfaces = [for (entry in program.interfaces)
			{
				name:entry.name,
					bases:entry.bases,
					methods:[for (method in entry.methods)
					{
						name:method.name,
							arguments:[for (argument in method.arguments) mapped(argument)],
							result:mapped(method.result)
					}]
			}];
		result.staticFields = [];
		for (field in program.staticFields)
			switch field.type {
				case Enum(name) if (planner.shape(name) != null):
					for (leaf in storage(name).valueObject.fields)
						result.staticFields.push({
							name: globalLeaf(field.name, leaf.name),
							type: IrValueLaneReference.isCarrier(leaf.type) ? Dyn : leaf.type
						});
				default:
					result.staticFields.push({name: field.name, type: mapped(field.type)});
			}
		var rewrittenObjects:Array<IrObject> = [for (object in program.objects)
			{
				name:object.name,
					isValue:object.isValue,
					nativeLayout:object.nativeLayout,
					base:object.base,
					interfaces:object.interfaces,
					methods:object.methods,
					fields:[for (field in object.fields)
					{
						name:field.name,
							type:mapped(field.type),
							nativeLayout:field.nativeLayout,
							scalarStorage:field.scalarStorage,
							nullableScalarStorage:field.nullableScalarStorage
					}]
			}];
		result.objects = rewrittenObjects.concat(planner.generatedObjects());
		var table = IrObjectTable.of([for (object in result.objects) object.name => object]);
		var helpers:Map<String, IrFunction> = [];
		function helper(name:String, enumName:String, constructor:Int, field:Int):String {
			if (helpers.exists(name))
				return name;
			var shape = storage(enumName),
				access = new IrInlineEnumCaseAccess(shape, table),
				b = new IrBuilder();
			var value:IrValue;
			if (constructor == -2)
				value = access.nullValue(b);
			else if (field == -1)
				value = access.construct(b, constructor, [
					for (index in 0...shape.cases[constructor].parameters.length)
						b.argument('p$index', shape.cases[constructor].parameters[index])
				]);
			else {
				var input = b.argument('value', Obj(shape.valueObject.name));
				if (field == -3)
					value = b.equal(b.fieldGet(input, "tag", I32), b.constInt(0));
				else if (field == -2) {
					var tag = b.fieldGet(input, 'tag', I32),
						missing = b.createBlock(),
						present = b.createBlock();
					b.branch(b.equal(tag, b.constInt(0)), missing, present);
					b.select(missing);
					b.throwValue(b.toDyn(b.constString('Null access')));
					b.select(present);
					value = b.sub(tag, b.constInt(1));
				} else
					value = access.field(b, input, constructor, field);
			}
			b.returnValue(value);
			helpers.set(name,
				new IrFunction(name, b.arguments, value.type, b.blocks,
				Provider(TypeKey.of(Enum(enumName)),
				ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, name))));
			return name;
		}
		var lowering = new IrInlineEnumLowering(planner, eligibility, types, helper,
			[for (object in result.objects) if (object.isValue) object.name => true],
			[for (entry in result.interfaces) entry.name => true], mapped, containsMapped);
		for (fn in program.functions)
			result.functions.push(lowering.lower(fn, fn.bodyIn(types, builder), builder));
		var names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names)
			result.functions.push(helpers.get(name));
		// The functions lowered here call their typed dispatchers already (`lower`); the others did before.
		IrTypedInterfaceDispatch.generate(result.functions, result.objects, result.interfaces);
		// Lane-array reflection bridges use the logical enum adapter even when this source has no escape.
		result.functions = result.functions.concat(IrInlineEnumEscapes.functions(result.enums, table, planner));
		var calls:Map<String, Bool> = [];
		for (fn in result.functions) {
			var body = fn.bodyIn(types, builder);
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					if (body.opcode(row) == IrOpcode.Call)
						calls.set(body.symbol(row).name, true);
					row = body.nextRow(row);
				}
			}
		}
		var existing = [for (native in result.natives) native.name => true];
		for (native in IrInlineEnumWordAccess.natives())
			if (native.name != "haxe.Int64.toInt" && calls.exists(native.name) && !existing.exists(native.name))
				result.natives.push(native);
		return result;
	}

	static function globalLeaf(name:String, field:String):String
		return "$inline-enum-global:" + name.length + ":" + name + ":" + field;

	/** `fn` (whose body is `body`) lowered: itself when no position of it mentions a selected enum. */
	function lower(fn:IrFunction, body:IrBody, builder:Null<IrBodyBuilder>):IrFunction {
		if (!mentionsSelected(body))
			return fn;
		var edited = body.forEditing(builder);
		rewrite(edited);
		return IrFunction.ofOwnedBody(edited);
	}

	function mentionsId(id:Int):Bool {
		if (id >= mentions.length) {
			var from = mentions.length;
			mentions.resize(id + 1);
			for (index in from...id + 1)
				mentions[index] = -1;
		}
		if (mentions[id] < 0)
			mentions[id] = containsMapped(types.type(id)) ? 1 : 0;
		return mentions[id] == 1;
	}

	inline function mentionsValue(body:IrBody, value:IrValueId):Bool
		return mentionsId(body.valueTypeId(value));

	function mappedId(id:Int):Int {
		if (id >= mappedIds.length) {
			var from = mappedIds.length;
			mappedIds.resize(id + 1);
			for (index in from...id + 1)
				mappedIds[index] = -1;
		}
		if (mappedIds[id] < 0)
			mappedIds[id] = mentionsId(id) ? types.id(mapped(types.type(id))) : id;
		return mappedIds[id];
	}

	/** Whether a position the function names holds a type with a selected enum: its arguments, result, bindings, rows and descriptors. */
	function mentionsSelected(body:IrBody):Bool {
		if (mentionsId(body.result))
			return true;
		for (index in 0...body.argumentCount())
			if (mentionsValue(body, body.argument(index)))
				return true;
		for (index in 0...body.bindingCount())
			if (mentionsValue(body, body.bindingValue(index)))
				return true;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var out = body.output(row);
				if (out.exists() && mentionsValue(body, out))
					return true;
				for (index in 0...body.operandCount(row))
					if (mentionsValue(body, body.operand(row, index)))
						return true;
				if (body.opcode(row) == IrOpcode.TypeValue && mentionsId(body.aux(row)))
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	function storage(name:String):compiler.ir.passes.enums.IrInlineEnumLayout.IrInlineEnumShape {
		var shape = planner.shape(name);
		if (shape == null)
			throw new InternalError('Missing selected inline enum storage "$name"');
		return shape;
	}

	inline function selected(type:IrType):Null<String>
		return switch type {
			case Enum(name) if (planner.shape(name) != null): name;
			default: null;
		};

	/**
	 * Lowers `body` in place. The rows are read with their types as they were, which change last.
	 */
	function rewrite(body:IrBody):Void {
		var limit = body.valueLimit(), name = body.name;
		nulls.clear();
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.ConstNull)
					nulls.set(body.output(row), true);
				row = body.nextRow(row);
			}
		}
		inline function fresh(type:IrType):IrValueId
			return body.newValue("$enum-value-load", body.typeId(type));
		function link(block:Int, before:Int, opcode:IrOpcode, output:IrValueId, aux:Int,
				provenance:SourceProvenance):Int {
			var row = body.endRow(opcode, output, aux, provenance);
			body.linkBefore(block, before, row);
			return row;
		}
		function symbol(name:String):Int
			return IrSymbol.of(name).id;
		var none = IrValueId.of(-1);
		// A copy of a value packet read from `raw` into `output`, before `before`; each row reading `raw` is listed in `reads`,
		// followed by `raw`.
		function copyLoad(block:Int, before:Int, output:IrValueId, raw:IrValueId, enumName:String,
				provenance:SourceProvenance, ?reads:Array<Int>):Void {
			var shape = storage(enumName),
				origin = new SourceProvenance(provenance.location, CompilerGenerated(IrGenerator.ValueCopyReason));
			body.beginRow();
			link(block, before, IrOpcode.ValueInit, output, 0, origin);
			for (field in shape.valueObject.fields) {
				var leaf = fresh(field.type);
				body.beginRow();
				body.pushOperand(raw);
				var read = link(block, before, IrOpcode.FieldGet, leaf, symbol(field.name), origin);
				if (reads != null) {
					reads.push(read);
					reads.push(raw);
				}
				body.beginRow();
				body.pushOperand(output);
				body.pushOperand(leaf);
				link(block, before, IrOpcode.FieldSet, none, symbol(field.name), origin);
			}
		}
		// Mirror the frontend's existing struct parameter copies after making enum parameters physical values: every read of
		// such an argument reads its copy, made at the start of the first block.
		var start = body.blockCount() > 0 ? body.firstRow(0) : -1, argumentReads:Null<Array<Int>> = null;
		for (index in 0...body.argumentCount()) {
			var argument = body.argument(index), enumName = selected(body.valueType(argument));
			if (enumName == null)
				continue;
			if (argumentReads == null)
				argumentReads = [];
			var copied = fresh(mapped(body.valueType(argument)));
			body.alias(argument, copied);
			copyLoad(0, start, copied, argument, enumName, SourceProvenance.generated(IrGenerator.ValueCopyReason),
				argumentReads);
		}
		var callable = eligibility.callableDescriptors.get(name);
		for (block in 0...body.blockCount()) {
			var row = block == 0 ? start : body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row), opcode = body.opcode(row), out = body.output(row);
				switch opcode {
					case IrOpcode.FieldGet:
						var enumName = selected(body.valueType(out));
						if (enumName != null) {
							var raw = fresh(mapped(body.valueType(out)));
							body.beginRow();
							body.pushOperand(body.operand(row, 0));
							link(block, row, IrOpcode.FieldGet, raw, body.aux(row), body.provenance(row));
							copyLoad(block, row, out, raw, enumName, body.provenance(row));
							body.removeRow(block, row);
						}
					case IrOpcode.GlobalGet:
						var enumName = selected(body.valueType(out));
						if (enumName != null) {
							var global = body.symbol(row).name,
								origin = new SourceProvenance(body.provenance(row).location,
									CompilerGenerated(IrGenerator.ValueCopyReason));
							body.beginRow();
							link(block, row, IrOpcode.ValueInit, out, 0, origin);
							for (field in storage(enumName).valueObject.fields) {
								var leaf = fresh(field.type);
								if (IrValueLaneReference.isCarrier(field.type)) {
									var raw = fresh(Dyn);
									body.beginRow();
									link(block, row, IrOpcode.GlobalGet, raw, symbol(globalLeaf(global, field.name)),
										origin);
									body.beginRow();
									body.pushOperand(raw);
									link(block, row, IrOpcode.Call, leaf, symbol(IrValueLaneReference.PACK), origin);
								} else {
									body.beginRow();
									link(block, row, IrOpcode.GlobalGet, leaf, symbol(globalLeaf(global, field.name)),
										origin);
								}
								body.beginRow();
								body.pushOperand(out);
								body.pushOperand(leaf);
								link(block, row, IrOpcode.FieldSet, none, symbol(field.name), origin);
							}
							body.removeRow(block, row);
						}
					case IrOpcode.GlobalSet:
						var value = body.operand(row, 0), enumName = selected(body.valueType(value));
						if (enumName != null) {
							var global = body.symbol(row).name,
								provenance = body.provenance(row),
								leaves:Array<Int> = [];
							for (field in storage(enumName).valueObject.fields) {
								var leaf = fresh(field.type);
								body.beginRow();
								body.pushOperand(value);
								link(block, row, IrOpcode.FieldGet, leaf, symbol(field.name), provenance);
								if (IrValueLaneReference.isCarrier(field.type)) {
									var raw = fresh(Dyn);
									body.beginRow();
									body.pushOperand(leaf);
									link(block, row, IrOpcode.Call, raw, symbol(IrValueLaneReference.UNPACK),
										provenance);
									leaf = raw;
								}
								leaves.push(symbol(globalLeaf(global, field.name)));
								leaves.push(leaf);
							}
							// Snapshot every leaf before publishing any part of the assignment.
							var index = 0;
							while (index < leaves.length) {
								body.beginRow();
								body.pushOperand(IrValueId.of(leaves[index + 1]));
								link(block, row, IrOpcode.GlobalSet, none, leaves[index], provenance);
								index += 2;
							}
							body.removeRow(block, row);
						}
					case IrOpcode.MakeEnum:
						var enumName = body.symbol(row).name, constructor = body.auxInt(row, 1);
						if (planner.shape(enumName) != null)
							body.setOperation(row, IrOpcode.Call,
								symbol(helper(IrInlineEnumCaseAccess.HELPER_PREFIX + 'construct:$enumName:$constructor',
								enumName,
								constructor, -1)));
					case IrOpcode.ConstNull:
						var enumName = selected(body.valueType(out));
						if (enumName != null)
							body.setOperation(row, IrOpcode.Call,
								symbol(helper(IrInlineEnumCaseAccess.HELPER_PREFIX + 'null:$enumName', enumName, -2,
								-1)));
					case IrOpcode.EnumField:
						var enumName = selected(body.valueType(body.operand(row, 0)));
						if (enumName != null) {
							var constructor = body.auxInt(row, 0), field = body.auxInt(row, 1);
							body.setOperation(row, IrOpcode.Call,
								symbol(helper(IrInlineEnumCaseAccess.HELPER_PREFIX
								+ 'field:$enumName:$constructor:$field', enumName,
								constructor, field)));
						}
					case IrOpcode.EnumIndex:
						var enumName = selected(body.valueType(body.operand(row, 0)));
						if (enumName != null)
							body.setOperation(row, IrOpcode.Call,
								symbol(helper(IrInlineEnumCaseAccess.HELPER_PREFIX + 'index:$enumName', enumName, -1,
								-2)));
					case IrOpcode.Equal
						if (nulls.exists(body.operand(row, 0)) || nulls.exists(body.operand(row, 1))):
						var operand = nulls.exists(body.operand(row, 0)) ? body.operand(row, 1) : body.operand(row, 0),
							enumName = selected(body.valueType(operand));
						if (enumName != null) {
							body.beginRow();
							body.pushOperand(operand);
							link(block, row, IrOpcode.Call, out,
								symbol(helper(IrInlineEnumCaseAccess.HELPER_PREFIX + "is-null:" + enumName, enumName,
								-1, -3)),
								body.provenance(row));
							body.removeRow(block, row);
						}
					case IrOpcode.ToDyn, IrOpcode.SafeCast, IrOpcode.Equal:
						checkEscape(body, row);
					case IrOpcode.TypeValue:
						if (callable != null && callable.exists(out))
							body.setAux(row, mappedId(body.aux(row)));
					case IrOpcode.Throw:
						if (mentionsValue(body, body.operand(row, 0)))
							throw new InternalError('Unsupported inline enum throw passed eligibility');
					default:
				}
				row = following;
			}
		}
		// The arguments' copies read the arguments themselves.
		body.sweepAliases();
		if (argumentReads != null) {
			var index = 0;
			while (index < argumentReads.length) {
				body.setOperand(argumentReads[index], 0, IrValueId.of(argumentReads[index + 1]));
				index += 2;
			}
		}
		for (value in 0...limit) {
			var id = body.valueTypeId(IrValueId.of(value));
			if (id >= 0 && mappedId(id) != id)
				body.setValueType(IrValueId.of(value), mappedId(id));
		}
		if (mappedId(body.result) != body.result)
			body.setResult(mappedId(body.result));
		IrTypedInterfaceDispatch.rewriteBodyValueCalls(body, values, contracts);
	}

	/** The Dynamic and checked boundaries eligibility let through, which never carry a selected enum unadapted. */
	function checkEscape(body:IrBody, row:Int):Void {
		var opcode = body.opcode(row),
			value = body.valueType(body.operand(row, 0)),
			out = body.valueType(body.output(row));
		inline function container(type:IrType):Bool
			return switch type {
				case Array(_), Iterator(_): true;
				default: false;
			};
		inline function isDyn(type:IrType):Bool
			return switch type {
				case Dyn: true;
				default: false;
			};
		if (opcode == IrOpcode.ToDyn && selected(value) != null)
			throw new InternalError("Eligible enum unexpectedly escapes to Dynamic");
		if (opcode == IrOpcode.SafeCast && selected(out) != null)
			throw new InternalError("Eligible enum unexpectedly enters from Dynamic");
		// Container casts keep their logical descriptor; the shared array pass installs lane storage. The container header is the
		// reference escape; do not box its elements.
		if ((opcode == IrOpcode.SafeCast && container(out)) || (opcode == IrOpcode.ToDyn && container(value)))
			return;
		if (opcode == IrOpcode.Equal)
			switch value {
				case Function(_, _):
					return;
				default:
			}
		// Scalar closure lowering boxes enum arguments only in this Dynamic boundary adapter; the paired closure adapter restores
		// the physical enum packet after its logical signature check.
		if ((opcode == IrOpcode.ToDyn && eligibility.supportsCallableEscape(value))
			|| (opcode == IrOpcode.SafeCast && isDyn(value) && eligibility.supportsCallableEscape(out)))
			return;
		if (containsMapped(value) || containsMapped(out))
			throw new InternalError('Unsupported inline enum escape passed eligibility: row $row of ${body.name}');
	}
}

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
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.model.IrTypeIds;
import compiler.ir.model.IrValueId;
import compiler.ir.model.SourceProvenance;
import compiler.ir.model.TypeKey;
import compiler.ir.passes.objects.IrTypedInterfaceDispatch;
import compiler.ir.passes.values.IrValueLaneLayout.IrValueLaneTarget;
import compiler.ir.passes.values.IrValueLaneReference;
import compiler.ir.pipeline.IrFunctionIndex;
import compiler.ir.pipeline.IrFunctionPass;
import compiler.ir.pipeline.IrFunctionStages;
import compiler.ir.reuse.IrFactReader;
import compiler.ir.reuse.IrStageMemos;

/**
 * Select one program-wide representation, then lower eligible enum values to their lane packets. On IR bodies
 * (docs/design/IR_CORE_COLUMNS.md, migration): a function that mentions a selected enum is edited in place, on a copy when a cache
 * holds its body; the helpers, dispatchers and escape adapters it adds are built as functions and encoded.
 */
@:nullSafety(Strict)
class IrInlineEnumLowering {
	final planner:IrInlineEnumLayout;
	final eligibility:IrInlineEnumEligibility;
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

	function new(planner:IrInlineEnumLayout, eligibility:IrInlineEnumEligibility,
			helper:(name:String, enumName:String, constructor:Int, field:Int) -> String, values:Map<String, Bool>,
			contracts:Map<String, Bool>, mapped:IrType->IrType, containsMapped:IrType->Bool) {
		this.planner = planner;
		this.eligibility = eligibility;
		this.helper = helper;
		this.values = values;
		this.contracts = contracts;
		this.mapped = mapped;
		this.containsMapped = containsMapped;
	}

	/**
	 * `program` with its selected enums lowered, reading the functions' bodies and encoding a function that has none; a function
	 * it changes or makes is owned by the next stage.
	 */
	public static function run(program:IrProgram, target:IrValueLaneTarget, canonicalObjects:Array<IrObject>,
			?reflectableObjects:Array<String>, ?builder:IrBodyBuilder, ?stageMemos:IrStageMemos):IrProgram {
		var planner = new IrInlineEnumLayout(program.enums, program.objects, target == HashLink ? 64 : 32, target,
			canonicalObjects, false, null, stageMemos);
		var eligibility = new IrInlineEnumEligibility(program, planner, reflectableObjects, builder, stageMemos);
		if (!eligibility.allowed.keys().hasNext())
			return program;
		planner = new IrInlineEnumLayout(program.enums, program.objects, target == HashLink ? 64 : 32, target,
			canonicalObjects, false, eligibility.allowed, stageMemos);
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
				name: entry.name,
				cases: entry.cases,
				isRecursive: entry.isRecursive,
				inlineStorage: selectedStorage.get(entry.name)
			}];
		result.natives = program.natives.copy();
		result.cNatives = program.cNatives;
		result.positionalFingerprints = program.positionalFingerprints;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		result.parameterDefaults = program.parameterDefaults;
		result.interfaces = [for (entry in program.interfaces)
			{
				name: entry.name,
				bases: entry.bases,
				methods: [for (method in entry.methods)
					{
						name: method.name,
						arguments: [for (argument in method.arguments) mapped(argument)],
						result: mapped(method.result)
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
				name: object.name,
				isValue: object.isValue,
				nativeLayout: object.nativeLayout,
				base: object.base,
				interfaces: object.interfaces,
				methods: object.methods,
				fields: [for (field in object.fields)
					{
						name: field.name,
						type: mapped(field.type),
						nativeLayout: field.nativeLayout,
						scalarStorage: field.scalarStorage,
						nullableScalarStorage: field.nullableScalarStorage
					}]
			}];
		result.objects = rewrittenObjects.concat(planner.generatedObjects());
		var table = IrObjectTable.of([for (object in result.objects) object.name => object]);
		// The helper `name` for `enumName`'s `constructor` and `field`; negative ones name the null value and tag reads (`lower`).
		function helper(name:String, enumName:String, constructor:Int, field:Int):IrFunction {
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
			return new IrFunction(name, b.arguments, value.type, b.blocks,
				Provider(TypeKey.of(Enum(enumName)),
				ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, name)));
		}
		var pass:Null<IrInlineEnumLoweringPass> = null;
		var lowering = new IrInlineEnumLowering(planner, eligibility, (name, enumName, constructor, field) -> {
			var current = pass;
			if (current != null)
				current.ask(name, enumName, constructor, field);
			return name;
		},
			[for (object in result.objects) if (object.isValue) object.name => true],
			[for (entry in result.interfaces) entry.name => true], mapped, containsMapped);
		// What the lowering of a function and the helpers read of the program besides the enums a function names: the selected
		// enums' declarations and storage, the value objects and the interfaces.
		function layout():String {
			var parts:Array<String> = [];
			for (entry in program.enums)
				if (eligibility.allowed.exists(entry.name)) {
					var shape = storage(entry.name);
					parts.push('enum ${entry.name} ${shape.valueObject.name}');
					for (item in entry.cases)
						parts.push('case ${item.name} '
							+ [for (param in item.params) IrTypeIdentity.text(param)].join(","));
					for (item in shape.cases)
						parts.push('lanes ' + [for (param in item.parameters) IrTypeIdentity.text(param)].join(","));
				}
			parts.push(compiler.ir.passes.values.IrInlineValueLayout.valueDeclarations(result.objects));
			for (entry in result.interfaces)
				parts.push('interface ${entry.name}');
			return parts.join("\n");
		}
		var lowered = new IrInlineEnumLoweringPass(lowering, builder, stageMemos, layout, helper);
		pass = lowered;
		result.functions = IrFunctionStages.run(IrInlineEnumLoweringPass.STAGE, lowered, program.functions, stageMemos,
			builder);
		var made = lowered.helpers();
		// The functions lowered here call their typed dispatchers already (`lower`); the others did before.
		var dispatched = result.functions.length;
		result.functions = result.functions.concat(made);
		IrTypedInterfaceDispatch.generate(result.functions, result.objects, result.interfaces, "inline-enum-lowering",
			stageMemos);
		made = made.concat(result.functions.slice(dispatched + made.length));
		// Lane-array reflection bridges use the logical enum adapter even when this source has no escape.
		var escapes = IrInlineEnumEscapes.functions(result.enums, table, planner, lowered.derive);
		result.functions = result.functions.concat(escapes);
		// The word access natives the functions call: the lowered functions' as their rewrite asked for them, the rest read here.
		for (fn in made.concat(escapes))
			lowered.scanNatives(fn.encodedBody(builder), null);
		var existing = [for (native in result.natives) native.name => true];
		for (native in IrInlineEnumWordAccess.natives())
			if (native.name != "haxe.Int64.toInt" && lowered.called.exists(native.name)
				&& !existing.exists(native.name))
				result.natives.push(native);
		return result;
	}

	static function globalLeaf(name:String, field:String):String
		return "$inline-enum-global:" + name.length + ":" + name + ":" + field;

	/** `fn` (whose body is `body`) lowered: itself when no position of it mentions a selected enum. */
	public function lower(fn:IrFunction, body:IrBody, builder:Null<IrBodyBuilder>):IrFunction {
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
			mentions[id] = containsMapped(IrTypeIds.type(id)) ? 1 : 0;
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
			mappedIds[id] = mentionsId(id) ? IrTypeIds.id(mapped(IrTypeIds.type(id))) : id;
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

	/** Whether the enum `name` is lowered to a value packet. */
	/** The text of what the eligibility let the closures of the function `name` carry. */
	public function callablePrint(name:String):String {
		var callable = eligibility.callableDescriptors.get(name);
		if (callable == null)
			return "";
		var values = [for (value in callable.keys()) value];
		values.sort((a, b) -> a - b);
		return values.join(",");
	}

	public function isSelected(name:String):Bool
		return planner.shape(name) != null;

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

/**
 * The lowering of each function (`IrInlineEnumLowering.lower`), per function (`IrFunctionPass`). The rewrite reads, for each enum
 * its types name, whether it is lowered (`SELECTED`); one that names a lowered enum also reads the print of what a lowering reads
 * of the program (`LAYOUT`: the selected enums' declarations and storage, the value objects, the interfaces) and of what the
 * eligibility let its closures carry (`CALLABLE`). It asks for the enum helpers it calls, by name, and for the word access natives
 * the function it hands on calls (by their place in `IrInlineEnumWordAccess.natives`, with no name). The helpers and the escape
 * adapters are derived (`IrFunctionStages.derived`), reading `LAYOUT`.
 */
@:nullSafety(Strict)
class IrInlineEnumLoweringPass extends IrFunctionPass {
	public static inline final STAGE = "inline-enum-lowering";

	static inline final SELECTED = 0;

	static inline final LAYOUT = 1;

	static inline final CALLABLE = 2;

	/** A helper request's kind is its constructor and its field, each plus 3, in this many bits and the rest. */
	static inline final CONSTRUCTOR_BITS = 15;

	final lowering:IrInlineEnumLowering;
	final builder:Null<IrBodyBuilder>;
	final stageMemos:Null<IrStageMemos>;
	final layout:() -> String;
	final helper:(name:String, enumName:String, constructor:Int, field:Int) -> IrFunction;

	/** The rewrite running, whose reader the lowering's helper requests go through. */
	var current:Null<IrFactReader> = null;

	/** By name, the helpers asked for: the enum, the constructor and the field. */
	final wanted:Map<String, {enumName:String, constructor:Int, field:Int}> = [];
	final natives:Array<String> = [for (native in IrInlineEnumWordAccess.natives()) native.name];

	/** By type id, the enums the type names where the lowering looks, or null when not known yet. */
	final enumNames:Array<Null<Array<String>>> = [];

	/** The word access natives the functions call. */
	public final called:Map<String, Bool> = [];

	public function new(lowering:IrInlineEnumLowering, builder:Null<IrBodyBuilder>,
			stageMemos:Null<IrStageMemos>,
			layout:() -> String, helper:(name:String, enumName:String, constructor:Int, field:Int) -> IrFunction) {
		this.lowering = lowering;
		this.builder = builder;
		this.stageMemos = stageMemos;
		this.layout = layout;
		this.helper = helper;
	}

	/** The lowering asks for the helper `name` (`IrInlineEnumLowering.helper`); `constructor` and `field` are at least -3. */
	public function ask(name:String, enumName:String, constructor:Int, field:Int):Void {
		var kind = (constructor + 3) | (field + 3) << CONSTRUCTOR_BITS, reader = current;
		if (reader == null)
			throw new InternalError('The inline enum helper $name is asked for outside a rewrite');
		reader.request(kind, Enum(enumName), name);
	}

	/** The helpers asked for, by name, derived. */
	public function helpers():Array<IrFunction> {
		var names = [for (name in wanted.keys()) name];
		names.sort(Reflect.compare);
		var made:Array<IrFunction> = [];
		for (name in names) {
			var found = wanted.get(name);
			if (found != null) {
				var wish:{enumName:String, constructor:Int, field:Int} = found;
				made.push(derive(name, () -> helper(name, wish.enumName, wish.constructor, wish.field)));
			}
		}
		return made;
	}

	/** The helper `name`, which `make` makes from the program's layout alone: derived in a session. */
	public function derive(name:String, make:() -> IrFunction):IrFunction {
		var known = stageMemos;
		return IrFunctionStages.derived(STAGE, name, this, IrFunctionStages.FROM_NAME, known,
			builder, reader -> {
				reader.read(LAYOUT, "");
				make();
			});
	}

	override public function summarize(fn:IrFunction):Int
		return 0;

	override public function prepare(functions:Array<IrFunction>, summaries:Array<Int>, names:IrFunctionIndex):Void {}

	override public function fact(kind:Int, key:String):Int {
		if (kind == SELECTED)
			return lowering.isSelected(key) ? 1 : 0;
		var known = stageMemos;
		if (known == null)
			return 0;
		return known.stageFacts.intern(kind == LAYOUT ? layout() : lowering.callablePrint(key));
	}

	static function addEnums(type:IrType, names:Array<String>):Void
		switch type {
			case Enum(name):
				if (names.indexOf(name) < 0)
					names.push(name);
			case Array(inner), Iterator(inner), Nullable(inner):
				addEnums(inner, names);
			case Function(arguments, result):
				for (argument in arguments)
					addEnums(argument, names);
				addEnums(result, names);
			default:
		}

	function readEnums(id:Int, reader:IrFactReader):Void {
		if (id < 0)
			return;
		var names = id < enumNames.length ? enumNames[id] : null;
		if (names == null) {
			names = [];
			addEnums(IrTypeIds.type(id), names);
			while (enumNames.length <= id)
				enumNames.push(null);
			enumNames[id] = names;
		}
		for (name in names)
			reader.read(SELECTED, name);
	}

	override public function transform(fn:IrFunction, summary:Int, reader:IrFactReader):IrFunction {
		var body = fn.encodedBody(builder);
		readEnums(body.result, reader);
		for (value in 0...body.valueLimit())
			readEnums(body.valueTypeId(IrValueId.of(value)), reader);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.TypeValue)
					readEnums(body.aux(row), reader);
				row = body.nextRow(row);
			}
		}
		current = reader;
		var result = lowering.lower(fn, body, builder);
		current = null;
		if (result != fn) {
			reader.read(LAYOUT, "");
			reader.read(CALLABLE, fn.name);
		}
		scanNatives(result.encodedBody(builder), reader);
		return result;
	}

	/** The word access natives `body` calls: asked for through `reader` when given, else noted. */
	public function scanNatives(body:IrBody, reader:Null<IrFactReader>):Void
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				if (body.opcode(row) == IrOpcode.Call) {
					var index = natives.indexOf(body.symbol(row).name);
					if (index >= 0) {
						if (reader != null)
							reader.request(index, Void);
						else
							called.set(natives[index], true);
					}
				}
				row = body.nextRow(row);
			}
		}

	override public function request(kind:Int, type:IrType, name:Null<String>):Void {
		if (name == null) {
			called.set(natives[kind], true);
			return;
		}
		var enumName = switch type {
			case Enum(enumName): enumName;
			default: throw new InternalError('The inline enum helper $name is asked for $type');
		};
		wanted.set(name, {
			enumName: enumName,
			constructor: (kind & ((1 << CONSTRUCTOR_BITS) - 1)) - 3,
			field: (kind >> CONSTRUCTOR_BITS) - 3
		});
	}

	override public function finish(functions:Array<IrFunction>):Array<IrFunction>
		return functions;
}

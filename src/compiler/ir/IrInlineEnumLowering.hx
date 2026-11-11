package compiler.ir;

import compiler.Provides.ProviderOperation;
import compiler.Provides.ProviderOperations;
import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.IrValueLaneLayout.IrValueLaneTarget;

/** Select one program-wide representation, then lower eligible enum values to their lane packets. */
class IrInlineEnumLowering {
	public static function run(program:IrProgram, target:IrValueLaneTarget, ?reflectableObjects:Array<String>):IrProgram {
		var planner = new IrInlineEnumLayout(program.enums, program.objects, target == HashLink ? 64 : 32, target);
		var eligibility = new IrInlineEnumEligibility(program, planner, reflectableObjects);
		if (!eligibility.allowed.keys().hasNext())
			return program;
		planner = new IrInlineEnumLayout(program.enums, program.objects, target == HashLink ? 64 : 32, target, null, false, eligibility.allowed);
		function storage(name:String):compiler.ir.IrInlineEnumLayout.IrInlineEnumShape {
			var shape = planner.shape(name);
			if (shape == null)
				throw 'Missing selected inline enum storage "$name"';
			return shape;
		}
		var selectedStorage:Map<String, String> = [];
		for (entry in program.enums)
			if (eligibility.allowed.exists(entry.name))
				selectedStorage.set(entry.name, storage(entry.name).valueObject.name);
		function inlineEnum(type:IrType):Bool
			return switch type {
				case Enum(name): planner.shape(name) != null;
				default: false;
			};
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
				case Function(arguments, result): Function([for (argument in arguments) mapped(argument)], mapped(result));
				case Nullable(inner): Nullable(mapped(inner));
				default: type;
			};
		var result = new IrProgram(program.entryPoint);
		result.enums = [
			for (entry in program.enums)
				{
					name: entry.name,
					cases: entry.cases,
					isRecursive: entry.isRecursive,
					inlineStorage: selectedStorage.get(entry.name)
				}
		];
		result.natives = program.natives.copy();
		result.cNatives = program.cNatives;
		result.positionalFingerprints = program.positionalFingerprints;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		result.parameterDefaults = program.parameterDefaults;
		result.interfaces = [
			for (entry in program.interfaces)
				{
					name: entry.name,
					bases: entry.bases,
					methods: [
						for (method in entry.methods)
							{
								name: method.name,
								arguments: [for (argument in method.arguments) mapped(argument)],
								result: mapped(method.result)
							}
					]
				}
		];
		result.staticFields = [];
		function globalLeaf(name:String, field:String):String
			return "$inline-enum-global:" + name.length + ":" + name + ":" + field;
		for (field in program.staticFields)
			switch field.type {
				case Enum(name) if (planner.shape(name) != null):
					for (leaf in storage(name).valueObject.fields)
						result.staticFields.push({name: globalLeaf(field.name, leaf.name), type: IrValueLaneReference.isCarrier(leaf.type) ? Dyn : leaf.type});
				default:
					result.staticFields.push({name: field.name, type: mapped(field.type)});
			}
		var rewrittenObjects:Array<IrObject> = [
			for (object in program.objects)
				{
					name: object.name,
					isValue: object.isValue,
					nativeLayout: object.nativeLayout,
					base: object.base,
					interfaces: object.interfaces,
					methods: object.methods,
					fields: [
						for (field in object.fields)
							{
								name: field.name,
								type: mapped(field.type),
								nativeLayout: field.nativeLayout,
								scalarStorage: field.scalarStorage,
								nullableScalarStorage: field.nullableScalarStorage
							}
					]
				}
		];
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
			helpers.set(name, new IrFunction(name, b.arguments, value.type, b.blocks, Provider(TypeKey.of(Enum(enumName)), ProviderOperations.detailed(ProviderOperation.InlineEnumHelper, name))));
			return name;
		}
		// Every rewrite below starts from a value whose type is, or contains, an inline enum; so does every check that throws.
		for (fn in program.functions) {
			if (!IrTypePositions.any(fn, containsMapped)) {
				result.functions.push(fn);
				continue;
			}
			var values:Map<Int, IrValue> = [], nulls:Map<Int, Bool> = [];
			for (block in fn.blocks)
				for (i in block.instructions)
					switch i.value {
						case ConstNull(out):
							nulls.set(out.id, true);
						default:
					}
			function use(value:IrValue):IrValue {
				if (!values.exists(value.id))
					values.set(value.id, new IrValue(value.id, value.name, mapped(value.type)));
				return values.get(value.id);
			}
			var nextValue = 0;
			for (arg in fn.arguments)
				if (arg.id >= nextValue)
					nextValue = arg.id + 1;
			for (block in fn.blocks)
				for (item in block.instructions) {
					var out = IrOperands.output(item.value);
					if (out != null && out.id >= nextValue)
						nextValue = out.id + 1;
					for (input in IrOperands.inputs(item.value))
						if (input.id >= nextValue)
							nextValue = input.id + 1;
				}
			function fresh(type:IrType):IrValue
				return new IrValue(nextValue++, "$enum-value-load", type);
			function copyLoad(block:IrBlock, output:IrValue, raw:IrValue, enumName:String, provenance:SourceProvenance):Void {
				var shape = storage(enumName),
					origin = new SourceProvenance(provenance.location, CompilerGenerated(IrGenerator.ValueCopyReason));
				block.instructions.push(new Located(NewObject(use(output), shape.valueObject.name), origin));
				for (field in shape.valueObject.fields) {
					var leaf = fresh(field.type);
					block.instructions.push(new Located(FieldGet(leaf, raw, field.name), origin));
					block.instructions.push(new Located(FieldSet(use(output), field.name, leaf), origin));
				}
			}
			// Mirror the frontend's existing struct parameter copies after making enum parameters physical values.
			var arguments = [for (argument in fn.arguments) use(argument)],
				parameterCopies = new IrBlock(-1);
			for (index in 0...fn.arguments.length)
				switch fn.arguments[index].type {
					case Enum(name) if (planner.shape(name) != null):
						var copied = fresh(mapped(fn.arguments[index].type));
						values.set(fn.arguments[index].id, copied);
						copyLoad(parameterCopies, copied, arguments[index], name, SourceProvenance.generated(IrGenerator.ValueCopyReason));
					default:
				}
			var blocks:Array<IrBlock> = [];
			for (block in fn.blocks) {
				var copy = new IrBlock(block.id);
				if (block == fn.blocks[0])
					for (item in parameterCopies.instructions)
						copy.instructions.push(item);
				for (located in block.instructions) {
					var instruction = IrInliner.remap(located.value, use, id -> id);
					switch located.value {
						case FieldGet(output, owner, field):
							switch output.type {
								case Enum(name) if (planner.shape(name) != null):
									var raw = fresh(mapped(output.type));
									copy.instructions.push(new Located(FieldGet(raw, use(owner), field), located.provenance));
									copyLoad(copy, output, raw, name, located.provenance);
									continue;
								default:
							}
						case GlobalGet(output, name):
							switch output.type {
								case Enum(enumName) if (planner.shape(enumName) != null):
									var shape = storage(enumName),
										origin = new SourceProvenance(located.provenance.location, CompilerGenerated(IrGenerator.ValueCopyReason));
									copy.instructions.push(new Located(NewObject(use(output), shape.valueObject.name), origin));
									for (field in shape.valueObject.fields) {
										var leaf = fresh(field.type);
										if (IrValueLaneReference.isCarrier(field.type)) {
											var raw = fresh(Dyn);
											copy.instructions.push(new Located(GlobalGet(raw, globalLeaf(name, field.name)), origin));
											copy.instructions.push(new Located(Call(leaf, IrValueLaneReference.PACK, [raw]), origin));
										} else
											copy.instructions.push(new Located(GlobalGet(leaf, globalLeaf(name, field.name)), origin));
										copy.instructions.push(new Located(FieldSet(use(output), field.name, leaf), origin));
									}
									continue;
								default:
							}
						case GlobalSet(name, value):
							switch value.type {
								case Enum(enumName) if (planner.shape(enumName) != null):
									var leaves:Array<{name:String, value:IrValue}> = [];
									for (field in storage(enumName).valueObject.fields) {
										var leaf = fresh(field.type);
										copy.instructions.push(new Located(FieldGet(leaf, use(value), field.name), located.provenance));
										if (IrValueLaneReference.isCarrier(field.type)) {
											var raw = fresh(Dyn);
											copy.instructions.push(new Located(Call(raw, IrValueLaneReference.UNPACK, [leaf]), located.provenance));
											leaf = raw;
										}
										leaves.push({name: globalLeaf(name, field.name), value: leaf});
									}
									// Snapshot every leaf before publishing any part of the assignment.
									for (leaf in leaves)
										copy.instructions.push(new Located(GlobalSet(leaf.name, leaf.value), located.provenance));
									continue;
								default:
							}
						case MakeEnum(output, name, constructor, args) if (planner.shape(name) != null):
							var name = helper(IrInlineEnumCaseAccess.HELPER_PREFIX + 'construct:$name:$constructor', name, constructor, -1);
							instruction = Call(use(output), name, [for (argument in args) use(argument)]);
						case ConstNull(output):
							switch output.type {
								case Enum(name) if (planner.shape(name) != null): instruction = Call(use(output),
										helper(IrInlineEnumCaseAccess.HELPER_PREFIX + 'null:$name', name, -2, -1), []);
								default:
							}
						case EnumField(output, value, constructor, field):
							switch value.type {
								case Enum(name) if (planner.shape(name) != null): instruction = Call(use(output),
										helper(IrInlineEnumCaseAccess.HELPER_PREFIX + 'field:$name:$constructor:$field', name, constructor,
											field), [use(value)]);
								default:
							}
						case EnumIndex(output, value):
							switch value.type {
								case Enum(name) if (planner.shape(name) != null): instruction = Call(use(output),
										helper(IrInlineEnumCaseAccess.HELPER_PREFIX + 'index:$name', name, -1, -2), [use(value)]);
								default:
							}
						case Equal(output, left, right) if (nulls.exists(left.id) || nulls.exists(right.id)):
							var operand = nulls.exists(left.id) ? right : left;
							switch operand.type {
								case Enum(name) if (planner.shape(name) != null): instruction = Call(use(output),
										helper(IrInlineEnumCaseAccess.HELPER_PREFIX + "is-null:" + name, name, -1, -3), [use(operand)]);
								default:
							}
						case ToDyn(_, value) if (inlineEnum(value.type)):
							throw "Eligible enum unexpectedly escapes to Dynamic";
						case SafeCast(output, _) if (inlineEnum(output.type)):
							throw "Eligible enum unexpectedly enters from Dynamic";
						case SafeCast(output, _) if (switch output.type {
								case Array(_), Iterator(_): true;
								default: false;
							}):
							// Container casts keep their logical descriptor; the shared array pass installs lane storage.
						case ToDyn(_, value) if (switch value.type {
								case Array(_), Iterator(_): true;
								default: false;
							}):
							// The container header is the reference escape; do not box its elements.
						case Equal(_, left, right) if (switch left.type {
								case Function(_, _): true;
								default: false;
							}):
						case ToDyn(_, value) if (eligibility.supportsCallableEscape(value.type)):
							// Scalar closure lowering boxes enum arguments only in this Dynamic boundary adapter.
						case SafeCast(output, value) if ((switch value.type { case Dyn: true; default: false; })
							&& eligibility.supportsCallableEscape(output.type)):
							// The paired closure adapter restores the physical enum packet after its logical signature check.
						case ToDyn(_, value), SafeCast(_, value), Equal(_, value, _):
							var output = IrOperands.output(located.value);
							var supported = switch located.value {
								case ToDyn(_, input): eligibility.supportsCallableEscape(input.type);
								case SafeCast(out, input): (switch input.type { case Dyn: true; default: false; }) && eligibility.supportsCallableEscape(out.type);
								default: false;
							};
							if (!supported && (containsMapped(value.type) || (output != null && containsMapped(output.type))))
								throw 'Unsupported inline enum escape passed eligibility: ' + Std.string(located.value);
						case TypeValue(out, type):
							var callable = eligibility.callableDescriptors.get(fn.name);
							instruction = TypeValue(use(out), callable != null && callable.exists(out.id) ? mapped(type) : type);
						default:
					}
					copy.instructions.push(new Located(instruction, located.provenance));
				}
				if (block.terminator != null)
					copy.terminator = new Located(switch block.terminator.value {
						case Return(value): Return(use(value));
						case Throw(value):
							if (containsMapped(value.type))
								throw 'Unsupported inline enum throw passed eligibility';
							Throw(use(value));
						case Rethrow(value): Rethrow(use(value));
						case Jump(id): Jump(id);
						case Branch(condition, yes, no): Branch(use(condition), yes, no);
					}, block.terminator.provenance);
				blocks.push(copy);
			}
			result.functions.push(new IrFunction(fn.name, arguments, mapped(fn.result), blocks, fn.kind, [
				for (binding in fn.debugBindings)
					{
						identity: binding.identity,
						name: binding.name,
						value: use(binding.value),
						path: binding.path,
						scopeStart: binding.scopeStart,
						scopeEnd: binding.scopeEnd
					}
			], fn.inlineHint, fn.retention));
		}
		var names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names)
			result.functions.push(helpers.get(name));
		result.functions = IrTypedInterfaceDispatch.rewriteValueCalls(result.functions, result.objects, result.interfaces);
		IrTypedInterfaceDispatch.generate(result.functions, result.objects, result.interfaces);
		// Lane-array reflection bridges use the logical enum adapter even when this source has no escape.
		result.functions = result.functions.concat(IrInlineEnumEscapes.functions(result.enums, table, planner));
		var calls:Map<String, Bool> = [];
		for (fn in result.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, name, _):
							calls.set(name, true);
						default:
					}
		var existing = [for (native in result.natives) native.name => true];
		for (native in IrInlineEnumWordAccess.natives())
			if (native.name != "haxe.Int64.toInt" && calls.exists(native.name) && !existing.exists(native.name))
				result.natives.push(native);
		return result;
	}
}

package compiler.ir.passes.enums;

import compiler.ir.analysis.IrEnumEscapeReach;
import compiler.ir.model.Ir;
import compiler.ir.model.IrBody;
import compiler.ir.model.IrBodyBuilder;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrOpcode;
import compiler.ir.model.IrTypeIds;
import compiler.ir.passes.objects.ObjectReflection;
import compiler.ir.passes.values.IrValueInterfaceBoxes;
import compiler.semantic.SemanticSignature;
import compiler.types.typing.EnumRuntimeType;

private typedef EnumUseNode = {
	final parents:Array<Int>;
	final bits:Array<Int>;
	var queued:Bool;
}

/** Conservative first source subset. A rejected enum keeps its nominal storage everywhere in the program. */
class IrInlineEnumEligibility {
	public final allowed:Map<String, Bool> = [];
	public final reasons:Map<String, String> = [];
	/** Type descriptors that describe a verified callable boundary for a selected enum. */
	public final callableDescriptors:Map<String, Map<Int, Bool>> = [];

	final objects:Map<String, IrObject>;
	final contracts:Map<String, IrInterface>;
	final declarations:Map<String, IrEnum>;
	final planner:IrInlineEnumLayout;
	final reflectionReach:IrEnumEscapeReach;
	final enumNodes:Map<String, Int> = [];
	final objectNodes:Map<String, Int> = [];
	final interfaceNodes:Map<String, Int> = [];
	final escapeRoots:Map<String, Array<IrType>> = [];
	final escapeOrder:Array<String> = [];
	final names:Array<String>;
	final nodes:Array<EnumUseNode> = [];
	final words:Int;
	final rejected:Array<Int>;
	/** The constants null of the function `scan` reads. */
	final nulls:Map<Int, Bool> = [];

	/**
	 * The enums of `program` that may be lowered to value packets, reading the functions' bodies made with `types` (those of the
	 * functions' bodies when not given), encoding a function that has none.
	 */
	public function new(program:IrProgram, planner:IrInlineEnumLayout, ?reflectableObjects:Array<String>,
			?types:IrTypeIds, ?builder:IrBodyBuilder) {
		this.planner = planner;
		var bodyTypes = types == null ? IrTypeIds.ofFunctions(program.functions) : types;
		reflectionReach = new IrEnumEscapeReach(program);
		declarations = [for (declaration in program.enums) declaration.name => declaration];
		objects = [for (object in program.objects) object.name => object];
		contracts = [for (contract in program.interfaces) contract.name => contract];
		// Tag enums have no payload storage to classify. Exclude them before allocating graph bitsets.
		names = [for (declaration in program.enums) if (!IrEnumTagStorage.eligible(declaration)) declaration.name];
		words = (names.length + 31) >> 5;
		rejected = [for (_ in 0...words) 0];
		if (names.length == 0) return;
		for (index in 0...names.length) {
			var name = names[index], node = named(enumNodes, name);
			nodes[node].bits[index >> 5] |= 1 << (index & 31);
		}
		for (object in program.objects) {
			var node = named(objectNodes, object.name);
			for (field in object.fields)
				depend(node, field.type);
			if (object.base != null) {
				var base = named(objectNodes, object.base);
				edge(node, base);
				edge(base, node);
			}
			for (contract in object.interfaces)
				edge(named(interfaceNodes, contract), node);
		}
		for (contract in program.interfaces) {
			var node = named(interfaceNodes, contract.name);
			for (base in contract.bases)
				edge(named(interfaceNodes, base), node);
		}
		for (declaration in program.enums)
			for (constructor in declaration.cases)
				for (parameter in constructor.params)
					depend(named(enumNodes, declaration.name), parameter);
		var functions = [for (fn in program.functions) fn.name => fn];
		for (object in program.objects)
			for (method in object.methods) {
				var fn = functions.get(method.functionName.name);
				if (fn == null)
					continue;
				var node = named(objectNodes, object.name);
				for (argument in fn.arguments)
					depend(node, argument.type);
				depend(node, fn.result);
			}
		for (field in program.staticFields) {
			var separator = field.name.lastIndexOf(".");
			if (separator < 0)
				continue;
			var node = objectNodes.get(field.name.substr(0, separator));
			if (node != null)
				depend(node, field.type);
		}
		closeDependencies();
		// Retained fields can survive even when no instruction reads or initializes them. Their container
		// descriptors still carry closure signatures, so apply the same restriction as instruction outputs.
		for (object in program.objects)
			for (field in object.fields)
				containerCallable(field.type);
		for (field in program.staticFields)
			containerCallable(field.type);
		for (declaration in program.enums) if (!IrEnumTagStorage.eligible(declaration)) {
			if (nativePayload(Enum(declaration.name), []))
				block(declaration.name, "canonical native payload layout");
			else if (planner.shape(declaration.name) == null)
				block(declaration.name, "recursive or disproportionate layout");
			else if (EnumRuntimeType.declaration(declaration.name) != declaration.name)
				block(declaration.name, "generic enum transport");
			// Reference payloads retain nominal callable descriptors; do not rewrite one side of their ABI.
			for (constructor in declaration.cases)
				for (parameter in constructor.params)
					callablePayload(parameter);
		}
		// Selecting a larger inline field must never reuse native offsets computed for a boxed enum.
		for (object in program.objects)
			if (object.nativeLayout != null)
				for (field in object.fields)
					value(field.type, "enclosing native layout");
		for (object in program.objects)
			if (!object.isValue)
				for (method in object.methods) {
					var fn = functions.get(method.functionName.name);
					if (fn == null)
						continue;
					for (argument in fn.arguments)
						value(argument.type, "ordinary method signature");
					value(fn.result, "ordinary method signature");
				}
		for (native in program.natives)
			if (!IrArrayRuntimeNatives.isStorage(native.name)) {
				for (argument in native.arguments)
					escape(argument, "native signature");
				escape(native.result, "native signature");
			}
		// Reflection helpers are generated after storage selection and can expose every registered layout.
		if (ObjectReflection.usedByProgram(program)) {
			var reflectedNames = reflectableObjects == null ? [] : reflectableObjects,
				reflected = [for (name in reflectedNames) name => true];
			for (object in program.objects) {
				// Anonymous records have runtime layouts too. A Dynamic/reflection edge can reach
				// one even when it was created inside a Dynamic object literal.
				if (!object.isValue && SemanticSignature.isAnonymousName(object.name))
					reflected.set(object.name, true);
				if (object.isValue || StringTools.startsWith(object.name, IrValueInterfaceBoxes.BOX_PREFIX))
					reflected.set(object.name, true);
			}
			var unsupported = reflectedUnsupportedEnums(reflected);
			for (name in unsupported.keys()) block(name, "registered reflection layout");
		}
		for (native in program.cNatives) {
			for (argument in native.arguments)
				escape(argument, "C native signature");
			escape(native.result, "C native signature");
		}
		for (fn in program.functions)
			scan(fn, fn.bodyIn(bodyTypes, builder), program.entryPoint);
		for (reason in escapeOrder)
			for (name in reflectionReach.collect(escapeRoots.get(reason), supportsCallableEscape).keys()) block(name,
				reason);
		for (name in names)
			if (!reasons.exists(name))
				allowed.set(name, true);
	}

	/** What one function's rows let escape or keep in value form, and its verified callable descriptors. */
	function scan(fn:IrFunction, body:IrBody, entryPoint:String):Void {
		if (fn.retention == Expose || fn.name == entryPoint) {
			for (argument in fn.arguments)
				escape(argument.type, "host signature");
			escape(fn.result, "host signature");
		}
		// Descriptors are rare: their tables are made for a function that has one.
		var descriptors:Null<Map<Int, IrType>> = null;
		nulls.clear();
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.TypeValue:
						if (descriptors == null)
							descriptors = [];
						descriptors.set(body.output(row), body.typeOperand(row));
					case IrOpcode.ConstNull:
						nulls.set(body.output(row), true);
					default:
				}
				row = body.nextRow(row);
			}
		}
		var arrayDescriptors:Map<Int, Bool> = descriptors == null ? null : [],
			callableDescriptorUses:Map<Int, Bool> = descriptors == null ? null : [],
			referenceTypeDescriptorUses:Map<Int, Bool> = descriptors == null ? null : [],
			logicalEnumDescriptorUses:Map<Int, Bool> = descriptors == null ? null : [],
			descriptorUses:Map<Int, Int> = descriptors == null ? null : [],
			otherDescriptors:Map<Int, Bool> = descriptors == null ? null : [];
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var opcode = body.opcode(row);
				if (opcode.isTerminator()) {
					switch opcode {
						case IrOpcode.Throw, IrOpcode.Rethrow:
							escape(body.valueType(body.operand(row, 0)), "exception escape");
						case IrOpcode.Return, IrOpcode.Branch, IrOpcode.Switch
							if (descriptors != null && descriptors.exists(body.operand(row, 0))):
							otherDescriptors.set(body.operand(row, 0), true);
						default:
					}
					row = body.nextRow(row);
					continue;
				}
				if (descriptors != null && opcode != IrOpcode.Phi)
					for (inputIndex in 0...body.operandCount(row)) {
						var input:Int = body.operand(row, inputIndex);
						if (descriptors.exists(input)) {
							descriptorUses.set(input,
								(descriptorUses.exists(input) ? descriptorUses.get(input) : 0) + 1);
							var callTarget = opcode == IrOpcode.Call && body.operandCount(row) == 2
								&& body.operand(row, 1) == input ? body.symbol(row).name : null;
							if (callTarget == "__closure_is_of_type" && supportsCallableEscape(descriptors.get(input)))
								callableDescriptorUses.set(input, true);
							else if ((callTarget == "__std_is_exact_type" || callTarget == "__std_is_of_type")
								&& isReferenceTypeDescriptor(descriptors.get(input)))
								referenceTypeDescriptorUses.set(input, true);
							else if (callTarget == "__array_alloc_typed_ref")
								arrayDescriptors.set(input, true);
							else if ((callTarget == "__std_is_exact_type" || callTarget == "__std_is_of_type")
								&& logicalEnumDescriptorFunction(fn.name)
								&& isSelectedEnumDescriptor(descriptors.get(input)))
								logicalEnumDescriptorUses.set(input, true);
							else
								otherDescriptors.set(input, true);
						}
					}
				switch opcode {
					case IrOpcode.Call:
						var name = body.symbol(row).name;
						if (StringTools.startsWith(name, "__map_") && StringTools.contains(name, "_ref_")) {
							var count = body.operandCount(row);
							switch name.substr(name.lastIndexOf("_ref_") + 5) {
								case "set" if (count >= 3):
									// A map stores the value reference itself. Classes, arrays and iterators keep their own object layout;
									// a direct enum or value struct still needs its nominal boxed representation here.
									escapeMapReference(body.valueType(body.operand(row, count - 1)),
										"native reference map storage");
								case "get" | "values" | "handles":
									escapeMapReference(body.valueType(body.output(row)),
										"native reference map storage");
								default:
							}
						}
					case IrOpcode.ToDyn:
						var value = body.valueType(body.operand(row, 0));
						if (!supportsCallableEscape(value))
							escape(value, "Dynamic escape");
					case IrOpcode.SafeCast:
						var value = body.valueType(body.operand(row, 0)), out = body.valueType(body.output(row));
						if (!((switch value {
							case Dyn: true;
							default: false;
						}) && supportsCallableEscape(out))) {
							escape(out, "checked escape");
							escape(value, "checked escape");
						}
					case IrOpcode.Phi if (descriptors != null):
						for (index in 0...body.operandCount(row)) {
							var input:Int = body.operand(row, index);
							if (descriptors.exists(input)) {
								descriptorUses.set(input,
									(descriptorUses.exists(input) ? descriptorUses.get(input) : 0) + 1);
								otherDescriptors.set(input, true);
							}
						}
					case IrOpcode.MethodCall:
						// Interface packets have a verified typed table; ordinary value calls do not yet share it.
						var receiver = body.valueType(body.operand(row, 0));
						switch receiver {
							case Virtual(_):
							default:
								value(receiver, "ordinary method receiver");
								value(body.valueType(body.output(row)), "ordinary method result");
								for (index in 1...body.operandCount(row))
									value(body.valueType(body.operand(row, index)), "ordinary method argument");
						}
					case IrOpcode.InstanceClosure:
						var receiver = body.valueType(body.operand(row, 0));
						switch receiver {
							case Virtual(_):
							case Obj(name) if (StringTools.startsWith(name,
								compiler.semantic.LambdaName.ENVIRONMENT_PREFIX)):
							default:
								value(receiver, "bound value receiver");
								callableValue(body.valueType(body.output(row)), "bound value method", true);
						}
					case IrOpcode.Equal:
						var left = body.operand(row, 0), right = body.operand(row, 1);
						if (!nulls.exists(left) && !nulls.exists(right)) {
							value(body.valueType(left), "unlowered enum comparison");
							value(body.valueType(right), "unlowered enum comparison");
						}
					default:
				}
				var out = body.output(row);
				if (out.exists())
					containerCallable(body.valueType(out));
				row = body.nextRow(row);
			}
		}
		if (descriptors == null)
			return;
		var validCallableDescriptors:Map<Int, Bool> = [];
		for (id => type in descriptors) {
			var singleUse = descriptorUses.get(id) == 1 && !otherDescriptors.exists(id);
			if (referenceTypeDescriptorUses.exists(id) && singleUse && isReferenceTypeDescriptor(type))
				continue;
			if (logicalEnumDescriptorUses.exists(id) && singleUse && isSelectedEnumDescriptor(type))
				continue;
			if (callableDescriptorUses.exists(id) && singleUse && supportsCallableEscape(type))
				validCallableDescriptors.set(id, true);
			else if (!arrayDescriptors.exists(id) || otherDescriptors.exists(id) || descriptorUses.get(id) != 1)
				escape(type, "runtime type descriptor");
		}
		if (validCallableDescriptors.keys().hasNext())
			callableDescriptors.set(fn.name, validCallableDescriptors);
	}

	static function logicalEnumDescriptorFunction(name:String):Bool
		return name == IrEnumDynamicDispatch.EQUAL || name == IrEnumDynamicDispatch.REFLECT
			|| StringTools.startsWith(name, "$enum-dynamic-test:");

	function isSelectedEnumDescriptor(type:IrType):Bool
		return switch type {
			case Enum(name): planner.shape(name) != null;
			default: false;
		};

	/** A class type check consumes nominal identity without observing the class's field layout. */
	function isReferenceTypeDescriptor(type:IrType):Bool
		return switch type {
			case Obj(name):
				var object = objects.get(name);
				object != null && !object.isValue;
			default: false;
		};

	// Native structs need the independent canonical layout, not target-specific pointer offsets.
	function nativePayload(type:IrType, seen:Array<String>):Bool
		return switch type {
			case Enum(name):
				if (seen.contains(name)) false;
				else {
					var declaration = declarations.get(name);
					declaration != null && Lambda.exists(declaration.cases,
						item -> Lambda.exists(item.params, p -> nativePayload(p, seen.concat([name]))));
				}
			case Obj(name): var object = objects.get(name);
				object != null && object.isValue && (object.nativeLayout != null
					|| Lambda.exists(object.fields, field -> nativePayload(field.type, seen)));
			case Nullable(inner): nativePayload(inner, seen);
			default: false;
		}

	function named(map:Map<String, Int>, name:String):Int {
		var found = map.get(name);
		if (found != null)
			return found;
		var index = nodes.length;
		nodes.push({parents: [], bits: [for (_ in 0...words) 0], queued: false});
		map.set(name, index);
		return index;
	}

	function edge(parent:Int, child:Int):Void
		nodes[child].parents.push(parent);

	function depend(parent:Int, type:IrType):Void
		switch type {
			case Enum(name):
				edge(parent, named(enumNodes, name));
			case Obj(name):
				var object = objects.get(name);
				// Ordinary classes are reference leaves in every value layout. Their fields and methods matter only when
				// that class itself crosses a Dynamic/reflection or typed-call boundary.
				if (object != null && object.isValue)
					edge(parent, named(objectNodes, name));
			case Virtual(name):
				edge(parent, named(interfaceNodes, name));
			case Array(inner), Iterator(inner), Nullable(inner):
				depend(parent, inner);
			case Function(arguments, result):
				for (argument in arguments)
					depend(parent, argument);
				depend(parent, result);
			default:
		}

	function closeDependencies():Void {
		var pending:Array<Int> = [];
		for (index in enumNodes) {
			pending.push(index);
			nodes[index].queued = true;
		}
		var cursor = 0;
		while (cursor < pending.length) {
			var node = nodes[pending[cursor++]];
			node.queued = false;
			for (parent in node.parents) {
				var target = nodes[parent], changed = false;
				for (word in 0...words) {
					var merged = target.bits[word] | node.bits[word];
					if (merged != target.bits[word]) {
						target.bits[word] = merged;
						changed = true;
					}
				}
				if (changed && !target.queued) {
					pending.push(parent);
					target.queued = true;
				}
			}
		}
	}

	function mark(node:Null<Int>, reason:String):Void {
		if (node == null)
			return;
		var bits = nodes[node].bits;
		for (word in 0...words) {
			var fresh = bits[word] & ~rejected[word];
			if (fresh == 0)
				continue;
			rejected[word] |= fresh;
			for (bit in 0...32)
				if ((fresh & (1 << bit)) != 0) {
					reasons.set(names[(word << 5) + bit], reason);
				}
		}
	}

	/** Direct selected enum arguments/results can use the established scalar closure ABI and enum escape adapters. */
	public function supportsCallableEscape(type:IrType):Bool {
		var signature:Null<IrType> = switch type {
			case Function(_, _): type;
			case Nullable(inner): switch inner {
					case Function(_, _): inner;
					default: null;
				};
			default: null;
		};
		if (signature == null) return false;
		var parts:Array<IrType> = switch signature {
			case Function(arguments, result): arguments.concat([result]);
			default: [];
		};
		var found = false;
		for (part in parts)
			switch part {
				case Enum(name) if (planner.shape(name) != null && EnumRuntimeType.declaration(name) == name
					&& !nativePayload(Enum(name), [])):
					found = true;
				default:
					if (hasSelectedEnum(part, [])) return false;
			}
		return found;
	}

	function hasSelectedEnum(type:IrType, seenValues:Array<String>):Bool
		return switch type {
			case Enum(name): planner.shape(name) != null;
			case Nullable(inner), Array(inner), Iterator(inner): hasSelectedEnum(inner, seenValues);
			case Function(arguments, result): Lambda.exists(arguments,
				argument -> hasSelectedEnum(argument, seenValues)) || hasSelectedEnum(result, seenValues);
			case Obj(name):
				var object = objects.get(name);
				object != null && object.isValue && !seenValues.contains(name)
					&& Lambda.exists(object.fields, field -> hasSelectedEnum(field.type, seenValues.concat([name])));
			default: false;
		};

	function reflectedUnsupportedEnums(reflected:Map<String, Bool>):Map<String, Bool> {
		var roots:Array<IrType> = [for (name in reflected.keys()) Obj(name)];
		return reflectionReach.collect(roots, supportsCallableEscape);
	}

	function block(name:String, reason:String):Void {
		if (enumNodes.exists(name)) mark(enumNodes.get(name), reason);
	}

	/** Map reference slots retain managed object pointers; only boxed value packets cross this boundary. */
	function escapeMapReference(type:IrType, reason:String):Void
		switch type {
			case Enum(_): escapeType(type, reason);
			case Nullable(inner): escapeMapReference(inner, reason);
			case Obj(name):
				var object = objects.get(name);
				if (object != null && object.isValue) escapeType(type, reason);
			case Function(_, _): escapeType(type, reason);
			default:
		}

	function escape(type:IrType, reason:String):Void escapeType(type, reason);

	function escapeType(type:IrType, reason:String):Void {
		var roots = escapeRoots.get(reason);
		if (roots == null) {
			roots = [];
			escapeRoots.set(reason, roots);
			escapeOrder.push(reason);
		}
		if (reason == "native signature" || reason == "C native signature") IrEnumEscapeReach.addNativeRoot(roots,
			type);
		else roots.push(type);
	}

	function value(type:IrType, reason:String):Void
		switch type {
			case Enum(name):
				block(name, reason);
			case Nullable(inner):
				value(inner, reason);
			case Obj(name):
				var object = objects.get(name);
				if (object != null && object.isValue)
					for (field in object.fields)
						value(field.type, reason);
			default:
		}

	function callableValue(type:IrType, reason:String, allowInlineEnumEscape:Bool = false):Void
		switch type {
			case Function(arguments, result):
				if (allowInlineEnumEscape && supportsCallableEscape(type)) return;
				for (argument in arguments)
					value(argument, reason);
				value(result, reason);
			default:
		}

	function callablePayload(type:IrType):Void
		switch type {
			case Function(_, _):
				callableValue(type, "nominal callable payload");
			case Nullable(inner), Array(inner), Iterator(inner):
				callablePayload(inner);
			case Obj(name):
				var object = objects.get(name);
				if (object != null && object.isValue)
					for (field in object.fields)
						callablePayload(field.type);
			default:
		}

	function containerCallable(type:IrType):Void
		switch type {
			case Array(inner), Iterator(inner):
				callablePayload(inner);
			case Nullable(inner):
				containerCallable(inner);
			default:
		}
}

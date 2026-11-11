package compiler.ir;

import compiler.ir.Ir;
import compiler.semantic.SemanticSignature;
import compiler.types.typing.EnumRuntimeType;

private typedef EnumUseNode = {final parents:Array<Int>; final bits:Array<Int>; var queued:Bool;}

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

	public function new(program:IrProgram, planner:IrInlineEnumLayout, ?reflectableObjects:Array<String>) {
		this.planner = planner;
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
				var fn = functions.get(method.functionName);
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
					var fn = functions.get(method.functionName);
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
		if (ObjectReflection.usesObjectLayouts(program.natives)) {
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
		for (fn in program.functions) {
			if (fn.retention == Expose || fn.name == program.entryPoint) {
				for (argument in fn.arguments)
					escape(argument.type, "host signature");
				escape(fn.result, "host signature");
			}
			var descriptors:Map<Int, IrType> = [],
				arrayDescriptors:Map<Int, Bool> = [],
				callableDescriptorUses:Map<Int, Bool> = [],
				referenceTypeDescriptorUses:Map<Int, Bool> = [],
				logicalEnumDescriptorUses:Map<Int, Bool> = [],
				descriptorUses:Map<Int, Int> = [],
				otherDescriptors:Map<Int, Bool> = [],
				nulls:Map<Int, Bool> = [];
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case TypeValue(out, type):
							descriptors.set(out.id, type);
						case ConstNull(out):
							nulls.set(out.id, true);
						default:
					}
			for (block in fn.blocks) {
				for (located in block.instructions) {
					var instruction = located.value;
					for (input in IrOperands.inputs(instruction))
						if (descriptors.exists(input.id)) {
							descriptorUses.set(input.id, (descriptorUses.exists(input.id) ? descriptorUses.get(input.id) : 0) + 1);
							switch instruction {
								case Call(_, "__closure_is_of_type", arguments) if (arguments.length == 2 && arguments[1].id == input.id
									&& supportsCallableEscape(descriptors.get(input.id))):
									callableDescriptorUses.set(input.id, true);
							case Call(_, "__std_is_exact_type" | "__std_is_of_type", arguments) if (arguments.length == 2 && arguments[1].id == input.id
								&& isReferenceTypeDescriptor(descriptors.get(input.id))):
								referenceTypeDescriptorUses.set(input.id, true);
								case Call(_, "__array_alloc_typed_ref", arguments) if (arguments.length == 2 && arguments[1].id == input.id):
									arrayDescriptors.set(input.id, true);
								case Call(_, "__std_is_exact_type" | "__std_is_of_type", arguments) if (arguments.length == 2 && arguments[1].id == input.id
									&& logicalEnumDescriptorFunction(fn.name) && isSelectedEnumDescriptor(descriptors.get(input.id))):
									logicalEnumDescriptorUses.set(input.id, true);
								default:
									otherDescriptors.set(input.id, true);
							}
						}
					switch instruction {
						case Call(out, name, arguments) if (StringTools.startsWith(name, "__map_")
							&& StringTools.contains(name, "_ref_")):
							var operation = name.substr(name.lastIndexOf("_ref_") + 5);
							switch operation {
								case "set" if (arguments.length >= 3):
								// A map stores the value reference itself. Classes, arrays and iterators keep their own object layout;
								// a direct enum or value struct still needs its nominal boxed representation here.
								escapeMapReference(arguments[arguments.length - 1].type, "native reference map storage");
								case "get" | "values":
								escapeMapReference(out.type, "native reference map storage");
								default:
							}
						case ToDyn(out, value) if (!supportsCallableEscape(value.type)):
							escape(value.type, "Dynamic escape");
						case SafeCast(out, value) if (!((switch (value.type) { case Dyn: true; default: false; }) && supportsCallableEscape(out.type))):
							escape(out.type, "checked escape");
							escape(value.type, "checked escape");
						case Phi(_, inputs):
							for (input in inputs)
								if (descriptors.exists(input.value.id)) {
									descriptorUses.set(input.value.id, (descriptorUses.exists(input.value.id) ? descriptorUses.get(input.value.id) : 0) + 1);
									otherDescriptors.set(input.value.id, true);
								}
						case MethodCall(out, receiver, _, arguments, _):
							// Interface packets have a verified typed table; ordinary value calls do not yet share it.
							switch receiver.type {
								case Virtual(_):
								default:
									value(receiver.type, "ordinary method receiver");
									value(out.type, "ordinary method result");
									for (argument in arguments)
										value(argument.type, "ordinary method argument");
							}
						case InstanceClosure(out, _, receiver):
							switch receiver.type {
								case Virtual(_):
								case Obj(name) if (StringTools.startsWith(name, compiler.semantic.LambdaName.ENVIRONMENT_PREFIX)):
								default:
									value(receiver.type, "bound value receiver");
									callableValue(out.type, "bound value method", true);
							}
						case Equal(_, left, right) if (!nulls.exists(left.id) && !nulls.exists(right.id)):
							value(left.type, "unlowered enum comparison");
							value(right.type, "unlowered enum comparison");
						default:
					}
					var out = IrOperands.output(instruction);
					if (out != null)
						containerCallable(out.type);
				}
				if (block.terminator != null)
					switch block.terminator.value {
						case Throw(thrown), Rethrow(thrown):
							escape(thrown.type, "exception escape");
						case Return(result), Branch(result, _, _) if (descriptors.exists(result.id)):
							otherDescriptors.set(result.id, true);
						default:
					}
			}
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
					{
					escape(type, "runtime type descriptor");
					}
			}
			if (validCallableDescriptors.keys().hasNext()) callableDescriptors.set(fn.name, validCallableDescriptors);
		}
		for (reason in escapeOrder)
			for (name in reflectionReach.collect(escapeRoots.get(reason), supportsCallableEscape).keys()) block(name, reason);
		for (name in names)
			if (!reasons.exists(name))
				allowed.set(name, true);
	}

	static function logicalEnumDescriptorFunction(name:String):Bool
		return name == IrEnumDynamicDispatch.EQUAL || name == IrEnumDynamicDispatch.REFLECT
			|| StringTools.startsWith(name, "$enum-dynamic-test:");

	function isSelectedEnumDescriptor(type:IrType):Bool
		return switch type { case Enum(name): planner.shape(name) != null; default: false; };

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
				if (seen.contains(name)) false; else {
					var declaration = declarations.get(name);
					declaration != null && Lambda.exists(declaration.cases, item -> Lambda.exists(item.params, p -> nativePayload(p, seen.concat([name]))))
					;
				}
			case Obj(name): var object = objects.get(name); object != null && object.isValue && (object.nativeLayout != null
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
			case Nullable(inner): switch inner { case Function(_, _): inner; default: null; };
			default: null;
		};
		if (signature == null) return false;
		var parts:Array<IrType> = switch signature { case Function(arguments, result): arguments.concat([result]); default: []; };
		var found = false;
		for (part in parts)
			switch part {
				case Enum(name) if (planner.shape(name) != null && EnumRuntimeType.declaration(name) == name && !nativePayload(Enum(name), [])):
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
			case Function(arguments, result): Lambda.exists(arguments, argument -> hasSelectedEnum(argument, seenValues)) || hasSelectedEnum(result, seenValues);
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
		if (reason == "native signature" || reason == "C native signature") IrEnumEscapeReach.addNativeRoot(roots, type);
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

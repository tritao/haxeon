package compiler.ir;

import compiler.ir.Ir;
import compiler.types.typing.EnumRuntimeType;

private typedef EnumUseNode = {final parents:Array<Int>; final bits:Array<Int>; var queued:Bool;}

/** Conservative first source subset. A rejected enum keeps its nominal storage everywhere in the program. */
class IrInlineEnumEligibility {
	public final allowed:Map<String, Bool> = [];
	public final reasons:Map<String, String> = [];

	final objects:Map<String, IrObject>;
	final declarations:Array<IrEnum>;
	final enumNodes:Map<String, Int> = [];
	final objectNodes:Map<String, Int> = [];
	final interfaceNodes:Map<String, Int> = [];
	final names:Array<String>;
	final nodes:Array<EnumUseNode> = [];
	final words:Int;
	final rejected:Array<Int>;

	public function new(program:IrProgram, planner:IrInlineEnumLayout, ?reflectableObjects:Array<String>) {
		declarations = program.enums;
		objects = [for (object in program.objects) object.name => object];
		names = [for (declaration in program.enums) declaration.name];
		words = (names.length + 31) >> 5;
		rejected = [for (_ in 0...words) 0];
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
		for (declaration in program.enums) {
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
			if (!StringTools.startsWith(native.name, "__array_")) {
				for (argument in native.arguments)
					escape(argument, "native signature");
				escape(native.result, "native signature");
			}
		// Reflection helpers are generated after storage selection and can expose every registered layout.
		if (ObjectReflection.usesObjectLayouts(program.natives)) {
			var reflectedNames = reflectableObjects == null ? [] : reflectableObjects,
				reflected = [for (name in reflectedNames) name => true];
			for (object in program.objects)
				if (reflected.exists(object.name)
					|| object.isValue
					|| StringTools.startsWith(object.name, IrValueInterfaceBoxes.BOX_PREFIX))
					mark(objectNodes.get(object.name), "registered reflection layout");
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
				otherDescriptors:Map<Int, Bool> = [],
				factoryCasts:Map<Int, Bool> = [],
				factoryErases:Map<Int, Bool> = [],
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
			for (block in fn.blocks)
				for (position in 0...block.instructions.length)
					switch block.instructions[position].value {
						case Call(raw, "__array_alloc_typed_ref", arguments) if (arguments.length == 2
							&& position + 2 < block.instructions.length):
							switch [block.instructions[position + 1].value, block.instructions[position + 2].value] {
								case [ToDyn(erased, source), SafeCast(out, input)] if (source.id == raw.id && input.id == erased.id):
									// The shared array pass verifies the descriptor and unique temporary uses before lowering this protocol.
									switch out.type {
										case Array(_):
											factoryCasts.set(out.id, true);
											factoryErases.set(erased.id, true);
										default:
									}
								default:
							}
						default:
					}
			for (block in fn.blocks) {
				for (located in block.instructions) {
					var instruction = located.value;
					for (input in IrOperands.inputs(instruction))
						if (descriptors.exists(input.id))
							switch instruction {
								case Call(_, "__array_alloc_typed_ref", arguments) if (arguments.length == 2 && arguments[1].id == input.id):
									arrayDescriptors.set(input.id, true);
								default:
									otherDescriptors.set(input.id, true);
							}
					switch instruction {
						case ToDyn(out, value) if (!factoryErases.exists(out.id)):
							escape(value.type, "Dynamic escape");
						case SafeCast(out, value) if (!factoryCasts.exists(out.id)):
							escape(out.type, "checked escape");
							escape(value.type, "checked escape");
						case Phi(_, inputs):
							for (input in inputs)
								if (descriptors.exists(input.value.id))
									otherDescriptors.set(input.value.id, true);
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
									callableValue(out.type, "bound value method");
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
			for (id => type in descriptors)
				if (!arrayDescriptors.exists(id) || otherDescriptors.exists(id))
					escape(type, "runtime type descriptor");
		}
		for (name in names)
			if (!reasons.exists(name))
				allowed.set(name, true);
	}

	// Native structs need the independent canonical layout, not target-specific pointer offsets.
	function nativePayload(type:IrType, seen:Array<String>):Bool
		return switch type {
			case Enum(name):
				if (seen.contains(name)) false; else {
					var declaration:Null<IrEnum> = null;
					for (candidate in declarations)
						if (candidate.name == name) {
							declaration = candidate;
							break;
						}
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
				if ((fresh & (1 << bit)) != 0)
					reasons.set(names[(word << 5) + bit], reason);
		}
	}

	function block(name:String, reason:String):Void
		mark(enumNodes.get(name), reason);

	function escape(type:IrType, reason:String):Void
		switch type {
			case Enum(name):
				block(name, reason);
			case Obj(name):
				mark(objectNodes.get(name), reason);
			case Virtual(name):
				mark(interfaceNodes.get(name), reason);
			case Nullable(inner), Array(inner), Iterator(inner):
				escape(inner, reason);
			case Function(arguments, result):
				for (argument in arguments)
					escape(argument, reason);
				escape(result, reason);
			default:
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

	function callableValue(type:IrType, reason:String):Void
		switch type {
			case Function(arguments, result):
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

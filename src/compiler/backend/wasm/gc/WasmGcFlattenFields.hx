package compiler.backend.wasm.gc;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrInlineValueLayout;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.IrInliner;
import compiler.ir.IrOperands;
import compiler.ir.IrObjectTable;
import compiler.ir.IrScalarReplacement;
import compiler.ir.hl.PhiEdges;
import compiler.ir.SourceProvenance.Located;

private typedef FlattenedPlace = {
	final owner:IrValue;
	final path:Array<String>;
	final typeName:String;
}
private typedef PlaceMethod = {final name:String; final original:String; final owner:String; final path:Array<String>; final typeName:String;}

/** Rewrites field places to physical leaf accesses before Wasm GC type planning. */
class WasmGcFlattenFields {
	/** A pseudo-field lowered as a null check on the holder, with no actual storage slot. */
	public static inline final CHECK_FIELD = "$wasm-gc:check-holder";

	final program:IrProgram;
	final declarations:Map<String, IrObject>;
	final values:WasmGcValueLayout;
	final objects:IrObjectTable;
	final originals:Map<String, IrFunction>;
	final methods:Array<PlaceMethod> = [];
	final requested:Map<String, Bool> = [];
	final scalarSignatures:Map<String, WasmGcScalarAbi.WasmGcScalarSignature>;

	public function new(program:IrProgram, ?scalarSignatures:Map<String, WasmGcScalarAbi.WasmGcScalarSignature>) {
		this.program = program;
		declarations = [for (object in program.objects) object.name => object];
		objects = IrObjectTable.of(declarations);
		values = new WasmGcValueLayout(program);
		originals = [for (fn in program.functions) fn.name => fn];
		this.scalarSignatures = scalarSignatures == null ? [] : scalarSignatures;
	}

	public function rewrite():IrProgram {
		var functions:Array<IrFunction> = [];
		for (original in program.functions) {
			var signature = scalarSignatures.get(original.name),
				fn = signature != null && signature.throwsReceiver ? original : IrScalarReplacement.rewrite(original, objects, true),
				rewritten = rewriteFunction(fn, null);
			functions.push(rewritten);
		}
		var methodIndex = 0;
		while (methodIndex < methods.length) {
			var method = methods[methodIndex++], original = originals.get(method.original);
			if (original == null || original.arguments.length == 0) throw 'Missing Wasm GC place method "${method.original}"';
			var next = nextId(original), owner = new IrValue(next, "$wasm-gc-place-owner", Obj(method.owner)),
				args = [owner].concat(original.arguments.slice(1)),
				clone = new IrFunction(method.name, args, original.result, original.blocks, [], original.inlineHint),
				place:FlattenedPlace = {owner: owner, path: method.path, typeName: method.typeName};
			var rewritten = rewriteFunction(clone, {id: original.arguments[0].id, place: place});
			functions.push(rewritten);
		}
		var result = new IrProgram(program.entryPoint);
		result.natives = program.natives;
		result.cNatives = program.cNatives;
		result.functions = functions;
		result.objects = program.objects;
		result.interfaces = program.interfaces;
		result.enums = program.enums;
		result.staticFields = program.staticFields;
		result.positionalFingerprints = program.positionalFingerprints;
		result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		return result;
	}

	public function retainOriginals(reachable:Map<String, Bool>, roots:Array<String>):Bool {
		var added = false;
		for (method in methods) if (reachable.exists(method.name) && roots.indexOf(method.original) < 0) {
			roots.push(method.original); added = true;
		}
		return added;
	}

	function rewriteFunction(fn:IrFunction, seed:Null<{id:Int, place:FlattenedPlace}>):IrFunction {
		// Materializing a phi input may dereference its holder, so do it only on the selected edge.
		fn = PhiEdges.split(fn);
		var aliases:Map<Int, FlattenedPlace> = [], changed = true, next = 0;
		if (seed != null) aliases.set(seed.id, seed.place);
		for (argument in fn.arguments) if (argument.id >= next) next = argument.id + 1;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && output.id >= next) next = output.id + 1;
				switch located.value {
					case FieldGet(out, owner, field) if (values.isValue(out.type) && !aliases.exists(out.id)):
						var name = switch out.type { case Obj(value): value; default: throw "Invalid value projection"; };
						var parent = aliases.get(owner.id);
						aliases.set(out.id, parent == null ? {owner: owner, path: [field], typeName: name} :
							{owner: parent.owner, path: parent.path.concat([field]), typeName: name});
						changed = true;
					default:
				}
			}
		}
		var blocks:Array<IrBlock> = [], edgeCopies:Map<Int, Array<Located<IrInstruction>>> = [];
		for (block in fn.blocks) {
			var replacement = new IrBlock(block.id);
			for (position in 0...block.instructions.length) {
				var located = block.instructions[position];
				switch located.value {
				case Phi(out, inputs):
					var mapped:Array<IrPhiInput> = [];
					for (input in inputs) {
						var edge = new IrBlock(input.block), actual = materialize(input.value, aliases, edge, located, next);
						next = actual.next;
						if (edge.instructions.length > 0) {
							if (!edgeCopies.exists(input.block)) edgeCopies.set(input.block, []);
							for (instruction in edge.instructions) edgeCopies.get(input.block).push(instruction);
						}
						mapped.push({block: input.block, value: actual.value});
					}
					replacement.instructions.push(new Located(Phi(out, mapped), located.provenance));
				case FieldGet(out, object, field) if (aliases.exists(out.id)):
					// Preserve the original null access point even when the field projection itself has no scalar load.
					if (!aliases.exists(object.id) && !immediateLeafAccess(block, position, aliases.get(out.id), aliases)) {
						var check = new IrValue(next++, "$wasm-gc-holder-check", I32);
						replacement.instructions.push(new Located(FieldGet(check, object, CHECK_FIELD), located.provenance));
					}
				case FieldGet(out, object, field) if (aliases.exists(object.id)):
					var place = aliases.get(object.id);
					replacement.instructions.push(new Located(FieldGet(out, place.owner, physical(place.owner.type, place.path.concat([field]))), located.provenance));
				case FieldSet(object, field, value):
					var target = aliases.get(object.id), owner = target == null ? object : target.owner,
						path = target == null ? [field] : target.path.concat([field]), source = aliases.get(value.id),
						declared = findField(target == null ? object.type : Obj(target.typeName), field);
					if (declared != null && values.isValue(declared.type)) {
						var check = new IrValue(next++, "$wasm-gc-holder-check", I32);
						replacement.instructions.push(new Located(FieldGet(check, owner, CHECK_FIELD), located.provenance));
						var snapshot:Array<{field:String, value:IrValue}> = [];
						for (slot in values.leaves(declared.type)) {
							var loaded = new IrValue(next++, "$wasm-gc-copy-field", slot.type), sourceOwner = source == null ? value : source.owner,
								sourcePath = source == null ? slot.path : source.path.concat(slot.path);
							replacement.instructions.push(new Located(FieldGet(loaded, sourceOwner, physical(sourceOwner.type, sourcePath)), located.provenance));
							snapshot.push({field: physical(owner.type, path.concat(slot.path)), value: loaded});
						}
						for (entry in snapshot) replacement.instructions.push(new Located(FieldSet(owner, entry.field, entry.value), located.provenance));
					} else {
						var actual = materialize(value, aliases, replacement, located, next);
						next = actual.next;
						replacement.instructions.push(new Located(FieldSet(owner, target == null ? field : physical(owner.type, path), actual.value),
							located.provenance));
					}
				case MethodCall(out, receiver, method, arguments) if (aliases.exists(receiver.id)):
					var place = aliases.get(receiver.id), target = methodName(place.typeName, method);
					if (target == null) throw 'Missing Wasm GC method "${place.typeName}.$method"';
					var args:Array<IrValue> = [place.owner];
					for (argument in arguments) {
						var actual = materialize(argument, aliases, replacement, located, next);
						next = actual.next; args.push(actual.value);
					}
					replacement.instructions.push(new Located(Call(out, requestMethod(place, target), args), located.provenance));
				case Call(out, name, arguments) if (arguments.length > 0 && aliases.exists(arguments[0].id)
						&& isPlaceMethod(aliases.get(arguments[0].id).typeName, name)):
					var place:FlattenedPlace = cast aliases.get(arguments[0].id);
					var args:Array<IrValue> = [place.owner];
					for (argument in arguments.slice(1)) {
						var actual = materialize(argument, aliases, replacement, located, next);
						next = actual.next; args.push(actual.value);
					}
					replacement.instructions.push(new Located(Call(out, requestMethod(place, name), args), located.provenance));
				case InstanceClosure(out, name, receiver) if (aliases.exists(receiver.id)):
					var place = aliases.get(receiver.id);
					if (isPlaceMethod(place.typeName, name))
						replacement.instructions.push(new Located(InstanceClosure(out, requestMethod(place, name), place.owner), located.provenance));
					else {
						var actual = materialize(receiver, aliases, replacement, located, next);
						next = actual.next;
						replacement.instructions.push(new Located(InstanceClosure(out, name, actual.value), located.provenance));
					}
				default:
					var substitutions:Map<Int, IrValue> = [];
					for (input in IrOperands.inputs(located.value)) if (aliases.exists(input.id) && !substitutions.exists(input.id)) {
						var actual = materialize(input, aliases, replacement, located, next);
						next = actual.next; substitutions.set(input.id, actual.value);
					}
					var instruction = substitutions.keys().hasNext() ?
						IrInliner.remap(located.value, value -> substitutions.exists(value.id) ? substitutions.get(value.id) : value, id -> id) : located.value;
					replacement.instructions.push(new Located(instruction, located.provenance));
				}
			}
			var terminator = block.terminator;
			if (terminator != null) {
				var input = switch terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): value;
					default: null;
				};
				if (input != null && aliases.exists(input.id)) {
					var anchor = new Located(ConstVoid(new IrValue(-1, "", Void)), terminator.provenance),
						actual = materialize(input, aliases, replacement, anchor, next);
					next = actual.next;
					var rewritten = switch terminator.value {
						case Return(_): Return(actual.value);
						case Throw(_): Throw(actual.value);
						case Rethrow(_): Rethrow(actual.value);
						case Branch(_, yes, no): Branch(actual.value, yes, no);
						default: terminator.value;
					};
					terminator = new Located(rewritten, terminator.provenance);
				}
			}
			replacement.terminator = terminator;
			blocks.push(replacement);
		}
		for (block in blocks) if (edgeCopies.exists(block.id))
			for (instruction in edgeCopies.get(block.id)) block.instructions.push(instruction);
		var bindings = [for (binding in fn.debugBindings) if (!aliases.exists(binding.value.id)) binding];
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, bindings, fn.inlineHint, fn.retention);
	}

	/** Fold a holder check into an immediately following scalar access, without moving it across evaluation. */
	static function immediateLeafAccess(block:IrBlock, position:Int, root:FlattenedPlace, aliases:Map<Int, FlattenedPlace>):Bool {
		for (index in position + 1...block.instructions.length) switch block.instructions[index].value {
			case FieldGet(out, object, _) if (aliases.exists(object.id)):
				var place = aliases.get(object.id);
				if (!isWithin(place, root)) return false;
				if (!aliases.exists(out.id)) return true;
			case FieldSet(object, _, _) if (aliases.exists(object.id)):
				return isWithin(aliases.get(object.id), root);
			default: return false;
		}
		return false;
	}

	static function isWithin(place:FlattenedPlace, root:FlattenedPlace):Bool {
		if (place.owner.id != root.owner.id || place.path.length < root.path.length) return false;
		for (index in 0...root.path.length) if (place.path[index] != root.path[index]) return false;
		return true;
	}

	/** Materialize only at a reference-based boundary, after taking a snapshot of every field. */
	function materialize(value:IrValue, aliases:Map<Int, FlattenedPlace>, block:IrBlock, origin:Located<IrInstruction>,
			next:Int):{value:IrValue, next:Int} {
		var place = aliases.get(value.id);
		if (place == null) return {value: value, next: next};
		var copy = new IrValue(next++, "$wasm-gc-place-copy", value.type);
		block.instructions.push(new Located(NewObject(copy, place.typeName), origin.provenance));
		for (slot in values.leaves(value.type)) {
			var leaf = new IrValue(next++, "$wasm-gc-place-leaf", slot.type);
			block.instructions.push(new Located(FieldGet(leaf, place.owner, physical(place.owner.type, place.path.concat(slot.path))), origin.provenance));
			block.instructions.push(new Located(FieldSet(copy, physical(copy.type, slot.path), leaf), origin.provenance));
		}
		return {value: copy, next: next};
	}

	function requestMethod(place:FlattenedPlace, original:String):String {
		var owner = valueName(place.owner.type), name = "$wasm-gc-place:" + owner.length + ":" + owner;
		for (part in place.path) name += ":" + part.length + ":" + part;
		name += ":method:" + original.length + ":" + original;
		if (!requested.exists(name)) {
			requested.set(name, true);
			methods.push({name: name, original: original, owner: owner, path: place.path.copy(), typeName: place.typeName});
		}
		return name;
	}

	function methodName(owner:String, name:String):Null<String> {
		var current:Null<String> = owner;
		while (current != null) {
			var object = declarations.get(current);
			if (object == null) return null;
			for (method in object.methods) if (method.name == name) return method.functionName;
			current = object.base;
		}
		return null;
	}

	function isPlaceMethod(owner:String, name:String):Bool {
		if (StringTools.startsWith(name, "$generic:")) {
			var fn = originals.get(name);
			return fn != null && fn.arguments.length > 0 && fn.arguments[0].name == "this";
		}
		var current:Null<String> = owner;
		while (current != null) {
			var object = declarations.get(current);
			if (object == null) return false;
			for (method in object.methods) if (method.functionName == name) return true;
			current = object.base;
		}
		return false;
	}

	static function valueName(type:IrType):String
		return switch type { case Obj(name): name; default: throw 'Expected an object type, got $type'; };

	static function nextId(fn:IrFunction):Int {
		var next = 0;
		for (argument in fn.arguments) if (argument.id >= next) next = argument.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var output = IrOperands.output(located.value);
			if (output != null && output.id >= next) next = output.id + 1;
		}
		return next;
	}

	/** Translate a logical field path to its one physical GC field. */
	function physical(type:IrType, path:Array<String>):String {
		if (path.length == 0) throw "Empty Wasm GC field path";
		if (path.length == 1) return path[0];
		var field = findField(type, path[0]);
		if (field == null || !values.isValue(field.type)) throw 'Invalid Wasm GC field path ${path.join(".")}';
		for (slot in values.leaves(field.type)) {
			if (slot.path.length != path.length - 1) continue;
			var matches = true;
			for (index in 0...slot.path.length) if (slot.path[index] != path[index + 1]) matches = false;
			if (matches) return WasmGcValueLayout.fieldName(path[0], slot);
		}
		throw 'Missing Wasm GC leaf ${path.join(".")}';
	}

	function findField(type:IrType, field:String):Null<IrObjectField> {
		var name = switch type { case Obj(value): value; default: return null; };
		while (name != null) {
			var object = declarations.get(name);
			if (object == null) return null;
			for (candidate in object.fields) if (candidate.name == field) return candidate;
			name = object.base;
		}
		return null;
	}
}

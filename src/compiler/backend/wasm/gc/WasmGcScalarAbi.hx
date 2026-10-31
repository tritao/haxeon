package compiler.backend.wasm.gc;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.IrOperands;
import compiler.ir.IrVerifier;
import compiler.ir.SourceProvenance.Located;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmProgramIndex;

/** Source signature retained while a direct function uses scalar Wasm parameters and results. */
typedef WasmGcScalarSignature = {
	final arguments:Array<IrType>;
	final result:IrType;
	final mutatesReceiver:Bool;
	final throwsReceiver:Bool;
	final receiverId:Int;
}
typedef WasmGcScalarVirtualTarget = {final typeName:String; final clone:String;}
typedef WasmGcScalarVirtual = {final signature:WasmGcScalarSignature; final targets:Array<WasmGcScalarVirtualTarget>;}

/** Expands direct value calls before field flattening. Dynamic and method boundaries retain their reference ABI. */
class WasmGcScalarAbi {
	public static inline final RETURN_MARKER = "$wasm-gc:scalar-return";
	public static inline final RESULT_FIELD_PREFIX = "$wasm-gc:scalar-result:";
	public static inline final RETHROW_MARKER = "$wasm-gc:scalar-rethrow";

	public final signatures:Map<String, WasmGcScalarSignature> = [];
	/** Function types whose typed closure calls use the scalar ABI without an adapter. */
	public final scalarClosures:Map<String, Bool> = [];
	public final scalarVirtuals:Map<String, WasmGcScalarVirtual> = [];
	final program:IrProgram;
	final values:WasmGcValueLayout;
	final objects:Map<String, IrObject>;
	final methodClones:Map<String, String> = [];
	final receiverSafe:Map<String, Bool> = [];
	final valueMethods:Map<String, Bool> = [];
	final directClones:Map<String, String> = [];
	final originals:Map<String, IrFunction>;
	final roots:Array<String>;

	public function new(program:IrProgram, ?exports:Array<String>) {
		this.program = program;
		values = new WasmGcValueLayout(program);
		objects = [for (object in program.objects) object.name => object];
		originals = [for (fn in program.functions) fn.name => fn];
		roots = exports == null ? [] : exports.copy();
		var instanceMethods:Map<String, Bool> = [];
		for (object in program.objects) if (object.isValue) {
			instanceMethods.set(object.name + ".new", true);
			for (method in object.methods) instanceMethods.set(method.functionName, true);
		}
		for (fn in program.functions)
			if (StringTools.startsWith(fn.name, "$generic:") && fn.arguments.length > 0 && fn.arguments[0].name == "this"
				&& values.isValue(fn.arguments[0].type))
				instanceMethods.set(fn.name, true);
		for (fn in program.functions) {
			if ((StringTools.startsWith(fn.name, "$") && !StringTools.startsWith(fn.name, "$generic:")
					&& !StringTools.startsWith(fn.name, "$lambda:")) || instanceMethods.exists(fn.name)) continue;
			var args = [for (argument in fn.arguments) argument.type], hasValue = values.isValue(fn.result), safe = scalarizable(fn.result);
			for (argument in args) { if (values.isValue(argument)) hasValue = true; if (!scalarizable(argument)) safe = false; }
			if (hasValue && safe) {
				var name = "$wasm-gc:scalar-function:" + fn.name.length + ":" + fn.name;
				directClones.set(fn.name, name);
				signatures.set(name, {arguments: args, result: fn.result, mutatesReceiver: false, throwsReceiver: false, receiverId: -1});
			}
		}
		var methodNames:Array<String> = [];
		for (object in program.objects) if (object.isValue) {
			methodNames.push(object.name + ".new");
			for (method in object.methods) methodNames.push(method.functionName);
		}
		for (fn in program.functions)
			if (StringTools.startsWith(fn.name, "$generic:") && fn.arguments.length > 0 && fn.arguments[0].name == "this"
				&& values.isValue(fn.arguments[0].type)) methodNames.push(fn.name);
		for (name in methodNames) valueMethods.set(name, true);
		var candidates:Map<String, Bool> = [];
		for (name in methodNames) {
			var fn = originals.get(name);
			if (fn == null || fn.arguments.length == 0 || !values.isValue(fn.arguments[0].type) || !scalarizable(fn.result)) continue;
			var safe = true;
			for (argument in fn.arguments) if (!scalarizable(argument.type)) safe = false;
			if (safe) candidates.set(name, true);
		}
		// A scalar method must not publish a reference to its receiver. Starting with every candidate handles recursion.
		var changed = true;
		while (changed) {
			changed = false;
			for (name in methodNames) if (candidates.exists(name)) {
				var fn = originals.get(name);
				if (fn == null || !receiverDoesNotEscape(fn, candidates)) { candidates.remove(name); changed = true; }
			}
		}
		var safeCandidates:Map<String, Bool> = [for (name in methodNames) if (candidates.exists(name)) name => true];
		changed = true;
		while (changed) {
			changed = false;
			for (name in methodNames) if (safeCandidates.exists(name)) {
				var fn = originals.get(name);
				if (fn == null || !safeReceiver(fn, safeCandidates)) { safeCandidates.remove(name); changed = true; }
			}
		}
		for (name in methodNames) if (safeCandidates.exists(name)) receiverSafe.set(name, true);
		var throwing:Map<String, Bool> = [];
		for (name in methodNames) if (candidates.exists(name)) {
			var fn = originals.get(name);
			if (!safeCandidates.exists(name) || (fn != null && directlyThrows(fn))) throwing.set(name, true);
		}
		changed = true;
		while (changed) {
			changed = false;
			for (name in methodNames) if (candidates.exists(name) && !throwing.exists(name)) {
				var fn = originals.get(name);
				if (fn != null && callsThrowingMethod(fn, throwing)) { throwing.set(name, true); changed = true; }
			}
		}
		for (name in methodNames) if (candidates.exists(name) && !methodClones.exists(name)) {
			var fn = originals.get(name);
			if (fn == null) throw 'Missing scalar method "$name"';
			var args = [for (argument in fn.arguments) argument.type], clone = "$wasm-gc:scalar-method:" + name.length + ":" + name;
			methodClones.set(name, clone);
			signatures.set(clone, {arguments: args, result: fn.result, mutatesReceiver: true,
				throwsReceiver: throwing.exists(name), receiverId: fn.arguments[0].id});
		}
		planScalarVirtuals();
		planScalarClosures();
	}

	function scalarizable(type:IrType):Bool {
		if (!values.isValue(type)) return true;
		for (slot in values.leaves(type)) if (slot.isPresence) return false;
		return true;
	}

	public static function virtualKey(receiver:IrType, method:String):String
		return Std.string(receiver) + ":" + method.length + ":" + method;

	function planScalarVirtuals():Void {
		var index = WasmProgramIndex.of(program), seen:Map<String, Bool> = [];
		for (fn in program.functions) for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case MethodCall(out, receiver, method, _) if (!values.isValue(receiver.type)):
				var key = virtualKey(receiver.type, method);
				if (seen.exists(key)) continue;
				seen.set(key, true);
				var possible:Array<IrObject> = switch receiver.type {
					case Obj(name): index.subtypesOf(name);
					case Virtual(name): index.implementorsOf(name);
					default: [];
				};
				var targets:Array<WasmGcScalarVirtualTarget> = [], arguments:Null<Array<IrType>> = null,
					result:IrType = out.type, valid = possible.length > 0, hasValue = values.isValue(result);
				for (object in possible) {
					if (object.isValue) { valid = false; break; }
					var original = index.findMethod(object.name, method), clone = original == null ? null : directClones.get(original),
						target = original == null ? null : originals.get(original);
					if (clone == null || target == null || target.arguments.length == 0 || !IrVerifier.sameType(target.result, result)) {
						valid = false; break;
					}
					var params = [for (argument in target.arguments.slice(1)) argument.type];
					if (arguments == null) arguments = params;
					else if (arguments.length != params.length) { valid = false; break; }
					else for (position in 0...params.length) if (!IrVerifier.sameType(arguments[position], params[position])) valid = false;
					for (type in params) if (values.isValue(type)) hasValue = true;
					targets.push({typeName: object.name, clone: clone});
				}
				if (valid && hasValue && arguments != null) {
					targets.sort((left, right) -> depth(right.typeName) - depth(left.typeName));
					scalarVirtuals.set(key, {signature: {arguments: arguments, result: result, mutatesReceiver: false, throwsReceiver: false, receiverId: -1}, targets: targets});
				}
			default:
		}
	}

	function depth(name:String):Int {
		var result = 0, current:Null<String> = name;
		while (current != null) {
			var object = objects.get(current);
			if (object == null) break;
			result++; current = object.base;
		}
		return result;
	}

	/** Keep closure casts and Dynamic calls on their existing boxed adapter ABI. */
	function planScalarClosures():Void {
		var candidates:Map<String, Bool> = [], excluded:Map<String, Bool> = [], castArities:Map<Int, Bool> = [],
			entry = WasmModuleSupport.hasFunction(program, "main") ? "main" :
				WasmModuleSupport.hasFunction(program, "Main.main") ? "Main.main" : program.entryPoint;
		if (WasmModuleSupport.hasFunction(program, "__init")) roots.push("__init");
		var reachable = WasmModuleSupport.reachableFunctionsWithGeneratedRuntimeRoots(program, entry, roots);
		for (fn in program.functions) if (fn.name == entry || roots.indexOf(fn.name) >= 0 || fn.retention != Reachable) {
			for (argument in fn.arguments) if (closureArity(argument.type) >= 0) excluded.set(Std.string(argument.type), true);
			if (closureArity(fn.result) >= 0) excluded.set(Std.string(fn.result), true);
		}
		for (native in program.natives) {
			for (argument in native.arguments) if (closureArity(argument) >= 0) excluded.set(Std.string(argument), true);
			if (closureArity(native.result) >= 0) excluded.set(Std.string(native.result), true);
		}
		for (fn in program.functions) if (reachable.exists(fn.name)) for (block in fn.blocks) for (located in block.instructions)
			switch located.value {
				case StaticClosure(out, name):
					if (noteClosure(out.type, candidates) && !directClones.exists(name)) excluded.set(Std.string(out.type), true);
				case InstanceClosure(out, name, receiver):
					if (noteClosure(out.type, candidates) && (values.isValue(receiver.type) || !directClones.exists(name)))
						excluded.set(Std.string(out.type), true);
				case CallClosure(_, closure, arguments):
					if (closure.type == Dyn) castArities.set(arguments.length, true); else noteClosure(closure.type, candidates);
				case SafeCast(out, input):
					var targetArity = closureArity(out.type), sourceArity = closureArity(input.type);
					if (targetArity >= 0) castArities.set(targetArity, true);
					if (sourceArity >= 0) castArities.set(sourceArity, true);
				case ToDyn(_, input):
					if (closureArity(input.type) >= 0) excluded.set(Std.string(input.type), true);
				default:
			}
		for (fn in program.functions) if (reachable.exists(fn.name)) for (block in fn.blocks) {
			for (located in block.instructions) {
				for (input in IrOperands.inputs(located.value))
					if (closureArity(input.type) >= 0 && !safeClosureUse(located.value, input)) excluded.set(Std.string(input.type), true);
				switch located.value {
					case Phi(out, inputs): for (input in inputs)
						if (closureArity(input.value.type) >= 0 && !IrVerifier.sameType(input.value.type, out.type))
							excluded.set(Std.string(input.value.type), true);
					default:
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value) if (closureArity(value.type) >= 0 && !IrVerifier.sameType(value.type, fn.result)):
					excluded.set(Std.string(value.type), true);
				case Throw(value), Rethrow(value) if (closureArity(value.type) >= 0): excluded.set(Std.string(value.type), true);
				default:
			}
		}
		for (key in candidates.keys())
			if (!excluded.exists(key)) scalarClosures.set(key, true);
		if (castArities.keys().hasNext()) {
			// Cast adapters can receive any created signature of the same arity.
			var remove:Array<String> = [];
			for (fn in program.functions) if (reachable.exists(fn.name)) for (block in fn.blocks) for (located in block.instructions)
				switch located.value {
					case StaticClosure(out, _), InstanceClosure(out, _, _):
						if (castArities.exists(closureArity(out.type))) remove.push(Std.string(out.type));
					case CallClosure(_, closure, _):
						if (castArities.exists(closureArity(closure.type))) remove.push(Std.string(closure.type));
					default:
				}
			for (key in remove) scalarClosures.remove(key);
		}
	}

	function safeClosureUse(instruction:IrInstruction, value:IrValue):Bool {
		return switch instruction {
			case Call(_, name, arguments):
				var target = originals.get(name), expected:Null<Array<IrType>> = target == null ? null : [for (arg in target.arguments) arg.type];
				if (expected == null) for (native in program.natives) if (native.name == name) expected = native.arguments;
				if (expected == null) false; else {
					var safe = arguments.length == expected.length;
					if (safe) for (index in 0...arguments.length)
						if (arguments[index].id == value.id && !IrVerifier.sameType(value.type, expected[index])) safe = false;
					safe;
				}
			case CallClosure(_, closure, arguments):
				switch closure.type {
					case Function(expected, _):
						var safe = expected.length == arguments.length;
						if (safe) for (index in 0...arguments.length)
							if (arguments[index].id == value.id && !IrVerifier.sameType(value.type, expected[index])) safe = false;
						safe;
					default: false;
				}
			case FieldSet(owner, name, stored) if (stored.id == value.id):
				var field = lookupField(owner.type, name);
				field != null && IrVerifier.sameType(value.type, field.type);
			case ArraySet(array, _, stored) if (stored.id == value.id):
				switch array.type { case Array(element): IrVerifier.sameType(value.type, element); default: false; }
			case GlobalSet(name, stored) if (stored.id == value.id):
				var safe = false;
				for (field in program.staticFields) if (field.name == name) safe = IrVerifier.sameType(value.type, field.type);
				safe;
			case Equal(_, _, _): true;
			default: false;
		};
	}

	function lookupField(type:IrType, name:String):Null<IrObjectField> {
		var owner:Null<String> = switch type { case Obj(value): value; default: null; };
		while (owner != null) {
			var object = objects.get(owner);
			if (object == null) return null;
			for (field in object.fields) if (field.name == name) return field;
			owner = object.base;
		}
		return null;
	}

	function noteClosure(type:IrType, candidates:Map<String, Bool>):Bool {
		return switch type {
			case Function(arguments, result):
				var hasValue = values.isValue(result), safe = scalarizable(result);
				for (argument in arguments) { if (values.isValue(argument)) hasValue = true; if (!scalarizable(argument)) safe = false; }
				if (hasValue && safe) candidates.set(Std.string(type), true);
				hasValue && safe;
			default: false;
		};
	}

	static function closureArity(type:IrType):Int
		return switch type { case Function(arguments, _): arguments.length; default: -1; };

	/** The receiver may be scalarized when no reference to its place escapes the method. */
	function receiverDoesNotEscape(fn:IrFunction, candidates:Map<String, Bool>):Bool {
		var aliases:Map<Int, Bool> = [fn.arguments[0].id => true], changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case FieldGet(out, owner, _) if (aliases.exists(owner.id) && values.isValue(out.type) && !aliases.exists(out.id)):
					aliases.set(out.id, true); changed = true;
				default:
			}
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case Phi(_, inputs): for (input in inputs) if (aliases.exists(input.value.id)) return false;
					default:
				}
				var touches = false;
				for (input in IrOperands.inputs(located.value)) if (aliases.exists(input.id)) touches = true;
				if (!touches) continue;
				switch located.value {
					case FieldGet(_, owner, _) if (aliases.exists(owner.id)):
					case FieldSet(owner, field, value) if (aliases.exists(owner.id)):
						if (aliases.exists(value.id)) {
							var declared = lookupField(owner.type, field);
							if (declared == null || !values.isValue(declared.type)) return false;
						}
					case Call(_, name, arguments) if (candidates.exists(name) && arguments.length > 0 && aliases.exists(arguments[0].id)):
						for (argument in arguments.slice(1)) if (aliases.exists(argument.id)) return false;
					case MethodCall(_, owner, method, arguments) if (aliases.exists(owner.id)):
						var target = resolveMethod(owner.type, method);
						if (target == null || !candidates.exists(target)) return false;
						for (argument in arguments) if (aliases.exists(argument.id)) return false;
					default: return false;
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Return(value), Throw(value), Rethrow(value), Branch(value, _, _) if (aliases.exists(value.id)): return false;
				default:
			}
		}
		return true;
	}

	/** A receiver can be written back at return when no callback can observe its intermediate state. */
	function safeReceiver(fn:IrFunction, candidates:Map<String, Bool>):Bool {
		var aliases:Map<Int, Bool> = [for (argument in fn.arguments) if (values.isValue(argument.type)) argument.id => true], changed = true;
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case NewObject(out, _) if (values.isValue(out.type) && !aliases.exists(out.id)):
					aliases.set(out.id, true); changed = true;
				case FieldGet(out, owner, _) if (aliases.exists(owner.id) && values.isValue(out.type) && !aliases.exists(out.id)):
					aliases.set(out.id, true); changed = true;
				default:
			}
		}
		for (block in fn.blocks) {
			for (located in block.instructions) switch located.value {
				case Phi(_, inputs): for (input in inputs) if (aliases.exists(input.value.id)) return false;
				case FieldGet(_, owner, _), FieldSet(owner, _, _) if (aliases.exists(owner.id)):
				case NewObject(out, _) if (values.isValue(out.type)):
				case Call(_, name, args) if (candidates.exists(name) && args.length > 0 && aliases.exists(args[0].id)):
				case MethodCall(_, owner, method, _) if (aliases.exists(owner.id)):
					var target = resolveMethod(owner.type, method);
					if (target == null || !candidates.exists(target)) return false;
				case ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), ConstBool(_, _), ConstNull(_), ToDyn(_, _),
					Add(_, _, _), Sub(_, _, _), Mul(_, _, _), BitAnd(_, _, _), BitXor(_, _, _), BitOr(_, _, _),
					ShiftLeft(_, _, _), ShiftRight(_, _, _), UnsignedShiftRight(_, _, _), Less(_, _, _), LessEqual(_, _, _), Equal(_, _, _),
					IntToFloat(_, _), IntToInt64(_, _), FloatToFloat(_, _):
					for (input in IrOperands.inputs(located.value)) if (aliases.exists(input.id)) return false;
				case BeginTry(_, _), EndTry(_), Catch(_):
				default: return false;
			}
			if (block.terminator == null) return false;
			switch block.terminator.value {
				case Branch(value, _, _) if (aliases.exists(value.id)): return false;
				case Return(_), Throw(_), Rethrow(_), Branch(_, _, _), Jump(_):
				default: return false;
			}
		}
		return true;
	}

	static function directlyThrows(fn:IrFunction):Bool {
		for (block in fn.blocks) if (block.terminator != null) switch block.terminator.value {
			case Throw(_), Rethrow(_): return true;
			default:
		}
		return false;
	}

	function callsThrowingMethod(fn:IrFunction, throwing:Map<String, Bool>):Bool {
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case Call(_, name, _) if (throwing.exists(name)): return true;
			case MethodCall(_, receiver, method, _):
				var target = values.isValue(receiver.type) ? resolveMethod(receiver.type, method) : null;
				if (target != null && throwing.exists(target)) return true;
			default:
		}
		return false;
	}

	/** Values without an exposed place can defer receiver writes across a reentrant method call. */
	function isolatedValues(fn:IrFunction):Map<Int, Bool> {
		var roots:Map<Int, Int> = [], valid:Map<Int, Bool> = [], changed = true;
		for (argument in fn.arguments) if (values.isValue(argument.type) && !(argument.name == "this" && valueMethods.exists(fn.name))) {
			roots.set(argument.id, argument.id); valid.set(argument.id, true);
		}
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case NewObject(out, _) if (values.isValue(out.type)): roots.set(out.id, out.id); valid.set(out.id, true);
			default:
		}
		while (changed) {
			changed = false;
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case FieldGet(out, owner, _) if (roots.exists(owner.id) && values.isValue(out.type) && !roots.exists(out.id)):
					roots.set(out.id, roots.get(owner.id)); changed = true;
				default:
			}
		}
		for (block in fn.blocks) {
			for (located in block.instructions) {
				switch located.value {
					case Phi(_, inputs): for (input in inputs) if (roots.exists(input.value.id)) valid.set(roots.get(input.value.id), false);
					default:
				}
				for (input in IrOperands.inputs(located.value)) if (roots.exists(input.id)) {
					var allowed = switch located.value {
						case FieldGet(_, owner, _) if (roots.exists(owner.id)): true;
						case FieldSet(owner, field, value) if (roots.exists(owner.id)):
							if (value.id != input.id) true; else {
								var declared = lookupField(owner.type, field);
								declared != null && values.isValue(declared.type);
							}
						case Call(_, name, arguments) if (methodClones.exists(name) && arguments.length > 0 && arguments[0].id == input.id):
							var unique = true;
							for (argument in arguments.slice(1)) if (roots.exists(argument.id) && roots.get(argument.id) == roots.get(input.id)) unique = false;
							unique;
						case MethodCall(_, owner, method, arguments) if (owner.id == input.id):
							var target = resolveMethod(owner.type, method), unique = target != null && methodClones.exists(target);
							for (argument in arguments) if (roots.exists(argument.id) && roots.get(argument.id) == roots.get(input.id)) unique = false;
							unique;
						default: false;
					};
					if (!allowed) valid.set(roots.get(input.id), false);
				}
			}
			if (block.terminator != null) switch block.terminator.value {
				case Throw(value), Rethrow(value), Branch(value, _, _) if (roots.exists(value.id)): valid.set(roots.get(value.id), false);
				default:
			}
		}
		var result:Map<Int, Bool> = [];
		for (id => root in roots) if (valid.get(root) == true) result.set(id, true);
		return result;
	}

	public function rewrite():IrProgram {
		var result = new IrProgram(program.entryPoint);
		result.natives = program.natives; result.cNatives = program.cNatives;
		result.functions = [for (fn in program.functions) rewriteFunction(fn)];
		for (fn in program.functions) {
			var direct = directClones.get(fn.name);
			if (direct != null) result.functions.push(rewriteFunction(new IrFunction(direct, fn.arguments, fn.result, fn.blocks,
				fn.debugBindings, fn.inlineHint)));
			var clone = methodClones.get(fn.name);
			if (clone != null) result.functions.push(rewriteFunction(new IrFunction(clone, fn.arguments, fn.result, fn.blocks,
				fn.debugBindings, fn.inlineHint)));
		}
		result.objects = program.objects; result.interfaces = program.interfaces; result.enums = program.enums;
		result.staticFields = program.staticFields; result.positionalFingerprints = program.positionalFingerprints;
		result.parameterDefaults = program.parameterDefaults; result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		return result;
	}

	/** Keep the source ABI entry alongside a reachable scalar clone for closures and patch publication. */
	public function retainOriginals(reachable:Map<String, Bool>, roots:Array<String>):Bool {
		var added = false;
		var names = [for (original in directClones.keys()) original];
		for (original in methodClones.keys()) if (names.indexOf(original) < 0) names.push(original);
		names.sort(Reflect.compare);
		for (original in names) {
			var clone = directClones.exists(original) ? directClones.get(original) : methodClones.get(original);
			if (clone != null && reachable.exists(clone) && roots.indexOf(original) < 0) {
				roots.push(original); added = true;
			}
		}
		return added;
	}

	public function retainVirtualTargets(lowered:IrProgram, reachable:Map<String, Bool>, roots:Array<String>):Bool {
		var added = false;
		for (fn in lowered.functions) if (reachable.exists(fn.name)) for (block in fn.blocks) for (located in block.instructions)
			switch located.value {
				case MethodCall(_, receiver, method, _):
					var virtual = scalarVirtuals.get(virtualKey(receiver.type, method));
					if (virtual != null) for (target in virtual.targets) if (roots.indexOf(target.clone) < 0) {
						roots.push(target.clone); added = true;
					}
				default:
			}
		return added;
	}

	/** Check the backend-only scalar call and return operations after physical field rewriting. */
	public function validate(lowered:IrProgram):Void {
		var interfaces:Map<String, IrInterface> = [for (entry in lowered.interfaces) entry.name => entry];
		for (fn in lowered.functions) {
			var own = signatures.get(fn.name), handles:Map<Int, Array<IrType>> = [];
			if (own != null) {
				var expected = expandedTypes(own.arguments);
				if (expected.length != fn.arguments.length) throw 'Wrong scalar parameter count in ${fn.name}';
				for (index in 0...expected.length)
					if (!IrVerifier.sameType(expected[index], fn.arguments[index].type)) throw 'Wrong scalar parameter type in ${fn.name}';
			}
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case Call(out, name, arguments) if (name == RETHROW_MARKER):
					if (out.type != Void || arguments.length != 2 || arguments[0].type != Dyn || arguments[1].type != Bool)
						throw 'Invalid scalar rethrow in ${fn.name}';
				case MethodCall(out, receiver, method, arguments) if (scalarVirtuals.exists(virtualKey(receiver.type, method))):
					var virtual = scalarVirtuals.get(virtualKey(receiver.type, method));
					if (virtual == null) throw 'Missing scalar virtual method "$method"';
					var expected = expandedTypes(virtual.signature.arguments);
					if (arguments.length != expected.length) throw 'Wrong scalar virtual arity in ${fn.name}';
					for (index in 0...expected.length)
						if (!IrVerifier.compatibleType(arguments[index].type, expected[index], objects, interfaces))
							throw 'Wrong scalar virtual argument $index in ${fn.name}';
					if (values.isValue(virtual.signature.result)) handles.set(out.id, resultTypes(virtual.signature));
				case CallClosure(out, closure, arguments) if (scalarClosures.exists(Std.string(closure.type))):
					var signature:WasmGcScalarSignature = switch closure.type {
						case Function(args, result): {arguments: args, result: result, mutatesReceiver: false, throwsReceiver: false, receiverId: -1};
						default: throw "Invalid scalar closure type";
					};
					var expected = expandedTypes(signature.arguments);
					if (arguments.length != expected.length) throw 'Wrong scalar closure arity in ${fn.name}';
					for (index in 0...expected.length)
						if (!IrVerifier.compatibleType(arguments[index].type, expected[index], objects, interfaces))
							throw 'Wrong scalar closure argument $index in ${fn.name}';
					if (values.isValue(signature.result)) handles.set(out.id, resultTypes(signature));
				case Call(out, name, arguments) if (signatures.exists(name)):
					var signature = signatures.get(name);
					if (signature == null) throw 'Missing scalar function "$name"';
					var expected = expandedTypes(signature.arguments);
					if (arguments.length != expected.length) throw 'Wrong scalar call arity for "$name"';
					for (index in 0...expected.length)
						if (!IrVerifier.compatibleType(arguments[index].type, expected[index], objects, interfaces))
							throw 'Wrong scalar call argument $index for "$name": got ${arguments[index].type}, expected ${expected[index]}';
					if (signature.mutatesReceiver || values.isValue(signature.result)) handles.set(out.id, resultTypes(signature));
				case Call(out, name, arguments) if (name == RETURN_MARKER):
					if (own == null || out.type != Void) throw 'Unexpected scalar return in ${fn.name}';
					var expected = resultTypes(own);
					if (arguments.length != expected.length) throw 'Wrong scalar result count in ${fn.name}';
					for (index in 0...expected.length)
						if (!IrVerifier.sameType(arguments[index].type, expected[index])) throw 'Wrong scalar result type in ${fn.name}';
				default:
			}
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case FieldGet(out, owner, name) if (StringTools.startsWith(name, RESULT_FIELD_PREFIX)):
					var fields = handles.get(owner.id), index = Std.parseInt(name.substr(RESULT_FIELD_PREFIX.length));
					if (fields == null || index == null || index < 0 || index >= fields.length || !IrVerifier.sameType(out.type, fields[index]))
						throw 'Invalid scalar call result "$name" in ${fn.name}';
				default:
			}
		}
	}

	function expandedTypes(types:Array<IrType>):Array<IrType> {
		var result:Array<IrType> = [];
		for (type in types)
			if (values.isValue(type)) for (slot in values.leaves(type)) result.push(slot.type);
			else result.push(type);
		return result;
	}

	function resultTypes(signature:WasmGcScalarSignature):Array<IrType> {
		var result:Array<IrType> = [];
		if (signature.mutatesReceiver) for (slot in values.leaves(signature.arguments[0])) result.push(slot.type);
		if (signature.result != Void) {
			if (values.isValue(signature.result)) for (slot in values.leaves(signature.result)) result.push(slot.type);
			else result.push(signature.result);
		}
		if (signature.throwsReceiver) { result.push(Dyn); result.push(Bool); }
		return result;
	}

	function rewriteFunction(fn:IrFunction):IrFunction {
		var signature = signatures.get(fn.name), next = nextId(fn), args:Array<IrValue> = [], prefix:Array<Located<IrInstruction>> = [];
		var isolated = isolatedValues(fn);
		var first = fn.blocks[0], end = first.terminator;
		if (end == null) throw 'Missing entry terminator in ${fn.name}';
		var provenance = first.instructions.length == 0 ? end.provenance : first.instructions[0].provenance;
		for (argument in fn.arguments) {
			if (signature == null || !values.isValue(argument.type)) { args.push(argument); continue; }
			var name = objectName(argument.type);
			prefix.push(new Located(NewObject(argument, name), provenance));
			for (slot in values.leaves(argument.type)) {
				var scalar = new IrValue(next++, argument.name + ".$field", slot.type);
				args.push(scalar);
				next = writeLeaf(prefix, argument, slot.path, scalar, provenance, next);
			}
		}
		var blocks:Array<IrBlock> = [];
		for (blockIndex in 0...fn.blocks.length) {
			var block = fn.blocks[blockIndex], replacement = new IrBlock(block.id);
			if (blockIndex == 0) for (instruction in prefix) replacement.instructions.push(instruction);
			for (located in block.instructions) switch located.value {
				case StaticClosure(out, name) if (scalarClosures.exists(Std.string(out.type))):
					replacement.instructions.push(new Located(StaticClosure(out, directClones.get(name)), located.provenance));
				case InstanceClosure(out, name, receiver) if (scalarClosures.exists(Std.string(out.type))):
					replacement.instructions.push(new Located(InstanceClosure(out, directClones.get(name), receiver), located.provenance));
				case CallClosure(out, closure, originalArgs) if (scalarClosures.exists(Std.string(closure.type))):
					next = expandClosureCall(replacement, located, out, closure, originalArgs, next);
				case Call(out, name, originalArgs) if (directClones.exists(name)):
					next = expandCall(replacement, located, out, directClones.get(name), originalArgs, next);
				case Call(out, name, originalArgs) if (methodClones.exists(name)):
					if (receiverSafe.exists(name) || (originalArgs.length > 0 && isolated.exists(originalArgs[0].id)))
						next = expandCall(replacement, located, out, methodClones.get(name), originalArgs, next);
					else replacement.instructions.push(located);
				case Call(out, name, originalArgs) if (signatures.exists(name)):
					next = expandCall(replacement, located, out, name, originalArgs, next);
				case MethodCall(out, receiver, method, originalArgs) if (scalarVirtuals.exists(virtualKey(receiver.type, method))):
					next = expandVirtualCall(replacement, located, out, receiver, method, originalArgs, next);
				case MethodCall(out, receiver, method, originalArgs) if (values.isValue(receiver.type)):
					var original = resolveMethod(receiver.type, method), clone = original == null ? null : methodClones.get(original);
					if (clone == null || (!receiverSafe.exists(original) && !isolated.exists(receiver.id))) replacement.instructions.push(located);
					else next = expandCall(replacement, located, out, clone, [receiver].concat(originalArgs), next);
				default: replacement.instructions.push(located);
			}
			var terminator = block.terminator;
			if (signature != null && (signature.mutatesReceiver || values.isValue(signature.result)) && terminator != null) switch terminator.value {
				case Return(value):
					var parts:Array<IrValue> = [];
					if (signature.mutatesReceiver) for (slot in values.leaves(signature.arguments[0])) {
						var read = readLeaf(replacement.instructions, fn.arguments[0], slot.path, terminator.provenance, next);
						next = read.next; parts.push(read.value);
					}
					if (values.isValue(signature.result)) for (slot in values.leaves(signature.result)) {
						var read = readLeaf(replacement.instructions, value, slot.path, terminator.provenance, next);
						next = read.next; parts.push(read.value);
					} else if (signature.result != Void) parts.push(value);
					if (signature.throwsReceiver) {
						var exception = new IrValue(next++, "$wasm-gc-no-exception", Dyn), thrown = new IrValue(next++, "$wasm-gc-not-thrown", Bool);
						replacement.instructions.push(new Located(ConstNull(exception), terminator.provenance));
						replacement.instructions.push(new Located(ConstBool(thrown, false), terminator.provenance));
						parts.push(exception); parts.push(thrown);
					}
					var marker = new IrValue(next++, "$wasm-gc-return", Void);
					replacement.instructions.push(new Located(Call(marker, RETURN_MARKER, parts), terminator.provenance));
					terminator = new Located(Return(marker), terminator.provenance);
				default:
			}
			replacement.terminator = terminator;
			blocks.push(replacement);
		}
		return new IrFunction(fn.name, args, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention);
	}

	function expandVirtualCall(block:IrBlock, origin:Located<IrInstruction>, out:IrValue, receiver:IrValue, method:String,
			originalArgs:Array<IrValue>, next:Int):Int {
		var virtual = scalarVirtuals.get(virtualKey(receiver.type, method));
		if (virtual == null) throw 'Missing scalar virtual method "$method"';
		var expanded:Array<IrValue> = [];
		for (index in 0...originalArgs.length) {
			var argument = originalArgs[index], declared = virtual.signature.arguments[index];
			if (!values.isValue(declared)) { expanded.push(argument); continue; }
			for (slot in values.leaves(declared)) {
				var read = readLeaf(block.instructions, argument, slot.path, origin.provenance, next);
				next = read.next; expanded.push(read.value);
			}
		}
		if (!values.isValue(virtual.signature.result)) {
			block.instructions.push(new Located(MethodCall(out, receiver, method, expanded), origin.provenance));
			return next;
		}
		var handle = new IrValue(next++, "$wasm-gc-virtual-result", out.type), index = 0;
		block.instructions.push(new Located(MethodCall(handle, receiver, method, expanded), origin.provenance));
		block.instructions.push(new Located(NewObject(out, objectName(out.type)), origin.provenance));
		for (slot in values.leaves(out.type)) {
			var scalar = new IrValue(next++, "$wasm-gc-virtual-result-field", slot.type);
			block.instructions.push(new Located(FieldGet(scalar, handle, RESULT_FIELD_PREFIX + index++), origin.provenance));
			next = writeLeaf(block.instructions, out, slot.path, scalar, origin.provenance, next);
		}
		return next;
	}

	function expandClosureCall(block:IrBlock, origin:Located<IrInstruction>, out:IrValue, closure:IrValue,
			originalArgs:Array<IrValue>, next:Int):Int {
		var signature = switch closure.type {
			case Function(arguments, result): {arguments: arguments, result: result};
			default: throw "Scalar closure has no function type";
		};
		var expanded:Array<IrValue> = [];
		for (index in 0...originalArgs.length) {
			var argument = originalArgs[index], declared = signature.arguments[index];
			if (!values.isValue(declared)) { expanded.push(argument); continue; }
			for (slot in values.leaves(declared)) {
				var read = readLeaf(block.instructions, argument, slot.path, origin.provenance, next);
				next = read.next; expanded.push(read.value);
			}
		}
		if (!values.isValue(signature.result)) {
			block.instructions.push(new Located(CallClosure(out, closure, expanded), origin.provenance));
			return next;
		}
		var handle = new IrValue(next++, "$wasm-gc-closure-result", out.type), index = 0;
		block.instructions.push(new Located(CallClosure(handle, closure, expanded), origin.provenance));
		block.instructions.push(new Located(NewObject(out, objectName(out.type)), origin.provenance));
		for (slot in values.leaves(out.type)) {
			var scalar = new IrValue(next++, "$wasm-gc-closure-result-field", slot.type);
			block.instructions.push(new Located(FieldGet(scalar, handle, RESULT_FIELD_PREFIX + index++), origin.provenance));
			next = writeLeaf(block.instructions, out, slot.path, scalar, origin.provenance, next);
		}
		return next;
	}

	function expandCall(block:IrBlock, origin:Located<IrInstruction>, out:IrValue, name:String, originalArgs:Array<IrValue>, next:Int):Int {
		var callee = signatures.get(name);
		if (callee == null) throw 'Missing scalar Wasm GC signature "$name"';
		var expanded:Array<IrValue> = [];
		for (index in 0...originalArgs.length) {
			var argument = originalArgs[index], declared = callee.arguments[index];
			if (!values.isValue(declared)) { expanded.push(argument); continue; }
			for (slot in values.leaves(declared)) {
				var read = readLeaf(block.instructions, argument, slot.path, origin.provenance, next);
				next = read.next; expanded.push(read.value);
			}
		}
		if (!callee.mutatesReceiver && !values.isValue(callee.result)) {
			block.instructions.push(new Located(Call(out, name, expanded), origin.provenance));
			return next;
		}
		var handleType = callee.mutatesReceiver ? callee.arguments[0] : out.type,
			handle = new IrValue(next++, "$wasm-gc-result", handleType), index = 0;
		block.instructions.push(new Located(Call(handle, name, expanded), origin.provenance));
		if (callee.mutatesReceiver) for (slot in values.leaves(callee.arguments[0])) {
			var scalar = new IrValue(next++, "$wasm-gc-receiver-field", slot.type);
			block.instructions.push(new Located(FieldGet(scalar, handle, RESULT_FIELD_PREFIX + index++), origin.provenance));
			next = writeLeaf(block.instructions, originalArgs[0], slot.path, scalar, origin.provenance, next);
		}
		if (callee.throwsReceiver) {
			var resultCount = callee.result == Void ? 0 : values.isValue(callee.result) ? values.leaves(callee.result).length : 1,
				exception = new IrValue(next++, "$wasm-gc-exception", Dyn), thrown = new IrValue(next++, "$wasm-gc-thrown", Bool),
				check = new IrValue(next++, "$wasm-gc-rethrow", Void);
			block.instructions.push(new Located(FieldGet(exception, handle, RESULT_FIELD_PREFIX + (index + resultCount)), origin.provenance));
			block.instructions.push(new Located(FieldGet(thrown, handle, RESULT_FIELD_PREFIX + (index + resultCount + 1)), origin.provenance));
			block.instructions.push(new Located(Call(check, RETHROW_MARKER, [exception, thrown]), origin.provenance));
		}
		if (values.isValue(callee.result)) {
			block.instructions.push(new Located(NewObject(out, objectName(out.type)), origin.provenance));
			for (slot in values.leaves(out.type)) {
				var scalar = new IrValue(next++, "$wasm-gc-result-field", slot.type);
				block.instructions.push(new Located(FieldGet(scalar, handle, RESULT_FIELD_PREFIX + index++), origin.provenance));
				next = writeLeaf(block.instructions, out, slot.path, scalar, origin.provenance, next);
			}
		} else if (out.type == Void) block.instructions.push(new Located(ConstVoid(out), origin.provenance));
		else block.instructions.push(new Located(FieldGet(out, handle, RESULT_FIELD_PREFIX + index), origin.provenance));
		return next;
	}

	function resolveMethod(type:IrType, name:String):Null<String> {
		var object = objects.get(objectName(type));
		if (object == null) return null;
		for (method in object.methods) if (method.name == name) return method.functionName;
		return null;
	}

	function readLeaf(instructions:Array<Located<IrInstruction>>, root:IrValue, path:Array<String>, provenance:compiler.ir.SourceProvenance,
			next:Int):{value:IrValue, next:Int} {
		var current = root;
		for (field in path) {
			var declared = findField(current.type, field), output = new IrValue(next++, "$wasm-gc-arg-field", declared.type);
			instructions.push(new Located(FieldGet(output, current, field), provenance));
			current = output;
		}
		return {value: current, next: next};
	}

	function writeLeaf(instructions:Array<Located<IrInstruction>>, root:IrValue, path:Array<String>, value:IrValue,
			provenance:compiler.ir.SourceProvenance, next:Int):Int {
		var current = root;
		for (index in 0...path.length) {
			var field = path[index];
			if (index == path.length - 1) instructions.push(new Located(FieldSet(current, field, value), provenance));
			else {
				var declared = findField(current.type, field), child = new IrValue(next++, "$wasm-gc-arg-place", declared.type);
				instructions.push(new Located(FieldGet(child, current, field), provenance));
				current = child;
			}
		}
		return next;
	}

	function findField(type:IrType, name:String):IrObjectField {
		var owner = objectName(type), object = objects.get(owner);
		if (object == null) throw 'Missing Wasm GC value "$owner"';
		for (field in object.fields) if (field.name == name) return field;
		throw 'Missing Wasm GC value field "$owner.$name"';
	}

	static function objectName(type:IrType):String return switch type { case Obj(name): name; default: throw 'Expected a value object, got $type'; };

	static function nextId(fn:IrFunction):Int {
		var next = 0;
		for (argument in fn.arguments) if (argument.id >= next) next = argument.id + 1;
		for (block in fn.blocks) for (located in block.instructions) {
			var output = IrOperands.output(located.value);
			if (output != null && output.id >= next) next = output.id + 1;
		}
		return next;
	}
}

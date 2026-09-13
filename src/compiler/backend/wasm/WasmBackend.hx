package compiler.backend.wasm;

import compiler.backend.Backend;
import compiler.backend.Backend.BackendOptions;
import compiler.backend.Backend.BackendResult;
import compiler.backend.MemoryContract.MemoryContractCodec;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.Ir.IrCNative;
import compiler.ir.Ir.IrTerminator;
import compiler.ir.Ir.IrBlock;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import haxe.io.Bytes as HaxeBytes;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmPatch.WasmPatchArtifact;
import compiler.backend.wasm.WasmStructurer.WasmLoopInfo;
import compiler.backend.wasm.WasmLayout.WasmFieldLayout;
import compiler.backend.wasm.WasmGcRoots.WasmSafepoint;
import compiler.backend.wasm.WasmRepresentation.WasmRepresentationSet;
import compiler.backend.wasm.WasmRepresentation.WasmFunctionRepresentationContext;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringResult;
import compiler.backend.wasm.WasmRepresentation.WasmGcRepresentation;
import compiler.backend.wasm.WasmGcMaps;

typedef WasmClosureTypes = {
	final staticType:Int;
	var instanceType:Null<Int>;
}

/** First self-hosted Wasm backend: scalar lowering with explicit CFG fallback. */
class WasmBackend implements Backend {
	public function new() {}

	public function compile(program:IrProgram, options:BackendOptions):BackendResult {
		return compileInternal(program, options, null);
	}

	/**
	 * Builds a replacement Wasm patch artifact after the semantic ABI planner has
	 * confirmed that table publication is safe. The module remains self-contained
	 * for now so its runtime dependencies are validated by the same encoder as a
	 * full build; the filtered manifest is what the host publishes atomically.
	 */
	public function compilePatch(previous:Null<IrProgram>, program:IrProgram, changed:Array<String>, options:BackendOptions):WasmPatchArtifact {
		var decision = WasmPatch.plan(previous, program);
		switch decision {
			case Patch:
			default:
				throw 'Wasm patch rejected by semantic ABI: ${Std.string(decision)}';
		}
		var result = compileInternal(program, options, changed);
		return {
			bytes: result.bytes,
			manifest: WasmPatch.manifest(program, changed),
			decision: decision,
			changed: changed.copy()
		};
	}

	function compileInternal(program:IrProgram, options:BackendOptions, patchChanged:Null<Array<String>>):BackendResult {
		var target = WasmTarget.forBackend(options.target, options.debugNames);
		if (target.referenceModel == Gc)
			return WasmGcModuleBuilder.compile(program, options, patchChanged);
		if (target.referenceModel == Linear32)
			return WasmLinearModuleBuilder.compile(program, options, patchChanged, target);
		throw "Wasm backend target " + Std.string(options.target) + " is not implemented yet";
	}

	public static function addMemoryStatExport(module:WasmModule, name:String, body:Array<WasmInstruction>):Void {
		var index = module.addFunction(new WasmFunction(name, {parameters: [], results: [I32]}, [], body));
		module.exports.push({name: name, functionIndex: index});
	}

	public static function addCNativeImports(module:WasmModule, functions:Map<String, Int>, program:IrProgram, used:Map<String, Bool>):Void {
		for (native in program.cNatives) {
			if (!used.exists(native.name))
				continue;
			var type:WasmFunctionType = {
				parameters: [for (argument in native.arguments) requireValueType(argument)],
				results: resultTypes(native.result)
			};
			var importModule = native.library == null || native.library == "" ? "env" : native.library,
				importName = native.symbol == null || native.symbol == "" ? native.name : native.symbol;
			functions.set(native.name, module.addImport(importModule, importName, type));
		}
	}

	public static function reachableNatives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case Call(_, name, _):
								result.set(name, true);
							default:
						}
		return result;
	}

	public static function reachableCNatives(program:IrProgram, reachable:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case CNativeCall(_, name, _):
								result.set(name, true);
							default:
						}
		return result;
	}

	public static function memoryPages(bytes:Int):Int
		return Std.int(Math.ceil(bytes / 65536.0));

	public static function resultTypes(type:IrType):Array<WasmValueType>
		return type == Void ? [] : [requireValueType(type)];

	public static function mapNativeParts(name:String):Null<{mapName:String, operation:String}> {
		if (!StringTools.startsWith(name, "__map_"))
			return null;
		var separator = name.lastIndexOf("_");
		if (separator <= 6 || separator == name.length - 1)
			return null;
		return {
			mapName: name.substring(2, separator),
			operation: name.substring(separator + 1, name.length)
		};
	}

	public static function collectClosureTypes(module:WasmModule, program:IrProgram):Map<String, WasmClosureTypes> {
		var result:Map<String, WasmClosureTypes> = [];
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case CallClosure(_, closure, _):
							switch closure.type {
								case Function(arguments, resultType):
									var type:WasmFunctionType = {
										parameters: [for (argument in arguments) requireValueType(argument)],
										results: resultTypes(resultType)
									};
									var key = Std.string(closure.type);
									if (!result.exists(key)) result.set(key, {staticType: module.typeIndex(type), instanceType: null});
								default:
							}
						case InstanceClosure(output, name, _):
							var target:Null<IrFunction> = null;
							for (candidate in program.functions)
								if (candidate.name == name)
									target = candidate;
							if (target == null || target.arguments.length == 0)
								throw 'Wasm instance closure target "$name" has no receiver';
							var closureArguments = switch output.type {
								case Function(arguments, _): arguments;
								default: throw 'Wasm instance closure has an invalid function type';
							};
							var resultType = switch output.type {
								case Function(_, result): result;
								default: Void;
							};
							var staticType = module.typeIndex({
								parameters: [for (argument in closureArguments) requireValueType(argument)],
								results: resultTypes(resultType)
							}), instanceType = module.typeIndex({
								parameters: [requireValueType(target.arguments[0].type)].concat([for (argument in closureArguments) requireValueType(argument)]),
								results: resultTypes(resultType)
							});
							var key = Std.string(output.type),
								existing = result.get(key);
							if (existing == null)
								result.set(key, {staticType: staticType, instanceType: instanceType});
							else
								existing.instanceType = instanceType;
						default:
					}
		return result;
	}

	public static function buildTableSlots(module:WasmModule, functions:Map<String, Int>):Map<String, Int> {
		var names = [for (fn in module.functions) if (functions.exists(fn.name)) fn.name];
		names.sort(Reflect.compare);
		var slots:Map<String, Int> = [];
		for (index in 0...names.length) {
			slots.set(names[index], index);
			module.tableElements.push(requiredFunctionIndex(functions, names[index]));
		}
		module.tableMin = names.length;
		return slots;
	}

	public static function stringBytes(value:String):HaxeBytes {
		var raw = HaxeBytes.ofString(value),
			bytes = HaxeBytes.alloc(WasmLayout.STRING_DATA_OFFSET + raw.length + 1);
		bytes.setInt32(0, typeId(Bytes));
		bytes.setInt32(WasmLayout.STRING_LENGTH_OFFSET, raw.length);
		bytes.setInt32(WasmLayout.ARRAY_CAPACITY_OFFSET, raw.length);
		for (index in 0...raw.length)
			bytes.set(WasmLayout.STRING_DATA_OFFSET + index, raw.get(index));
		return bytes;
	}

	public static function zeroValue(type:IrType):Array<WasmInstruction>
		return switch type {
			case I64: [I64Const(0)];
			case F64: [F64Const(0.0)];
			case Void: [];
			default: [I32Const(0)];
		};

	public static function align(value:Int, boundary:Int):Int
		return (value + boundary - 1) & ~(boundary - 1);

	public static function placeStaticData(program:IrProgram, module:WasmModule, start:Int, reachable:Map<String, Bool>):{addresses:Map<String, Int>, end:Int} {
		var addresses:Map<String, Int> = [], next = start;
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case StaticDataAddress(_, bytes):
								var key = staticDataKey(bytes);
								if (!addresses.exists(key)) {
									var offset = align(next, 8), data = HaxeBytes.alloc(bytes.length);
									for (index in 0...bytes.length)
										data.set(index, bytes[index]);
									module.data.push({offset: offset, bytes: data});
									addresses.set(key, offset);
									next = offset + data.length;
								}
							default:
						}
		return {addresses: addresses, end: align(next, 8)};
	}

	public static function staticDataKey(bytes:Array<Int>):String {
		var digits = "0123456789abcdef", key = new StringBuf();
		for (byte in bytes) {
			key.add(digits.charAt(byte >>> 4));
			key.add(digits.charAt(byte & 15));
		}
		return key.toString();
	}

	public static function isGcNativePointerType(type:IrType):Bool
		return switch type {
			case Abstract("native_pointer"): true;
			case _: false;
		};

	public static function hasFunction(program:IrProgram, name:String):Bool {
		for (fn in program.functions)
			if (fn.name == name)
				return true;
		return false;
	}

	public static function hasExceptions(program:IrProgram):Bool {
		for (fn in program.functions) {
			for (block in fn.blocks) {
				for (located in block.instructions)
					switch located.value {
						case BeginTry(_, _), EndTry(_), Catch(_):
							return true;
						default:
					}
				if (block.terminator != null)
					switch block.terminator.value {
						case Throw(_), Rethrow(_):
							return true;
						default:
					}
			}
		}
		return false;
	}

	public static function reachableFunctions(program:IrProgram, entry:String, ?additionalRoots:Array<String>):Map<String, Bool> {
		var byName:Map<String, IrFunction> = [],
			reachable:Map<String, Bool> = [],
			pending:Array<String> = [entry];
		if (additionalRoots != null)
			for (root in additionalRoots)
				pending.push(root);
		for (fn in program.functions)
			byName.set(fn.name, fn);
		while (pending.length > 0) {
			var name = pending.pop();
			if (reachable.exists(name) || !byName.exists(name))
				continue;
			reachable.set(name, true);
			var fn = byName.get(name);
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, target, _):
							enqueueFunction(target, byName, pending);
						case StaticClosure(_, target), InstanceClosure(_, target, _):
							enqueueFunction(target, byName, pending);
						case MethodCall(_, object, method, _):
							switch object.type {
								case Obj(objectName):
									for (candidate in program.objects)
										if (isObjectSubtype(program, candidate.name, objectName))
											enqueueFunction(findMethod(program, candidate.name, method), byName, pending);
								case Virtual(interfaceName):
									for (candidate in program.objects)
										if (implementsInterface(program, candidate.name, interfaceName))
											enqueueFunction(findMethod(program, candidate.name, method), byName, pending);
								default:
							}
						default:
					}
		}
		return reachable;
	}

	static function enqueueFunction(name:Null<String>, byName:Map<String, IrFunction>, pending:Array<String>):Void
		if (name != null && byName.exists(name))
			pending.push(name);

	static function findMethod(program:IrProgram, objectName:String, methodName:String):Null<String> {
		for (object in program.objects)
			if (object.name == objectName) {
				for (method in object.methods)
					if (method.name == methodName)
						return method.functionName;
				return object.base == null ? null : findMethod(program, object.base, methodName);
			}
		return null;
	}

	static function isObjectSubtype(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (object in program.objects)
			if (object.name == actual)
				return object.base != null && isObjectSubtype(program, object.base, expected);
		return false;
	}

	static function implementsInterface(program:IrProgram, objectName:String, interfaceName:String):Bool {
		for (object in program.objects)
			if (object.name == objectName) {
				for (implemented in object.interfaces)
					if (interfaceExtends(program, implemented, interfaceName))
						return true;
				return object.base != null && implementsInterface(program, object.base, interfaceName);
			}
		return false;
	}

	static function interfaceExtends(program:IrProgram, actual:String, expected:String):Bool {
		if (actual == expected)
			return true;
		for (interfaceDecl in program.interfaces)
			if (interfaceDecl.name == actual)
				for (base in interfaceDecl.bases)
					if (interfaceExtends(program, base, expected))
						return true;
		return false;
	}

	public static function typeId(type:IrType):Int {
		var identity = switch type {
			case Iterator(_): Abstract("realtime_iterator");
			default: type;
		}, text = Std.string(identity), hash:Int = -2128831035;
		for (index in 0...text.length) {
			hash = Std.int(hash ^ text.charCodeAt(index));
			hash = Std.int(hash * 16777619);
		}
		return hash;
	}

	static function programFunction(program:IrProgram, name:String):IrFunction {
		for (fn in program.functions)
			if (fn.name == name)
				return fn;
		throw 'Unknown IR function "$name"';
	}

	public static function requiredGlobal(globals:Map<String, Int>, name:String):Int {
		if (!globals.exists(name))
			throw 'Unknown Wasm global "$name"';
		return globals.get(name);
	}

	public static function requiredFunctionIndex(functions:Map<String, Int>, name:String):Int {
		if (!functions.exists(name))
			throw 'Unknown Wasm function "$name"';
		return functions.get(name);
	}

	public static function requireValueType(type:IrType):WasmValueType
		return switch type {
			case I32, Bool: I32;
			case I64: I64;
			case F64: F64;
			case Bytes, ManagedBytes, Dyn, TypeRef, Array(_), Enum(_), Obj(_), Abstract(_), Virtual(_), Iterator(_), Function(_, _): I32;
			default: throw 'Wasm scalar backend does not yet support IR type ${Std.string(type)}';
		};
}

package compiler.backend.wasm;

import haxe.io.Bytes;
import haxe.io.BytesBuffer;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/**
 * Links a precompiled runtime module into a module being built (docs/WASM_LINEAR_RUNTIME.md).
 *
 * The runtime may import only `env.memory`, which becomes the module's memory, and functions from `haxeon_guest`,
 * which bind to the module's functions of those names. It defines functions only. Its bodies are copied as bytes;
 * `call` targets and block types are renumbered for the module, and nothing else needs to change because the
 * runtime has no globals, table or data of its own.
 */
class WasmRuntimeLinker {
	public static inline final GUEST_MODULE = "haxeon_guest";

	final bytes:Bytes;
	var position = 0;

	function new(bytes:Bytes)
		this.bytes = bytes;

	/**
	 * Appends the runtime's functions to `module`, resolving each `haxeon_guest` import with `guest`, and returns
	 * the module function index of each runtime export. Imports must all be in `module` already: appended
	 * functions take the indices after the last one.
	 */
	public static function link(module:WasmModule, runtime:Bytes, guest:String->Int):Map<String, Int>
		return new WasmRuntimeLinker(runtime).linkInto(module, guest);

	function linkInto(module:WasmModule, guest:String->Int):Map<String, Int> {
		if (bytes.length < 8 || bytes.getInt32(0) != 0x6d736100 || bytes.getInt32(4) != 1)
			throw "The Wasm runtime is not a version 1 WebAssembly module";
		position = 8;
		var types:Array<WasmFunctionType> = [],
			importedFunctions:Array<String> = [],
			functionTypes:Array<Int> = [],
			exports:Array<{name:String, index:Int}> = [],
			bodies:Array<{start:Int, end:Int}> = [];
		while (position < bytes.length) {
			var id = bytes.get(position++), size = u32(), end = position + size;
			switch id {
				case 0:
				case 1:
					for (_ in 0...u32()) {
						if (bytes.get(position++) != 0x60)
							throw "The Wasm runtime declares a non-function type";
						var parameters = [for (_ in 0...u32()) valueType()],
							results = [for (_ in 0...u32()) valueType()];
						types.push({parameters: parameters, results: results});
					}
				case 2:
					for (_ in 0...u32()) {
						var moduleName = name(),
							fieldName = name(),
							kind = bytes.get(position++);
						switch kind {
							case 0 if (moduleName == GUEST_MODULE):
								u32();
								importedFunctions.push(fieldName);
							case 2 if (moduleName == "env" && fieldName == "memory"):
								var flags = u32();
								u32();
								if (flags & 1 != 0) u32();
							default:
								throw 'The Wasm runtime imports $moduleName.$fieldName, which the linker cannot provide';
						}
					}
				case 3:
					for (_ in 0...u32())
						functionTypes.push(u32());
				case 7:
					for (_ in 0...u32()) {
						var exportName = name(), kind = bytes.get(position++), index = u32();
						if (kind != 0)
							throw 'The Wasm runtime exports $exportName, which is not a function';
						exports.push({name: exportName, index: index});
					}
				case 10:
					for (_ in 0...u32()) {
						var bodySize = u32();
						bodies.push({start: position, end: position + bodySize});
						position += bodySize;
					}
				default:
					throw 'The Wasm runtime has section $id; it may define only functions';
			}
			position = end;
		}
		if (bodies.length != functionTypes.length)
			throw "The Wasm runtime's function and code sections disagree";
		var importCount = importedFunctions.length, firstIndex = module.functionCount(), targets = [
			for (index in 0...importCount + bodies.length)
				index < importCount ? guest(importedFunctions[index]) : firstIndex + index - importCount
		];
		for (index in 0...bodies.length) {
			var body = bodies[index], type = types[functionTypes[index]];
			module.addFunction(new WasmFunction('__haxeon_runtime_$index', type, null, null, relocate(body.start, body.end, targets, types, module)));
		}
		return [for (entry in exports) entry.name => targets[entry.index]];
	}

	/** Copies one body, renumbering `call` targets and block types. */
	function relocate(start:Int, end:Int, targets:Array<Int>, types:Array<WasmFunctionType>, module:WasmModule):Bytes {
		var output = new BytesBuffer();
		position = start;
		var groups = u32();
		for (_ in 0...groups) {
			u32();
			valueType();
		}
		var copied = start;
		function flush(upTo:Int):Void {
			output.addBytes(bytes, copied, upTo - copied);
			copied = upTo;
		}
		while (position < end) {
			var opcode = bytes.get(position++);
			switch opcode {
				case 0x02 | 0x03 | 0x04:
					// A block type is empty (0x40), a value type, or a non-negative type index.
					var first = bytes.get(position);
					if (first == 0x40 || (first >= 0x7c && first <= 0x7f))
						position++;
					else {
						var at = position, index = s32();
						flush(at);
						writeU32(output, module.typeIndex(types[index]));
						copied = position;
					}
				case 0x0c | 0x0d | 0x20 | 0x21 | 0x22:
					u32();
				case 0x0e:
					for (_ in 0...u32() + 1)
						u32();
				case 0x10:
					var at = position, callee = u32();
					flush(at);
					writeU32(output, targets[callee]);
					copied = position;
				case 0x1c:
					for (_ in 0...u32())
						valueType();
				case _ if (opcode >= 0x28 && opcode <= 0x3e):
					u32();
					u32();
				case 0x3f | 0x40:
					position++;
				case 0x41:
					s32();
				case 0x42:
					s64();
				case 0x43:
					position += 4;
				case 0x44:
					position += 8;
				case 0xfc:
					switch u32() {
						case sub if (sub <= 7):
						case 10:
							position += 2;
						case 11:
							position += 1;
						case sub:
							throw 'The Wasm runtime uses unsupported instruction 0xfc $sub';
					}
				case _
					if (opcode <= 0x01 || opcode == 0x05 || opcode == 0x0b || opcode == 0x0f || opcode == 0x1a || opcode == 0x1b
						|| (opcode >= 0x45 && opcode <= 0xc4)):
				default:
					throw 'The Wasm runtime uses unsupported instruction 0x${StringTools.hex(opcode, 2)}';
			}
		}
		flush(end);
		return output.getBytes();
	}

	function u32():Int {
		var result = 0, shift = 0, byte;
		do {
			byte = bytes.get(position++);
			result |= (byte & 0x7f) << shift;
			shift += 7;
		} while (byte & 0x80 != 0);
		return result;
	}

	function s32():Int {
		var result = 0, shift = 0, byte;
		do {
			byte = bytes.get(position++);
			result |= (byte & 0x7f) << shift;
			shift += 7;
		} while (byte & 0x80 != 0);
		if (shift < 32 && byte & 0x40 != 0)
			result |= -1 << shift;
		return result;
	}

	function s64():Void {
		while (bytes.get(position++) & 0x80 != 0) {}
	}

	function name():String {
		var length = u32(), text = bytes.getString(position, length);
		position += length;
		return text;
	}

	function valueType():WasmValueType
		return switch bytes.get(position++) {
			case 0x7f: I32;
			case 0x7e: I64;
			case 0x7d: F32;
			case 0x7c: F64;
			case code: throw 'The Wasm runtime uses value type 0x${StringTools.hex(code, 2)}';
		};

	static function writeU32(output:BytesBuffer, value:Int):Void {
		var remaining = value;
		do {
			var byte = remaining & 0x7f;
			remaining >>>= 7;
			output.addByte(remaining != 0 ? byte | 0x80 : byte);
		} while (remaining != 0);
	}
}

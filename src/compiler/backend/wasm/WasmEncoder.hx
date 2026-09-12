package compiler.backend.wasm;

import haxe.io.Bytes;
import haxe.io.BytesOutput;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmModule.WasmGlobal;
import compiler.backend.wasm.WasmModule.WasmExport;
import compiler.backend.wasm.WasmModule.WasmDataSegment;
import compiler.backend.wasm.WasmModule.WasmCustomSection;

/** Encodes the small Wasm module model into standard WebAssembly binary format. */
class WasmEncoder {
	public static function encode(module:WasmModule):Bytes {
		WasmValidator.validate(module);
		for (imported in module.imports)
			module.typeIndex(imported.type);
		for (fn in module.functions)
			module.typeIndex(fn.type);
		var output = new BytesOutput();
		for (byte in [0, 97, 115, 109, 1, 0, 0, 0])
			output.writeByte(byte);
		writeSection(output, 1, encodeTypes(module.types));
		if (module.imports.length > 0 || module.importMemory)
			writeSection(output, 2, encodeImports(module));
		writeSection(output, 3, encodeFunctionTypes(module));
		if (module.tableMin != null)
			writeSection(output, 4, encodeTable(module.tableMin));
		if (module.memoryMin != null && !module.importMemory)
			writeSection(output, 5, encodeMemory(module.memoryMin));
		if (module.exceptionTagType != null)
			writeSection(output, 13, encodeTags(module.exceptionTagType));
		if (module.globals.length > 0)
			writeSection(output, 6, encodeGlobals(module.globals));
		var exports = module.exports.copy();
		if (module.exportMemory)
			exports.push({name: "memory", functionIndex: -1});
		if (module.exportTable)
			exports.push({name: "table", functionIndex: -2});
		if (exports.length > 0)
			writeSection(output, 7, encodeExports(exports, module.exportMemory, module.exportTable));
		if (module.start != null)
			writeSection(output, 8, encodeStart(module.start));
		if (module.tableMin != null && module.tableElements.length > 0)
			writeSection(output, 9, encodeElements(module.tableElements));
		writeSection(output, 10, encodeCode(module));
		if (module.data.length > 0)
			writeSection(output, 11, encodeData(module.data));
		if (module.customName != null)
			writeSection(output, 0, encodeName(module.customName, module));
		for (section in module.customSections)
			writeSection(output, 0, encodeCustom(section));
		return output.getBytes();
	}

	static function encodeCustom(section:WasmCustomSection):Bytes {
		var body = new BytesOutput();
		writeString(body, section.name);
		body.writeBytes(section.bytes, 0, section.bytes.length);
		return body.getBytes();
	}

	static function encodeTypes(types:Array<WasmFunctionType>):Bytes {
		var body = new BytesOutput();
		writeU32(body, types.length);
		for (type in types) {
			body.writeByte(0x60);
			writeTypes(body, type.parameters);
			writeTypes(body, type.results);
		}
		return body.getBytes();
	}

	static function encodeFunctionTypes(module:WasmModule):Bytes {
		var body = new BytesOutput();
		writeU32(body, module.functions.length);
		for (fn in module.functions)
			writeU32(body, module.typeIndex(fn.type));
		return body.getBytes();
	}

	static function encodeImports(module:WasmModule):Bytes {
		var body = new BytesOutput();
		writeU32(body, module.imports.length + (module.importMemory ? 1 : 0));
		for (imported in module.imports) {
			writeString(body, imported.module);
			writeString(body, imported.name);
			body.writeByte(0);
			writeU32(body, module.typeIndex(imported.type));
		}
		if (module.importMemory) {
			writeString(body, "env");
			writeString(body, "memory");
			body.writeByte(2);
			body.writeByte(0);
			writeU32(body, module.memoryMin == null ? 0 : module.memoryMin);
		}
		return body.getBytes();
	}

	static function encodeGlobals(globals:Array<WasmGlobal>):Bytes {
		var body = new BytesOutput();
		writeU32(body, globals.length);
		for (global in globals) {
			body.writeByte(valueType(global.type));
			body.writeByte(global.mutable ? 1 : 0);
			writeInstructions(body, global.init);
			body.writeByte(0x0b);
		}
		return body.getBytes();
	}

	static function encodeMemory(minimum:Int):Bytes {
		var body = new BytesOutput();
		writeU32(body, 1);
		body.writeByte(0);
		writeU32(body, minimum);
		return body.getBytes();
	}

	static function encodeTable(minimum:Int):Bytes {
		var body = new BytesOutput();
		writeU32(body, 1);
		body.writeByte(0x70);
		body.writeByte(0);
		writeU32(body, minimum);
		return body.getBytes();
	}

	static function encodeElements(elements:Array<Int>):Bytes {
		var body = new BytesOutput();
		writeU32(body, 1);
		body.writeByte(0);
		body.writeByte(0x41);
		writeS32(body, 0);
		body.writeByte(0x0b);
		writeU32(body, elements.length);
		for (element in elements)
			writeU32(body, element);
		return body.getBytes();
	}

	static function encodeExports(exports:Array<WasmExport>, exportMemory:Bool, exportTable:Bool):Bytes {
		var body = new BytesOutput();
		writeU32(body, exports.length);
		for (entry in exports) {
			writeString(body, entry.name);
			if (exportMemory && entry.functionIndex == -1) {
				body.writeByte(0x02);
				writeU32(body, 0);
			} else if (exportTable && entry.functionIndex == -2) {
				body.writeByte(0x01);
				writeU32(body, 0);
			} else {
				body.writeByte(0x00);
				writeU32(body, entry.functionIndex);
			}
		}
		return body.getBytes();
	}

	static function encodeStart(functionIndex:Int):Bytes {
		var body = new BytesOutput();
		writeU32(body, functionIndex);
		return body.getBytes();
	}

	static function encodeCode(module:WasmModule):Bytes {
		var body = new BytesOutput();
		writeU32(body, module.functions.length);
		for (fn in module.functions) {
			var functionBody = new BytesOutput();
			writeLocals(functionBody, fn.locals);
			writeInstructions(functionBody, fn.body);
			functionBody.writeByte(0x0b);
			var bytes = functionBody.getBytes();
			writeU32(body, bytes.length);
			body.writeBytes(bytes, 0, bytes.length);
		}
		return body.getBytes();
	}

	static function encodeData(data:Array<WasmDataSegment>):Bytes {
		var body = new BytesOutput();
		writeU32(body, data.length);
		for (segment in data) {
			body.writeByte(0);
			body.writeByte(0x41);
			writeS32(body, segment.offset);
			body.writeByte(0x0b);
			writeU32(body, segment.bytes.length);
			body.writeBytes(segment.bytes, 0, segment.bytes.length);
		}
		return body.getBytes();
	}

	static function encodeTags(typeIndex:Int):Bytes {
		var body = new BytesOutput();
		writeU32(body, 1);
		body.writeByte(0);
		writeU32(body, typeIndex);
		return body.getBytes();
	}

	static function encodeName(name:String, module:WasmModule):Bytes {
		var body = new BytesOutput();
		writeString(body, "name");
		var subsection = new BytesOutput();
		subsection.writeByte(1);
		var names = new BytesOutput();
		writeU32(names, module.functionCount());
		for (index in 0...module.imports.length) {
			writeU32(names, index);
			writeString(names, module.imports[index].name);
		}
		for (index in 0...module.functions.length) {
			writeU32(names, module.imports.length + index);
			writeString(names, module.functions[index].name);
		}
		var nameBytes = names.getBytes();
		writeU32(subsection, nameBytes.length);
		subsection.writeBytes(nameBytes, 0, nameBytes.length);
		var subsectionBytes = subsection.getBytes();
		body.writeBytes(subsectionBytes, 0, subsectionBytes.length);
		return body.getBytes();
	}

	static function writeSection(output:BytesOutput, id:Int, payload:Bytes):Void {
		output.writeByte(id);
		writeU32(output, payload.length);
		output.writeBytes(payload, 0, payload.length);
	}

	static function writeLocals(output:BytesOutput, locals:Array<WasmLocal>):Void {
		var groups:Array<{type:WasmValueType, count:Int}> = [];
		for (local in locals) {
			if (groups.length > 0 && groups[groups.length - 1].type == local.type)
				groups[groups.length - 1].count++;
			else
				groups.push({type: local.type, count: 1});
		}
		writeU32(output, groups.length);
		for (group in groups) {
			writeU32(output, group.count);
			output.writeByte(valueType(group.type));
		}
	}

	static function writeTypes(output:BytesOutput, types:Array<WasmValueType>):Void {
		writeU32(output, types.length);
		for (type in types)
			output.writeByte(valueType(type));
	}

	static function writeInstructions(output:BytesOutput, instructions:Array<WasmInstruction>):Void {
		for (instruction in instructions)
			switch instruction {
				case Unreachable:
					output.writeByte(0x00);
				case Nop:
					output.writeByte(0x01);
				case Block(result):
					output.writeByte(0x02);
					output.writeByte(blockType(result));
				case Loop(result):
					output.writeByte(0x03);
					output.writeByte(blockType(result));
				case Try(result):
					output.writeByte(0x06);
					output.writeByte(blockType(result));
				case If(result):
					output.writeByte(0x04);
					output.writeByte(blockType(result));
				case Else:
					output.writeByte(0x05);
				case Catch(tag):
					output.writeByte(0x07);
					writeU32(output, tag);
				case End:
					output.writeByte(0x0b);
				case Br(depth):
					output.writeByte(0x0c);
					writeU32(output, depth);
				case BrIf(depth):
					output.writeByte(0x0d);
					writeU32(output, depth);
				case BrTable(targets, defaultDepth):
					output.writeByte(0x0e);
					writeU32(output, targets.length);
					for (target in targets)
						writeU32(output, target);
					writeU32(output, defaultDepth);
				case Return:
					output.writeByte(0x0f);
				case Throw(tag):
					output.writeByte(0x08);
					writeU32(output, tag);
				case Call(index):
					output.writeByte(0x10);
					writeU32(output, index);
				case CallIndirect(typeIndex):
					output.writeByte(0x11);
					writeU32(output, typeIndex);
					output.writeByte(0);
				case MemoryCopy:
					output.writeByte(0xfc);
					writeU32(output, 10);
					writeU32(output, 0);
					writeU32(output, 0);
				case MemorySize:
					output.writeByte(0x3f);
					output.writeByte(0);
				case MemoryGrow:
					output.writeByte(0x40);
					output.writeByte(0);
				case Drop:
					output.writeByte(0x1a);
				case LocalGet(index):
					output.writeByte(0x20);
					writeU32(output, index);
				case LocalSet(index):
					output.writeByte(0x21);
					writeU32(output, index);
				case LocalTee(index):
					output.writeByte(0x22);
					writeU32(output, index);
				case GlobalGet(index):
					output.writeByte(0x23);
					writeU32(output, index);
				case GlobalSet(index):
					output.writeByte(0x24);
					writeU32(output, index);
				case I32Load(offset):
					output.writeByte(0x28);
					writeU32(output, 2);
					writeU32(output, offset);
				case I32Load8S(offset):
					output.writeByte(0x2c);
					writeU32(output, 0);
					writeU32(output, offset);
				case I32Load8U(offset):
					output.writeByte(0x2d);
					writeU32(output, 0);
					writeU32(output, offset);
				case I32Load16S(offset):
					output.writeByte(0x2e);
					writeU32(output, 1);
					writeU32(output, offset);
				case I32Load16U(offset):
					output.writeByte(0x2f);
					writeU32(output, 1);
					writeU32(output, offset);
				case I32Store(offset):
					output.writeByte(0x36);
					writeU32(output, 2);
					writeU32(output, offset);
				case I32Store8(offset):
					output.writeByte(0x3a);
					writeU32(output, 0);
					writeU32(output, offset);
				case I32Store16(offset):
					output.writeByte(0x3b);
					writeU32(output, 1);
					writeU32(output, offset);
				case I64Load(offset):
					output.writeByte(0x29);
					writeU32(output, 3);
					writeU32(output, offset);
				case I64Store(offset):
					output.writeByte(0x37);
					writeU32(output, 3);
					writeU32(output, offset);
				case F32Load(offset):
					output.writeByte(0x2a);
					writeU32(output, 2);
					writeU32(output, offset);
				case F32Store(offset):
					output.writeByte(0x38);
					writeU32(output, 2);
					writeU32(output, offset);
				case F64Load(offset):
					output.writeByte(0x2b);
					writeU32(output, 3);
					writeU32(output, offset);
				case F64Store(offset):
					output.writeByte(0x39);
					writeU32(output, 3);
					writeU32(output, offset);
				case I32Const(value):
					output.writeByte(0x41);
					writeS32(output, value);
				case I64Const(value):
					output.writeByte(0x42);
					writeS64(output, value);
				case F64Const(value):
					output.writeByte(0x44);
					writeF64(output, value);
				case I32Add:
					output.writeByte(0x6a);
				case I32Sub:
					output.writeByte(0x6b);
				case I32Mul:
					output.writeByte(0x6c);
				case I32DivS:
					output.writeByte(0x6d);
				case I32RemS:
					output.writeByte(0x6f);
				case I32And:
					output.writeByte(0x71);
				case I32Xor:
					output.writeByte(0x73);
				case I32Or:
					output.writeByte(0x72);
				case I32Shl:
					output.writeByte(0x74);
				case I32ShrS:
					output.writeByte(0x75);
				case I32ShrU:
					output.writeByte(0x76);
				case I32Eqz:
					output.writeByte(0x45);
				case I32Eq:
					output.writeByte(0x46);
				case I32LtS:
					output.writeByte(0x48);
				case I32LeS:
					output.writeByte(0x4c);
				case I64Add:
					output.writeByte(0x7c);
				case I64Sub:
					output.writeByte(0x7d);
				case I64Mul:
					output.writeByte(0x7e);
				case I64DivS:
					output.writeByte(0x7f);
				case I64RemS:
					output.writeByte(0x81);
				case I64And:
					output.writeByte(0x83);
				case I64Xor:
					output.writeByte(0x85);
				case I64Or:
					output.writeByte(0x84);
				case I64Shl:
					output.writeByte(0x86);
				case I64ShrS:
					output.writeByte(0x87);
				case I64ShrU:
					output.writeByte(0x88);
				case I64Eqz:
					output.writeByte(0x50);
				case I64Eq:
					output.writeByte(0x51);
				case I64LtS:
					output.writeByte(0x53);
				case I64LeS:
					output.writeByte(0x57);
				case F64Add:
					output.writeByte(0xa0);
				case F64Sub:
					output.writeByte(0xa1);
				case F64Mul:
					output.writeByte(0xa2);
				case F64Div:
					output.writeByte(0xa3);
				case F64Eq:
					output.writeByte(0x61);
				case F64Lt:
					output.writeByte(0x63);
				case F64Le:
					output.writeByte(0x65);
				case F64ConvertI32S:
					output.writeByte(0xb7);
				case F64ConvertI64S:
					output.writeByte(0xb9);
				case I64ExtendI32S:
					output.writeByte(0xac);
				case F64PromoteF32:
					output.writeByte(0xbb);
				case F32DemoteF64:
					output.writeByte(0xb6);
				case I32WrapI64:
					output.writeByte(0xa7);
				case I32TruncF64S:
					output.writeByte(0xaa);
			}
	}

	static function valueType(type:WasmValueType):Int
		return switch type {
			case I32: 0x7f;
			case I64: 0x7e;
			case F32: 0x7d;
			case F64: 0x7c;
		};

	static function blockType(type:Null<WasmValueType>):Int
		return type == null ? 0x40 : valueType(type);

	static function writeString(output:BytesOutput, value:String):Void {
		var bytes = Bytes.ofString(value);
		writeU32(output, bytes.length);
		output.writeBytes(bytes, 0, bytes.length);
	}

	static function writeU32(output:BytesOutput, value:Int):Void {
		var current = value;
		do {
			var byte = current & 0x7f;
			current = current >>> 7;
			if (current != 0)
				byte |= 0x80;
			output.writeByte(byte);
		} while (current != 0);
	}

	static function writeS32(output:BytesOutput, value:Int):Void {
		var current = value, more = true;
		while (more) {
			var byte = current & 0x7f;
			current = current >> 7;
			var sign = (byte & 0x40) != 0;
			more = !((current == 0 && !sign) || (current == -1 && sign));
			if (more)
				byte |= 0x80;
			output.writeByte(byte);
		}
	}

	static function writeS64(output:BytesOutput, value:Int):Void
		writeS32(output, value);

	static function writeF64(output:BytesOutput, value:Float):Void {
		var bytes = Bytes.alloc(8);
		bytes.setDouble(0, value);
		output.writeBytes(bytes, 0, 8);
	}
}

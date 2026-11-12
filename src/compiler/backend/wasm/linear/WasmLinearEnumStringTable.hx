package compiler.backend.wasm.linear;

import compiler.backend.wasm.EnumStringDescriptors;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.ir.Ir.IrType;

private typedef LinearEnumStringCase = {final name:Int; final descriptor:Int; final offsets:Array<Int>;}
private typedef LinearEnumStringGroup = {final type:Int; final cases:Array<LinearEnumStringCase>;}

/** Encode shared enum string descriptors in linear memory. */
class WasmLinearEnumStringTable {
	public static function place(module:WasmModule, model:EnumStringDescriptors, layout:WasmLayout, strings:Map<String, Int>, start:Int):{
		address:Int,
		count:Int,
		end:Int
	} {
		var groups:Array<LinearEnumStringGroup> = [];
		for (group in model.groups) {
			var cases:Array<LinearEnumStringCase> = [];
			for (index in 0...group.cases.length) {
				var item = group.cases[index], offsets:Array<Int> = [];
				for (field in 0...item.parameters.length)
					offsets.push(layout.enumField(group.name, index, field).offset);
				cases.push({name: requiredString(strings, item.name), descriptor: item.descriptor, offsets: offsets});
			}
			groups.push({type: module.runtimeTypeId(Enum(group.name)), cases: cases});
		}
		if (groups.length == 0)
			return {address: 0, count: 0, end: start};
		var address = (start + 3) & ~3,
			size = groups.length * 12,
			seen:Map<String, Bool> = [];
		for (group in groups) {
			size += group.cases.length * 8;
			for (item in group.cases)
				if (item.descriptor >= 0) {
					var key = physicalKey(item.descriptor, item.offsets);
					if (seen.exists(key))
						continue;
					seen.set(key, true);
					size += 4;
					for (field in model.descriptors[item.descriptor])
						size += 12 + (EnumStringDescriptors.code(field.kind) == EnumStringDescriptors.TAG ? 4 + field.tagNames.length * 4 : 0);
				}
		}
		var bytes = haxe.io.Bytes.alloc(size),
			cursor = groups.length * 12,
			encoded:Map<String, Int> = [];
		for (i in 0...groups.length) {
			var group = groups[i], at = i * 12;
			bytes.setInt32(at, group.type);
			bytes.setInt32(at + 4, group.cases.length);
			bytes.setInt32(at + 8, address + cursor);
			var casesStart = cursor;
			cursor += group.cases.length * 8;
			for (index in 0...group.cases.length) {
				var item = group.cases[index], itemAt = casesStart + index * 8;
				bytes.setInt32(itemAt, item.name);
				if (item.descriptor < 0)
					continue;
				var key = physicalKey(item.descriptor, item.offsets),
					existing = encoded.get(key);
				if (existing != null) {
					bytes.setInt32(itemAt + 4, existing);
					continue;
				}
				encoded.set(key, address + cursor);
				bytes.setInt32(itemAt + 4, address + cursor);
				var fields = model.descriptors[item.descriptor];
				bytes.setInt32(cursor, fields.length);
				cursor += 4;
				var fieldStart = cursor;
				cursor += fields.length * 12;
				for (field in 0...fields.length) {
					var entry = fields[field],
						pos = fieldStart + field * 12,
						kind = EnumStringDescriptors.code(entry.kind);
					bytes.setInt32(pos, item.offsets[field]);
					bytes.setInt32(pos + 4, kind);
					if (kind == EnumStringDescriptors.TAG) {
						bytes.setInt32(pos + 8, address + cursor);
						bytes.setInt32(cursor, entry.tagNames.length);
						cursor += 4;
						for (name in entry.tagNames) {
							bytes.setInt32(cursor, requiredString(strings, name));
							cursor += 4;
						}
					}
				}
			}
		}
		module.data.push({offset: address, bytes: bytes, censusCategory: "enum string descriptors"});
		return {address: address, count: groups.length, end: address + size};
	}

	/** Equal logical shapes can share an encoding only when their linear offsets also match. */
	static function physicalKey(descriptor:Int, offsets:Array<Int>):String
		return descriptor + ":" + offsets.join(",");

	static function requiredString(strings:Map<String, Int>, name:String):Int {
		var result = strings.get(name);
		if (result == null)
			throw 'Missing enum string "$name"';
		return result;
	}
}

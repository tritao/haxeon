package compiler.backend.wasm.linear;

import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;

private typedef EnumStringField = {final offset:Int; final kind:Int; final tags:Array<Int>;}

/** Static descriptors for the shared linear-memory enum formatter. */
class WasmLinearEnumStringTable {
	public static inline final REFERENCE = 0;
	public static inline final INTEGER = 1;
	public static inline final BOOLEAN = 2;
	public static inline final INTEGER64 = 3;
	public static inline final FLOAT = 4;
	public static inline final TAG = 5;

	/** Type rows point to constructor name and field-table records. */
	public static function place(module:WasmModule, program:IrProgram, layout:WasmLayout, strings:Map<String, Int>, selected:Map<String, Bool>,
			declarations:Array<IrEnum>, start:Int):{
		address:Int,
		count:Int,
		end:Int
	} {
		var groups:Array<{type:Int, cases:Array<{name:Int, fields:Array<EnumStringField>}>}> = [];
		for (decl in program.enums)
			if (selected.exists(decl.name)) {
				var cases = [];
				for (index in 0...decl.cases.length) {
					var constructor = decl.cases[index], fields = [];
					for (field in 0...constructor.params.length) {
						var entry = layout.enumField(decl.name, index, field),
							tags:Array<Int> = [];
						var kind = switch entry.type {
							case I32: INTEGER;
							case Bool: BOOLEAN;
							case I64: INTEGER64;
							case F32 | F64: FLOAT;
							case EnumTag(name):
								var tagged = Lambda.find(declarations, value -> value.name == name);
								if (tagged == null)
									throw 'Missing enum declaration "$name"';
								for (item in tagged.cases)
									tags.push(requiredString(strings, item.name));
								TAG;
							default: REFERENCE;
						};
						fields.push({offset: entry.offset, kind: kind, tags: tags});
					}
					cases.push({name: requiredString(strings, constructor.params.length == 0 ? constructor.name : constructor.name + "("), fields: fields});
				}
				groups.push({type: module.runtimeTypeId(Enum(decl.name)), cases: cases});
			}
		if (groups.length == 0)
			return {address: 0, count: 0, end: start};
		var address = (start + 3) & ~3, size = groups.length * 12;
		var seen:Map<String, Bool> = [];
		for (group in groups) {
			size += group.cases.length * 8;
			for (row in group.cases)
				if (row.fields.length > 0) {
					var key = fieldKey(row.fields);
					if (seen.exists(key))
						continue;
					seen.set(key, true);
					size += 4;
					for (field in row.fields)
						size += 12 + (field.kind == TAG ? 4 + field.tags.length * 4 : 0);
				}
		}
		var bytes = haxe.io.Bytes.alloc(size),
			cursor = groups.length * 12,
			descriptors:Map<String, Int> = [];
		for (i in 0...groups.length) {
			var group = groups[i], at = i * 12;
			bytes.setInt32(at, group.type);
			bytes.setInt32(at + 4, group.cases.length);
			bytes.setInt32(at + 8, address + cursor);
			var casesStart = cursor;
			cursor += group.cases.length * 8;
			for (caseIndex in 0...group.cases.length) {
				var row = group.cases[caseIndex],
					rowAt = casesStart + caseIndex * 8;
				bytes.setInt32(rowAt, row.name);
				if (row.fields.length == 0)
					continue;
				var key = fieldKey(row.fields),
					existing = descriptors.get(key);
				if (existing != null) {
					bytes.setInt32(rowAt + 4, existing);
					continue;
				}
				descriptors.set(key, address + cursor);
				bytes.setInt32(rowAt + 4, address + cursor);
				bytes.setInt32(cursor, row.fields.length);
				cursor += 4;
				var fieldStart = cursor;
				cursor += row.fields.length * 12;
				for (j in 0...row.fields.length) {
					var field = row.fields[j], pos = fieldStart + j * 12;
					bytes.setInt32(pos, field.offset);
					bytes.setInt32(pos + 4, field.kind);
					if (field.kind == TAG) {
						bytes.setInt32(pos + 8, address + cursor);
						bytes.setInt32(cursor, field.tags.length);
						cursor += 4;
						for (name in field.tags) {
							bytes.setInt32(cursor, name);
							cursor += 4;
						}
					}
				}
			}
		}

		module.data.push({offset: address, bytes: bytes, censusCategory: "enum string descriptors"});
		return {address: address, count: groups.length, end: address + size};
	}

	/** Descriptors with the same offsets, kinds and tag-name pointers can share one table. */
	static function fieldKey(fields:Array<EnumStringField>):String {
		var parts:Array<String> = [];
		for (field in fields)
			parts.push(field.offset + ":" + field.kind + ":" + field.tags.join(","));
		return parts.join(";");
	}

	static function requiredString(strings:Map<String, Int>, name:String):Int {
		var result = strings.get(name);
		if (result == null)
			throw 'Missing enum string "$name"';
		return result;
	}
}

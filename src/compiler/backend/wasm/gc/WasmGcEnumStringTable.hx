package compiler.backend.wasm.gc;

import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;

/** Passive data for the shared GC enum formatter; offsets in metadata are i32-array indices. */
class WasmGcEnumStringTable {
	public static inline final REFERENCE = 0;
	public static inline final INTEGER = 1;
	public static inline final BOOLEAN = 2;
	public static inline final INTEGER64 = 3;
	public static inline final FLOAT = 4;
	public static inline final TAG = 5;
	public static inline final RAW_POINTER = 6;
	public static inline final TYPE_REFERENCE = 7;
	public static inline final NATIVE_CALLBACK = 8;

	public final bytes:haxe.io.Bytes;
	public final words:Int;
	public final names:Int;

	/** Use packed 16-bit metadata when all offsets and slots fit; larger modules use 32-bit words. */
	public final narrow:Bool;

	public function new(program:IrProgram, selected:Map<String, Bool>, declarations:Array<IrEnum>, accessors:Map<String, Array<Int>>,
			matchers:Map<String, Int>) {
		var data:Array<Int> = [0, 0, 0, 0],
			nameBytes:Array<haxe.io.Bytes> = [],
			nameIds:Map<String, Int> = [];
		function nameId(value:String):Int {
			var existing = nameIds.get(value);
			if (existing != null)
				return existing;
			var result = nameBytes.length;
			nameBytes.push(haxe.io.Bytes.ofString(value));
			nameIds.set(value, result);
			return result;
		}
		var groups:Array<IrEnum> = [for (entry in program.enums) if (selected.exists(entry.name)) entry];
		var descriptors:Map<String, Int> = [];
		data[0] = groups.length;
		data[1] = data.length;
		for (_ in groups) {
			data.push(0);
			data.push(0);
			data.push(0);
		}
		for (index in 0...groups.length) {
			var group = groups[index], groupAt = 4 + index * 3;
			var matcher = matchers.get(group.name);
			if (matcher == null)
				throw 'Missing enum string matcher for ${group.name}';
			data[groupAt] = matcher;
			data[groupAt + 1] = group.cases.length;
			data[groupAt + 2] = data.length;
			var casesAt = data.length;
			for (_ in group.cases) {
				data.push(0);
				data.push(0);
				data.push(0);
			}
			for (caseIndex in 0...group.cases.length) {
				var item = group.cases[caseIndex],
					itemAt = casesAt + caseIndex * 3;
				data[itemAt] = nameId(item.params.length == 0 ? item.name : item.name + "(");
				if (item.params.length == 0)
					continue;
				var groupAccessors = accessors.get(group.name);
				if (groupAccessors == null || groupAccessors[caseIndex] < 0)
					throw 'Missing enum string accessor for ${group.name} case $caseIndex';
				data[itemAt + 2] = groupAccessors[caseIndex];
				var key = fieldKey(item.params),
					existing = descriptors.get(key);
				if (existing != null) {
					data[itemAt + 1] = existing;
					continue;
				}
				descriptors.set(key, data.length);
				data[itemAt + 1] = data.length;
				data.push(item.params.length);
				var fieldsAt = data.length;
				for (_ in item.params) {
					data.push(0);
					data.push(0);
					data.push(0);
				}
				for (field in 0...item.params.length) {
					var at = fieldsAt + field * 3;
					data[at] = switch item.params[field] {
						case I32: INTEGER;
						case Bool: BOOLEAN;
						case I64: INTEGER64;
						case F32 | F64: FLOAT;
						case RawPtr: RAW_POINTER;
						case TypeRef: TYPE_REFERENCE;
						case Abstract("native_callback"): NATIVE_CALLBACK;
						case EnumTag(name):
							var tagged = Lambda.find(declarations, entry -> entry.name == name);
							if (tagged == null)
								throw 'Missing enum declaration "$name"';
							data[at + 1] = tagged.cases.length;
							data[at + 2] = data.length;
							for (tag in tagged.cases)
								data.push(nameId(tag.name));
							TAG;
						default: REFERENCE;
					};
				}
			}
		}
		names = nameBytes.length;
		data[2] = names;
		data[3] = data.length;
		for (_ in nameBytes) {
			data.push(0);
			data.push(0);
		}
		words = data.length;
		var nameSize = 0;
		for (name in nameBytes)
			nameSize += name.length;
		var fits = words * 2 + nameSize <= 65535;
		for (value in data)
			if (value < 0 || value > 65535)
				fits = false;
		narrow = fits;
		var width = narrow ? 2 : 4, cursor = words * width;
		bytes = haxe.io.Bytes.alloc(cursor + nameSize);
		for (index in 0...nameBytes.length) {
			var name = nameBytes[index], at = data[3] + index * 2;
			data[at] = cursor;
			data[at + 1] = name.length;
			bytes.blit(cursor, name, 0, name.length);
			cursor += name.length;
		}
		for (index in 0...data.length) {
			if (narrow) {
				bytes.set(index * 2, data[index] & 255);
				bytes.set(index * 2 + 1, data[index] >>> 8);
			} else
				bytes.setInt32(index * 4, data[index]);
		}
	}

	/** Deduplicate equal kind sequences; enum tags retain their distinct name tables. */
	static function fieldKey(fields:Array<IrType>):String {
		var parts:Array<String> = [];
		for (field in fields)
			parts.push(switch field {
				case I32: "i";
				case Bool: "b";
				case I64: "l";
				case F32 | F64: "f";
				case RawPtr: "p";
				case TypeRef: "t";
				case Abstract("native_callback"): "c";
				case EnumTag(name): "e" + name.length + ":" + name;
				default: "r";
			});
		return parts.join(";");
	}
}

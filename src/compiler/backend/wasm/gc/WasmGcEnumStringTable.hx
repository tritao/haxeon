package compiler.backend.wasm.gc;

import compiler.backend.wasm.EnumStringDescriptors;

/** Passive data for the shared GC enum formatter; offsets in metadata are array indices. */
class WasmGcEnumStringTable {
	public final bytes:haxe.io.Bytes;
	public final words:Int;
	public final names:Int;

	/** Use packed 16-bit metadata when all offsets and slots fit; larger modules use 32-bit words. */
	public final narrow:Bool;

	public function new(model:EnumStringDescriptors, accessors:Map<String, Array<Int>>, matchers:Map<String, Int>) {
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
		var groups = model.groups;
		var descriptors:Map<Int, Int> = [];
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
				data[itemAt] = nameId(item.name);
				if (item.descriptor < 0)
					continue;
				var groupAccessors = accessors.get(group.name);
				if (groupAccessors == null || groupAccessors[caseIndex] < 0)
					throw 'Missing enum string accessor for ${group.name} case $caseIndex';
				data[itemAt + 2] = groupAccessors[caseIndex];
				var existing = descriptors.get(item.descriptor);
				if (existing != null) {
					data[itemAt + 1] = existing;
					continue;
				}
				descriptors.set(item.descriptor, data.length);
				data[itemAt + 1] = data.length;
				var fields = model.descriptors[item.descriptor];
				data.push(fields.length);
				var fieldsAt = data.length;
				for (_ in fields) {
					data.push(0);
					data.push(0);
					data.push(0);
				}
				for (field in 0...fields.length) {
					var at = fieldsAt + field * 3, entry = fields[field];
					data[at] = EnumStringDescriptors.code(entry.kind);
					if (data[at] == EnumStringDescriptors.TAG) {
						data[at + 1] = entry.tagNames.length;
						data[at + 2] = data.length;
						for (name in entry.tagNames)
							data.push(nameId(name));
					}
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
}

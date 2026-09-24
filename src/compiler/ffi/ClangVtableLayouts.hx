package compiler.ffi;

typedef VtableEntry = {
	final owner:String;
	final method:String;
	final index:Int;
	final thisAdjustment:Int;
}

typedef VtableLayout = {
	final owner:String;
	final entries:Array<VtableEntry>;
}

/** Parses Clang's Itanium/MSVC-independent vtable-index dump. */
class ClangVtableLayouts {
	public static function parse(text:String):Map<String, VtableLayout> {
		var result:Map<String, VtableLayout> = [],
			current:Null<String> = null,
			entries:Array<VtableEntry> = [],
			pendingAdjustment = 0;
		for (rawLine in text.split("\n")) {
			var line = StringTools.endsWith(rawLine, "\r") ? rawLine.substring(0, rawLine.length - 1) : rawLine,
				vtable = ~/^VTable indices for '([^']+)' \([0-9]+ entries\)\./;
			if (vtable.match(line)) {
				if (current != null)
					result.set(current, {owner: current, entries: entries});
				current = vtable.matched(1);
				entries = [];
				pendingAdjustment = 0;
				continue;
			}
			if (current == null)
				continue;
			var adjustment = ~/this adjustment:\s*(-?[0-9]+)/;
			if (adjustment.match(line)) {
				pendingAdjustment = Std.parseInt(adjustment.matched(1));
				continue;
			}
			var entry = ~/^\s*([0-9]+) \|\s+.*\s+([A-Za-z_][A-Za-z0-9_:~]*)\([^)]*\)/;
			if (entry.match(line)) {
				var method = entry.matched(2),
					separator = method.lastIndexOf("::"),
					owner = separator < 0 ? current : method.substring(0, separator),
					name = separator < 0 ? method : method.substring(separator + 2);
				entries.push({
					owner: owner,
					method: name,
					index: Std.parseInt(entry.matched(1)),
					thisAdjustment: pendingAdjustment
				});
				pendingAdjustment = 0;
			}
		}
		if (current != null)
			result.set(current, {owner: current, entries: entries});
		return result;
	}
}

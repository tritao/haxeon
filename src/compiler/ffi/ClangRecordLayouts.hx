package compiler.ffi;

/** One record layout reported by Clang, in bytes. */
typedef RecordLayout = {
	final size:Int;
	final align:Int;
	final offsets:Map<String, Int>;
}

/** Parser for Clang's human-readable record-layout dump. */
class ClangRecordLayouts {
	public static function parse(text:String):Map<String, RecordLayout> {
		var result:Map<String, RecordLayout> = [],
			current:Null<String> = null,
			offsets:Map<String, Int> = [],
			size:Null<Int> = null,
			align:Null<Int> = null;
		for (rawLine in text.split("\n")) {
			// Clang emits CRLF on Windows. Keep the grammar host-independent.
			var line = StringTools.endsWith(rawLine, "\r") ? rawLine.substring(0, rawLine.length - 1) : rawLine;
			// A top-level marker has one space after the separator. More deeply
			// indented markers describe nested records and are fields of the
			// current record, not a new layout.
			var record = ~/^\s*[0-9]+\s*\|\s(?:struct|class|union)\s+([A-Za-z_][A-Za-z0-9_:]*)/;
			if (record.match(line)) {
				current = record.matched(1);
				offsets = [];
				size = null;
				align = null;
				continue;
			}
			if (current == null)
				continue;
			var fieldLine = ~/^\s*([0-9]+) \|\s+.+ ([A-Za-z_][A-Za-z0-9_]*)$/;
			if (fieldLine.match(line))
				offsets.set(fieldLine.matched(2), Std.parseInt(fieldLine.matched(1)));
			var sizeValue = ~/sizeof=([0-9]+)/;
			if (sizeValue.match(line))
				size = Std.parseInt(sizeValue.matched(1));
			var alignValue = ~/align=([0-9]+)/;
			if (alignValue.match(line))
				align = Std.parseInt(alignValue.matched(1));
			var plainSizeLabel = ~/\bSize:\s*([0-9]+)/;
			if (plainSizeLabel.match(line))
				size = Std.parseInt(plainSizeLabel.matched(1));
			var plainAlignLabel = ~/\bAlignment:\s*([0-9]+)/;
			if (plainAlignLabel.match(line))
				align = Std.parseInt(plainAlignLabel.matched(1));
			if (size != null && align != null) {
				result.set(current, {size: size, align: align, offsets: offsets});
				current = null;
			}
		}
		return result;
	}
}

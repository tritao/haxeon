package inventory;

using StringTools;

/** Reads `name,category,count,price` lines; blank lines and `#` comments are skipped. */
class Parser {
	public static function parse(text:String):Array<Item> {
		var items = [];
		var separator = ~/\s*,\s*/g;
		for (line in text.split("\n")) {
			line = line.trim();
			if (line.length == 0 || line.startsWith("#"))
				continue;
			var fields = separator.split(line);
			if (fields.length != 4)
				throw new ParseError('expected 4 fields: $line');
			var count = Std.parseInt(fields[2]), price = Std.parseFloat(fields[3]);
			if (count == null || Math.isNaN(price))
				throw new ParseError('bad number: $line');
			items.push(new Item(fields[0], Category.parse(fields[1]), count, price));
		}
		return items;
	}
}

class ParseError extends haxe.Exception {}

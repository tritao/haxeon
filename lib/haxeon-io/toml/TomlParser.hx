package toml;

import haxe.io.Bytes;
import toml.TomlDateTime.TomlDateTimeKind;

/**
 * Reads a TOML 1.0 document into the values `haxe.Json.parse` gives for JSON, so code that reads either format reads one shape: a
 * table is an anonymous object, an array an `Array<Dynamic>`, a string a `String`, a boolean a `Bool` and a float a `Float`. An
 * integer is an `Int`, or a `Float` when it does not fit in 32 bits (exact up to 2^53). A date or time is a `TomlDateTime`.
 *
 * An invalid document throws a `TomlError` with the line and column. The parser scans the UTF-8 bytes of the text, so it costs the
 * same on every target.
 */
class TomlParser {
	public static function parse(text:String):Dynamic
		return new TomlParser(text).document();

	final bytes:Bytes;
	final length:Int;
	var position = 0;

	function new(text:String) {
		bytes = Bytes.ofString(text);
		length = bytes.length;
	}

	function document():Dynamic {
		var root = new Table(Defined), current = root;
		while (true) {
			skipSpace();
			if (position >= length)
				break;
			var code = at(position);
			if (code == "[".code) {
				current = header(root);
			} else if (code != "#".code && code != "\n".code && code != "\r".code) {
				keyValue(current);
			}
			endLine();
		}
		return root.toDynamic();
	}

	/** `[a.b]` or `[[a.b]]`: the table the following keys go in. */
	function header(root:Table):Table {
		position++;
		var array = at(position) == "[".code;
		if (array)
			position++;
		skipSpace();
		var start = position, keys = key();
		skipSpace();
		expect("]".code, array ? "expected ]] after the table name" : "expected ] after the table name");
		if (array)
			expect("]".code, "expected ]] after the table name");
		var table = root;
		for (index in 0...keys.length - 1)
			table = descend(table, keys[index], start, false);
		var name = keys[keys.length - 1], entry = table.entries.get(name);
		if (array) {
			var element = new Table(Defined);
			switch entry {
				case null:
					table.add(name, Tables([element]));
				case Tables(list):
					list.push(element);
				case _:
					throw error('"${keys.join(".")}" is already defined, not as an array of tables', start);
			}
			return element;
		}
		switch entry {
			case null:
				var defined = new Table(Defined);
				table.add(name, Child(defined));
				return defined;
			case Child(existing) if (existing.origin == Implicit):
				existing.origin = Defined;
				return existing;
			case _:
				throw error('"${keys.join(".")}" is already defined', start);
		}
	}

	/** The table `name` in `table` that a header's or a dotted key's path goes through, made when it is missing. */
	function descend(table:Table, name:String, start:Int, dotted:Bool):Table {
		switch table.entries.get(name) {
			case null:
				var child = new Table(dotted ? Dotted : Implicit);
				table.add(name, Child(child));
				return child;
			case Child(child):
				if (child.origin == Frozen || dotted && child.origin == Defined)
					throw error('table "$name" cannot be extended here', start);
				if (dotted)
					child.origin = Dotted;
				return child;
			case Tables(list) if (!dotted):
				return list[list.length - 1];
			case _:
				throw error('"$name" is already defined as a value', start);
		}
	}

	/** `a.b = value` in `table`. */
	function keyValue(table:Table):Void {
		var start = position, keys = key();
		skipSpace();
		expect("=".code, "expected = after a key");
		skipSpace();
		var value = value();
		for (index in 0...keys.length - 1)
			table = descend(table, keys[index], start, true);
		var name = keys[keys.length - 1];
		if (table.entries.exists(name))
			throw error('key "${keys.join(".")}" is defined twice', start);
		table.add(name, value);
	}

	function key():Array<String> {
		var keys = [];
		while (true) {
			keys.push(simpleKey());
			skipSpace();
			if (at(position) != ".".code)
				return keys;
			position++;
			skipSpace();
		}
	}

	function simpleKey():String {
		var code = at(position);
		if (code == "\"".code)
			return basicString();
		if (code == "'".code)
			return literalString();
		var start = position;
		while (position < length && isBareKey(at(position)))
			position++;
		if (position == start)
			throw error(position >= length ? "expected a key, found the end of the document" : "expected a key", start);
		return bytes.getString(start, position - start);
	}

	function value():Entry {
		if (position >= length)
			throw error("expected a value, found the end of the document", position);
		var code = at(position);
		return switch code {
			case "[".code: Value(array());
			case "{".code: Child(inlineTable());
			case _: Value(scalar());
		}
	}

	/** A value inside an array, where an inline table is already a finished object. */
	function element():Dynamic {
		return switch value() {
			case Value(value): value;
			case Child(table): table.toDynamic();
			case Tables(_): throw error("unexpected array of tables", position);
		}
	}

	function scalar():Dynamic {
		var code = at(position);
		if (code == "\"".code)
			return startsWith("\"\"\"") ? multiLineBasicString() : basicString();
		if (code == "'".code)
			return startsWith("'''") ? multiLineLiteralString() : literalString();
		if (startsWith("true") && !isBareKey(at(position + 4))) {
			position += 4;
			return true;
		}
		if (startsWith("false") && !isBareKey(at(position + 5))) {
			position += 5;
			return false;
		}
		if (isDigit(code) && isDigit(at(position + 1))) {
			if (isDigit(at(position + 2)) && isDigit(at(position + 3)) && at(position + 4) == "-".code)
				return dateTime();
			if (at(position + 2) == ":".code)
				return dateTime();
		}
		return number();
	}

	function array():Array<Dynamic> {
		position++;
		var result:Array<Dynamic> = [];
		while (true) {
			skipBlank();
			if (at(position) == "]".code) {
				position++;
				return result;
			}
			result.push(element());
			skipBlank();
			var code = at(position);
			if (code == ",".code)
				position++;
			else if (code != "]".code)
				throw error("expected , or ] in an array", position);
		}
	}

	/** `{a = 1, b.c = 2}`, on one line and closed for good: neither headers nor later keys add to it. */
	function inlineTable():Table {
		position++;
		var table = new Table(Defined);
		skipSpace();
		if (at(position) == "}".code) {
			position++;
			table.freeze();
			return table;
		}
		while (true) {
			skipSpace();
			keyValue(table);
			skipSpace();
			var code = at(position);
			position++;
			if (code == "}".code) {
				table.freeze();
				return table;
			}
			if (code != ",".code)
				throw error("expected , or } in an inline table", position - 1);
		}
	}

	function basicString():String {
		var start = position;
		position++;
		var output = new StringBuf(), run = position;
		while (true) {
			if (position >= length)
				throw error("unterminated string", start);
			var code = at(position);
			if (code == "\"".code) {
				output.add(bytes.getString(run, position - run));
				position++;
				return output.toString();
			}
			if (code == "\\".code) {
				output.add(bytes.getString(run, position - run));
				escape(output);
				run = position;
			} else if (code == "\n".code || code == "\r".code) {
				throw error("a basic string cannot span lines; use \"\"\" for a multi-line string", position);
			} else {
				checkCharacter(code);
				position++;
			}
		}
	}

	function multiLineBasicString():String {
		var start = position;
		position += 3;
		skipFirstNewline();
		var output = new StringBuf(), run = position;
		while (true) {
			if (position >= length)
				throw error("unterminated multi-line string", start);
			var code = at(position);
			if (code == "\"".code && startsWith("\"\"\"")) {
				output.add(bytes.getString(run, position - run));
				return closeMultiLine(output, "\"".code);
			}
			if (code == "\\".code) {
				output.add(bytes.getString(run, position - run));
				if (!lineEndingBackslash())
					escape(output);
				run = position;
			} else
				multiLineCharacter(code);
		}
	}

	function literalString():String {
		var start = position;
		position++;
		var run = position;
		while (true) {
			if (position >= length)
				throw error("unterminated string", start);
			var code = at(position);
			if (code == "'".code) {
				position++;
				return bytes.getString(run, position - 1 - run);
			}
			if (code == "\n".code || code == "\r".code)
				throw error("a literal string cannot span lines; use ''' for a multi-line string", position);
			checkCharacter(code);
			position++;
		}
	}

	function multiLineLiteralString():String {
		var start = position;
		position += 3;
		skipFirstNewline();
		var run = position;
		while (true) {
			if (position >= length)
				throw error("unterminated multi-line string", start);
			var code = at(position);
			if (code == "'".code && startsWith("'''")) {
				var output = new StringBuf();
				output.add(bytes.getString(run, position - run));
				return closeMultiLine(output, "'".code);
			}
			multiLineCharacter(code);
		}
	}

	/** At the first of three or more closing quotes: up to two more belong to the string (`""""a""""`). */
	function closeMultiLine(output:StringBuf, quote:Int):String {
		var count = 0;
		while (at(position + count) == quote)
			count++;
		if (count > 5)
			throw error("too many quotes at the end of a multi-line string", position);
		for (_ in 3...count)
			output.addChar(quote);
		position += count;
		return output.toString();
	}

	function skipFirstNewline():Void {
		if (at(position) == "\n".code)
			position++;
		else if (at(position) == "\r".code && at(position + 1) == "\n".code)
			position += 2;
	}

	function multiLineCharacter(code:Int):Void {
		if (code == "\r".code) {
			if (at(position + 1) != "\n".code)
				throw error("a carriage return must be followed by a line feed", position);
			position += 2;
		} else {
			if (code != "\n".code)
				checkCharacter(code);
			position++;
		}
	}

	/** A backslash ending a line in a multi-line basic string drops it and the whitespace and line breaks after it. */
	function lineEndingBackslash():Bool {
		var scan = position + 1;
		while (at(scan) == " ".code || at(scan) == "\t".code)
			scan++;
		if (at(scan) != "\n".code && !(at(scan) == "\r".code && at(scan + 1) == "\n".code))
			return false;
		position = scan;
		while (true) {
			var code = at(position);
			if (code == " ".code || code == "\t".code || code == "\n".code)
				position++;
			else if (code == "\r".code && at(position + 1) == "\n".code)
				position += 2;
			else
				return true;
		}
	}

	function escape(output:StringBuf):Void {
		var start = position;
		position++;
		var code = at(position++);
		switch code {
			case "b".code: output.addChar(8);
			case "t".code: output.addChar(9);
			case "n".code: output.addChar(10);
			case "f".code: output.addChar(12);
			case "r".code: output.addChar(13);
			case "\"".code: output.addChar(34);
			case "\\".code: output.addChar(92);
			case "u".code: output.addChar(unicode(4, start));
			case "U".code: output.addChar(unicode(8, start));
			case _: throw error("unknown escape sequence", start);
		}
	}

	function unicode(digits:Int, start:Int):Int {
		var value = 0;
		for (_ in 0...digits) {
			var digit = hexDigit(at(position));
			if (digit < 0)
				throw error('\\${digits == 4 ? "u" : "U"} needs $digits hexadecimal digits', start);
			if (value > 0x10FFFF)
				throw error("escaped code point is above U+10FFFF", start);
			value = value * 16 + digit;
			position++;
		}
		if (value > 0x10FFFF || value >= 0xD800 && value <= 0xDFFF)
			throw error("escape is not a Unicode scalar value", start);
		return value;
	}

	function checkCharacter(code:Int):Void {
		if (code < 0x20 && code != "\t".code || code == 0x7F)
			throw error("control characters must be escaped", position);
	}

	/** An integer or a float: the token up to the next delimiter, checked against TOML's grammar. */
	function number():Dynamic {
		var start = position;
		while (position < length && !isDelimiter(at(position)))
			position++;
		if (position == start)
			throw error("expected a value", start);
		var token = bytes.getString(start, position - start);
		var signed = token.charCodeAt(0) == "+".code || token.charCodeAt(0) == "-".code,
			negative = token.charCodeAt(0) == "-".code,
			body = signed ? token.substr(1) : token;
		if (body == "inf")
			return negative ? Math.NEGATIVE_INFINITY : Math.POSITIVE_INFINITY;
		if (body == "nan")
			return Math.NaN;
		if (!signed && body.length > 2 && body.charCodeAt(0) == "0".code) {
			var prefix = body.charCodeAt(1);
			var base = prefix == "x".code ? 16 : prefix == "o".code ? 8 : prefix == "b".code ? 2 : 0;
			if (base != 0)
				return radixInteger(body.substr(2), base, start);
		}
		if (body.length == 0 || !isDigit(body.charCodeAt(0)))
			throw error('invalid value "$token"', start);
		var digits = new StringBuf(),
			index = digitRun(body, 0, digits, "integer part", start),
			fraction = false,
			exponent = false;
		if (body.charCodeAt(0) == "0".code && index > 1)
			throw error("invalid number: leading zeros are not allowed", start);
		if (index < body.length && body.charCodeAt(index) == ".".code) {
			fraction = true;
			digits.add(".");
			index = digitRun(body, index + 1, digits, "fraction", start);
		}
		if (index < body.length && (body.charCodeAt(index) == "e".code || body.charCodeAt(index) == "E".code)) {
			exponent = true;
			digits.add("e");
			index++;
			if (index < body.length && (body.charCodeAt(index) == "+".code || body.charCodeAt(index) == "-".code)) {
				digits.addChar(body.charCodeAt(index));
				index++;
			}
			index = digitRun(body, index, digits, "exponent", start);
		}
		if (index != body.length)
			throw error('invalid value "$token"', start);
		var text = digits.toString();
		if (fraction || exponent)
			return negative ? -Std.parseFloat(text) : Std.parseFloat(text);
		if (text.length > 19 || text.length == 19 && text > (negative ? "9223372036854775808" : "9223372036854775807"))
			throw error("integer does not fit in 64 bits", start);
		var value = 0.0;
		for (digit in 0...text.length)
			value = value * 10 + (text.charCodeAt(digit) - "0".code);
		return integer(negative ? -value : value);
	}

	/** Digits from `index` of `body`, with single underscores between them, added to `output`; the index after them. */
	function digitRun(body:String, index:Int, output:StringBuf, what:String, start:Int):Int {
		var first = index;
		while (index < body.length) {
			var code = body.charCodeAt(index);
			if (isDigit(code)) {
				output.addChar(code);
				index++;
			} else if (code == "_".code && index > first && index + 1 < body.length
				&& isDigit(body.charCodeAt(index + 1)))
				index++;
			else
				break;
		}
		if (index == first)
			throw error('invalid number: expected digits in the $what', start);
		return index;
	}

	function radixInteger(body:String, base:Int, start:Int):Dynamic {
		var value = 0.0, bitLength = 0, previousDigit = false, bitsPerDigit = base == 16 ? 4 : base == 8 ? 3 : 1;
		for (index in 0...body.length) {
			var code = body.charCodeAt(index);
			if (code == "_".code && previousDigit && index + 1 < body.length) {
				previousDigit = false;
				continue;
			}
			var digit = hexDigit(code);
			if (digit < 0 || digit >= base)
				throw error("invalid digit in a base-" + base + " integer", start);
			if (bitLength > 0)
				bitLength += bitsPerDigit;
			else
				while (digit >> bitLength != 0)
					bitLength++;
			value = value * base + digit;
			previousDigit = true;
		}
		if (!previousDigit)
			throw error("invalid number: expected digits", start);
		if (bitLength > 63)
			throw error("integer does not fit in 64 bits", start);
		return integer(value);
	}

	static function integer(value:Float):Dynamic {
		if (value >= -2147483648.0 && value <= 2147483647.0)
			return Std.int(value);
		return value;
	}

	/** `1979-05-27`, `1979-05-27T07:32:00.5-07:00` (`t` or a space may separate), or `07:32:00`. */
	function dateTime():TomlDateTime {
		var start = position, kind:TomlDateTimeKind;
		if (at(position + 2) == ":".code) {
			time(start);
			kind = LocalTime;
		} else {
			date(start);
			var separator = at(position);
			if ((separator == "T".code || separator == "t".code || separator == " ".code) && isDigit(at(position + 1))
				&& isDigit(at(position + 2)) && at(position + 3) == ":".code) {
				position++;
				time(start);
				kind = LocalDateTime;
				var code = at(position);
				if (code == "Z".code || code == "z".code) {
					position++;
					kind = OffsetDateTime;
				} else if (code == "+".code || code == "-".code) {
					position++;
					if (twoDigits(start) > 23 || at(position++) != ":".code || twoDigits(start) > 59)
						throw error("invalid time offset", start);
					kind = OffsetDateTime;
				}
			} else
				kind = LocalDate;
		}
		if (position < length && !isDelimiter(at(position)))
			throw error("invalid date or time", start);
		return new TomlDateTime(kind, bytes.getString(start, position - start));
	}

	function date(start:Int):Void {
		var year = twoDigits(start) * 100 + twoDigits(start);
		if (at(position++) != "-".code)
			throw error("invalid date", start);
		var month = twoDigits(start);
		if (at(position++) != "-".code)
			throw error("invalid date", start);
		var day = twoDigits(start);
		var leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0),
			days = month == 2 ? (leap ? 29 : 28) : month == 4 || month == 6 || month == 9 || month == 11 ? 30 : 31;
		if (month < 1 || month > 12 || day < 1 || day > days)
			throw error("invalid date", start);
	}

	function time(start:Int):Void {
		var hour = twoDigits(start);
		if (at(position++) != ":".code)
			throw error("invalid time", start);
		var minute = twoDigits(start);
		if (at(position++) != ":".code)
			throw error("invalid time: seconds are required", start);
		var second = twoDigits(start);
		if (hour > 23 || minute > 59 || second > 60)
			throw error("invalid time", start);
		if (at(position) == ".".code) {
			position++;
			if (!isDigit(at(position)))
				throw error("invalid time: expected digits after the decimal point", start);
			while (isDigit(at(position)))
				position++;
		}
	}

	function twoDigits(start:Int):Int {
		var high = at(position), low = at(position + 1);
		if (!isDigit(high) || !isDigit(low))
			throw error("invalid date or time", start);
		position += 2;
		return (high - "0".code) * 10 + low - "0".code;
	}

	/** Spaces and tabs. */
	function skipSpace():Void {
		while (position < length && (at(position) == " ".code || at(position) == "\t".code))
			position++;
	}

	/** Whitespace, line breaks and comments, as between an array's values. */
	function skipBlank():Void {
		while (true) {
			skipSpace();
			var code = at(position);
			if (code == "#".code)
				comment();
			else if (code == "\n".code || code == "\r".code)
				newline();
			else
				return;
		}
	}

	/** After a key/value pair or a header: an optional comment, then a line break or the end. */
	function endLine():Void {
		skipSpace();
		if (at(position) == "#".code)
			comment();
		if (position >= length)
			return;
		var code = at(position);
		if (code != "\n".code && code != "\r".code)
			throw error("expected the end of the line", position);
		newline();
	}

	function comment():Void {
		position++;
		while (position < length && at(position) != "\n".code && at(position) != "\r".code) {
			checkCharacter(at(position));
			position++;
		}
	}

	function newline():Void {
		if (at(position) == "\r".code) {
			if (at(position + 1) != "\n".code)
				throw error("a carriage return must be followed by a line feed", position);
			position++;
		}
		position++;
	}

	function expect(code:Int, message:String):Void {
		if (at(position) != code)
			throw error(message, position);
		position++;
	}

	function startsWith(text:String):Bool {
		for (index in 0...text.length)
			if (at(position + index) != text.charCodeAt(index))
				return false;
		return true;
	}

	/** The byte at `offset`, or -1 past the end. */
	inline function at(offset:Int):Int
		return offset < length ? bytes.get(offset) : -1;

	function error(reason:String, offset:Int):TomlError {
		var line = 1, lineStart = 0;
		for (index in 0...(offset < length ? offset : length))
			if (bytes.get(index) == "\n".code) {
				line++;
				lineStart = index + 1;
			}
		var column = 1;
		for (index in lineStart...(offset < length ? offset : length))
			if (bytes.get(index) & 0xC0 != 0x80)
				column++;
		return new TomlError(reason, line, column);
	}

	static function isBareKey(code:Int):Bool
		return code >= "a".code && code <= "z".code || code >= "A".code && code <= "Z".code || isDigit(code)
			|| code == "_".code
			|| code == "-".code;

	static inline function isDigit(code:Int):Bool
		return code >= "0".code && code <= "9".code;

	static function isDelimiter(code:Int):Bool
		return code == " ".code || code == "\t".code || code == "\n".code || code == "\r".code || code == ",".code
			|| code == "]".code || code == "}".code || code == "#".code || code < 0;

	static function hexDigit(code:Int):Int {
		if (isDigit(code))
			return code - "0".code;
		if (code >= "a".code && code <= "f".code)
			return code - "a".code + 10;
		if (code >= "A".code && code <= "F".code)
			return code - "A".code + 10;
		return -1;
	}
}

/** How a table came to be, which decides what may add to it later. */
private enum TableOrigin {
	/** Made on the way to a header's table (`a` for `[a.b]`); a later `[a]` may still define it. */
	Implicit;

	/** By a header, or the document itself. */
	Defined;

	/** By a dotted key (`a.b = 1` makes `a`); more dotted keys may add to it, a header may not define it. */
	Dotted;

	/** An inline table: nothing adds to it. */
	Frozen;
}

private enum Entry {
	Value(value:Dynamic);
	Child(table:Table);
	Tables(tables:Array<Table>);
}

/** A table while the document is read, which knows its keys' order and origin; `toDynamic` makes the object the reader gets. */
private class Table {
	public var origin:TableOrigin;
	public final names:Array<String> = [];
	public final entries = new Map<String, Entry>();

	public function new(origin:TableOrigin)
		this.origin = origin;

	public function add(name:String, entry:Entry):Void {
		names.push(name);
		entries.set(name, entry);
	}

	public function freeze():Void {
		origin = Frozen;
		for (entry in entries)
			switch entry {
				case Child(table): table.freeze();
				case _:
			}
	}

	public function toDynamic():Dynamic {
		var result:Dynamic = {};
		for (name in names)
			Reflect.setField(result, name, switch entries.get(name) {
				case Value(value): value;
				case Child(table): table.toDynamic();
				case Tables(tables): [for (table in tables) table.toDynamic()];
				case null: null;
			});
		return result;
	}
}

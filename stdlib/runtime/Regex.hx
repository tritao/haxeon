package runtime;

#if wasm
/**
 * The Wasm regular-expression engine behind `EReg`, which HashLink backs with PCRE2. Patterns
 * compile to a small instruction program run by a backtracking machine with an explicit stack,
 * so long subjects do not deepen the Wasm call stack.
 *
 * Supported: literals and escapes (`\t \n \r \f \v \0 \xhh \uhhhh` and escaped punctuation),
 * `.`, classes with ranges and negation, `\d \w \s \D \W \S`, `\b \B`, anchors `^ $`,
 * quantifiers `* + ? {n} {n,} {n,m}` with lazy `?` forms, capturing and `(?:...)` groups,
 * `(?=...)` and `(?!...)` lookahead, and alternation. Options: `i` (ASCII case folding), `m`,
 * `s` and `u` (always on). Anything else, such as backreferences, lookbehind, named groups
 * or Unicode properties, throws when the pattern is compiled rather than matching wrongly.
 *
 * Subjects are the target's UTF-8 strings: positions are byte offsets, as `String` uses on
 * Wasm, while `.` and classes consume one whole code point.
 */
class Regex {
	static inline var CHAR = 0;
	static inline var ANY = 1;
	static inline var CLASS = 2;
	static inline var SPLIT = 3;
	static inline var JUMP = 4;
	static inline var SAVE = 5;
	static inline var LINE_START = 6;
	static inline var LINE_END = 7;
	static inline var WORD_BOUNDARY = 8;
	static inline var NOT_WORD_BOUNDARY = 9;
	static inline var MATCH = 10;
	static inline var MARK = 11;
	static inline var PROGRESS = 12;
	static inline var LOOKAHEAD = 13;
	static inline var NEGATIVE_LOOKAHEAD = 14;

	/** Expanded counted repetitions beyond this many instructions are refused. */
	static inline var MAX_PROGRAM = 100000;

	final operations:Array<Int> = [];
	final first:Array<Int> = [];
	final second:Array<Int> = [];
	final classes:Array<RegexClass> = [];
	final ignoreCase:Bool;
	final multiline:Bool;
	final dotAll:Bool;
	final groupCount:Int;
	final slotCount:Int;
	final slots:Array<Int> = [];
	var matched = false;

	// Backtracking stack: kind (0 resume at pc/position, 1 restore slot to value), a, b.
	final stackKinds:Array<Int> = [];
	final stackFirst:Array<Int> = [];
	final stackSecond:Array<Int> = [];

	public function new(pattern:String, options:String) {
		var ignoreCase = false, multiline = false, dotAll = false;
		for (index in 0...options.length) {
			var option = options.charAt(index);
			if (option == "i")
				ignoreCase = true;
			else if (option == "m")
				multiline = true;
			else if (option == "s")
				dotAll = true;
			else if (option != "u")
				throw 'Unsupported regular-expression option "$option"';
		}
		this.ignoreCase = ignoreCase;
		this.multiline = multiline;
		this.dotAll = dotAll;
		var parser = new RegexParser(pattern);
		var tree = parser.parse();
		groupCount = parser.groupCount + 1;
		// Capture slots come first; each unbounded loop then gets a progress slot.
		var compiler = new RegexCompiler(this, groupCount * 2);
		emit(SAVE, 0, 0);
		compiler.compile(tree);
		emit(SAVE, 1, 0);
		emit(MATCH, 0, 0);
		slotCount = compiler.nextSlot;
		for (index in 0...slotCount)
			slots.push(-1);
	}

	/** Searches `value` from `position`, treating `position + length` as the subject's end. */
	public function match(value:String, position:Int, length:Int):Bool {
		var end = position + length;
		matched = false;
		var start = position;
		while (start <= end) {
			for (index in 0...slotCount)
				slots[index] = -1;
			if (run(value, 0, start, end) >= 0) {
				matched = true;
				return true;
			}
			if (start >= end)
				break;
			start = nextCodePoint(value, start, end);
		}
		return false;
	}

	/** A group's start offset, or -1 when the group did not take part in the match. */
	public function matchedPos(group:Int):Int {
		requireGroup(group);
		return slots[group * 2 + 1] < 0 ? -1 : slots[group * 2];
	}

	public function matchedLength(group:Int):Int {
		requireGroup(group);
		var start = slots[group * 2], end = slots[group * 2 + 1];
		return start < 0 || end < 0 ? -1 : end - start;
	}

	/** The number of groups including the whole match, or -1 before a successful match. */
	public function matchedNum():Int
		return matched ? groupCount : -1;

	function requireGroup(group:Int):Void {
		if (!matched)
			throw "Calling regexp_matched_pos() on an unmatched regexp";
		if (group < 0 || group >= groupCount)
			throw 'Matched index $group outside bounds';
	}

	public function emit(operation:Int, a:Int, b:Int):Int {
		if (operations.length >= MAX_PROGRAM)
			throw "Regular expression is too large";
		operations.push(operation);
		first.push(a);
		second.push(b);
		return operations.length - 1;
	}

	public function patch(at:Int, a:Int, b:Int):Void {
		first[at] = a;
		second[at] = b;
	}

	public function programLength():Int
		return operations.length;

	public function addClass(value:RegexClass):Int {
		classes.push(value);
		return classes.length - 1;
	}

	/**
	 * Runs the program from `pc` at `position` until MATCH, returning the end offset or -1.
	 * Slots changed on a failed path are restored before the next alternative is tried.
	 */
	function run(value:String, startPc:Int, startPosition:Int, end:Int):Int {
		var base = stackKinds.length;
		var pc = startPc, position = startPosition;
		while (true) {
			var failed = false;
			switch operations[pc] {
				case CHAR:
					if (position >= end) {
						failed = true;
					} else {
						var code = codePointAt(value, position, end);
						if (code == first[pc] || ignoreCase && fold(code) == fold(first[pc])) {
							position = nextCodePoint(value, position, end);
							pc++;
						} else
							failed = true;
					}
				case ANY:
					if (position >= end || !dotAll && value.charCodeAt(position) == "\n".code)
						failed = true;
					else {
						position = nextCodePoint(value, position, end);
						pc++;
					}
				case CLASS:
					if (position >= end || !classes[first[pc]].contains(codePointAt(value, position, end), ignoreCase))
						failed = true;
					else {
						position = nextCodePoint(value, position, end);
						pc++;
					}
				case SPLIT:
					push(0, second[pc], position);
					pc = first[pc];
				case JUMP:
					pc = first[pc];
				case SAVE, MARK:
					push(1, first[pc], slots[first[pc]]);
					slots[first[pc]] = position;
					pc++;
				case PROGRESS:
					// An iteration that consumed nothing would loop forever; end it here instead.
					if (slots[first[pc]] == position)
						failed = true;
					else
						pc++;
				case LINE_START:
					if (position == 0 || multiline && value.charCodeAt(position - 1) == "\n".code)
						pc++;
					else
						failed = true;
				case LINE_END:
					// As in PCRE, `$` also matches before a final newline.
					if (position == end
						|| multiline && value.charCodeAt(position) == "\n".code
						|| position == end - 1 && value.charCodeAt(position) == "\n".code)
						pc++;
					else
						failed = true;
				case WORD_BOUNDARY, NOT_WORD_BOUNDARY:
					var before = position > 0 && isWordByte(value.charCodeAt(position - 1)),
						after = position < end && isWordByte(value.charCodeAt(position));
					if ((before != after) == (operations[pc] == WORD_BOUNDARY))
						pc++;
					else
						failed = true;
				case LOOKAHEAD, NEGATIVE_LOOKAHEAD:
					var found = run(value, pc + 1, position, end) >= 0;
					if (found == (operations[pc] == LOOKAHEAD))
						pc = first[pc];
					else
						failed = true;
				case MATCH:
					stackKinds.resize(base);
					stackFirst.resize(base);
					stackSecond.resize(base);
					return position;
				case operation:
					throw 'Invalid regular-expression instruction $operation';
			}
			if (failed) {
				var resumed = false;
				while (stackKinds.length > base) {
					var top = stackKinds.length - 1;
					var kind = stackKinds[top], a = stackFirst[top], b = stackSecond[top];
					stackKinds.resize(top);
					stackFirst.resize(top);
					stackSecond.resize(top);
					if (kind == 1)
						slots[a] = b;
					else {
						pc = a;
						position = b;
						resumed = true;
						break;
					}
				}
				if (!resumed)
					return -1;
			}
		}
	}

	function push(kind:Int, a:Int, b:Int):Void {
		stackKinds.push(kind);
		stackFirst.push(a);
		stackSecond.push(b);
	}

	static function isWordByte(code:Int):Bool
		return code >= "a".code && code <= "z".code || code >= "A".code && code <= "Z".code || code >= "0".code && code <= "9".code || code == "_".code;

	public static function fold(code:Int):Int
		return code >= "A".code && code <= "Z".code ? code + 32 : code;

	/** Decodes the UTF-8 code point at `position`; a malformed byte reads as itself. */
	public static function codePointAt(value:String, position:Int, end:Int):Int {
		var lead = value.charCodeAt(position);
		if (lead < 0xC0)
			return lead;
		var width = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2;
		if (position + width > end)
			return lead;
		var code = lead & (width == 2 ? 0x1F : width == 3 ? 0x0F : 0x07);
		for (index in 1...width)
			code = (code << 6) | (value.charCodeAt(position + index) & 0x3F);
		return code;
	}

	public static function nextCodePoint(value:String, position:Int, end:Int):Int {
		var lead = value.charCodeAt(position);
		var width = lead < 0xC0 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2;
		return position + width > end ? position + 1 : position + width;
	}
}

/** A parsed pattern node; `kind` selects which fields apply. */
private class RegexNode {
	public static inline var CHAR = 0;
	public static inline var ANY = 1;
	public static inline var CLASS = 2;
	public static inline var LINE_START = 3;
	public static inline var LINE_END = 4;
	public static inline var WORD_BOUNDARY = 5;
	public static inline var NOT_WORD_BOUNDARY = 6;
	public static inline var GROUP = 7;
	public static inline var CONCAT = 8;
	public static inline var ALTERNATION = 9;
	public static inline var REPEAT = 10;
	public static inline var LOOKAHEAD = 11;
	public static inline var NEGATIVE_LOOKAHEAD = 12;

	public final kind:Int;
	public final children:Array<RegexNode> = [];
	public var code = 0;
	public var group = -1;
	public var minimum = 0;
	public var maximum = 0;
	public var greedy = true;
	public var set:RegexClass = null;

	public function new(kind:Int) {
		this.kind = kind;
	}
}

/** Code-point ranges plus shorthand sets (`d`, `w`, `s`, negated in uppercase). */
private class RegexClass {
	public final ranges:Array<Int> = [];
	public final shorthands:Array<Int> = [];
	public var negated = false;

	public function new() {}

	public function contains(code:Int, ignoreCase:Bool):Bool {
		var found = containsExactly(code);
		if (!found && ignoreCase) {
			var lower = Regex.fold(code);
			var upper = lower >= "a".code && lower <= "z".code ? lower - 32 : lower;
			found = containsExactly(lower) || containsExactly(upper);
		}
		return found != negated;
	}

	function containsExactly(code:Int):Bool {
		var index = 0;
		while (index < ranges.length) {
			if (code >= ranges[index] && code <= ranges[index + 1])
				return true;
			index += 2;
		}
		for (shorthand in shorthands)
			if (inShorthand(shorthand, code))
				return true;
		return false;
	}

	public static function inShorthand(shorthand:Int, code:Int):Bool {
		return switch shorthand {
			case "d".code: code >= "0".code && code <= "9".code;
			case "D".code: !(code >= "0".code && code <= "9".code);
			case "w".code: code >= "a".code && code <= "z".code || code >= "A".code && code <= "Z".code || code >= "0".code && code <= "9".code
				|| code == "_".code;
			case "W".code: !inShorthand("w".code, code);
			case "s".code: code == 32 || code >= 9 && code <= 13;
			case "S".code: !inShorthand("s".code, code);
			case _: false;
		};
	}
}

/** Recursive-descent parser from pattern text to `RegexNode` trees. */
private class RegexParser {
	final pattern:String;
	var position = 0;

	public var groupCount = 0;

	public function new(pattern:String) {
		this.pattern = pattern == null ? "" : pattern;
	}

	public function parse():RegexNode {
		var node = parseAlternation();
		if (position < pattern.length)
			fail(pattern.charAt(position) == ")" ? "unmatched closing parenthesis" : "unexpected character");
		return node;
	}

	function parseAlternation():RegexNode {
		var first = parseSequence();
		if (!peek("|".code))
			return first;
		var node = new RegexNode(RegexNode.ALTERNATION);
		node.children.push(first);
		while (peek("|".code)) {
			position++;
			node.children.push(parseSequence());
		}
		return node;
	}

	function parseSequence():RegexNode {
		var node = new RegexNode(RegexNode.CONCAT);
		while (position < pattern.length && !peek("|".code) && !peek(")".code)) {
			var atom = parseAtom();
			node.children.push(parseQuantifier(atom));
		}
		return node;
	}

	function parseQuantifier(atom:RegexNode):RegexNode {
		var minimum = -1, maximum = -1;
		if (peek("*".code)) {
			minimum = 0;
			position++;
		} else if (peek("+".code)) {
			minimum = 1;
			position++;
		} else if (peek("?".code)) {
			minimum = 0;
			maximum = 1;
			position++;
		} else if (peek("{".code)) {
			// `{` that does not start a well-formed count is a literal, as in PCRE.
			var saved = position;
			position++;
			var low = readNumber(), high = low, valid = low >= 0;
			if (valid && peek(",".code)) {
				position++;
				if (peek("}".code))
					high = -1;
				else {
					high = readNumber();
					valid = high >= 0;
				}
			}
			if (valid && peek("}".code)) {
				position++;
				if (high >= 0 && high < low)
					fail("numbers out of order in {} quantifier");
				minimum = low;
				maximum = high;
			}
			if (minimum < 0) {
				position = saved;
				return atom;
			}
		} else
			return atom;
		switch atom.kind {
			case RegexNode.LINE_START | RegexNode.LINE_END | RegexNode.WORD_BOUNDARY | RegexNode.NOT_WORD_BOUNDARY:
				fail("quantifier does not follow a repeatable item");
			case _:
		}
		var node = new RegexNode(RegexNode.REPEAT);
		node.children.push(atom);
		node.minimum = minimum;
		node.maximum = maximum;
		if (peek("?".code)) {
			node.greedy = false;
			position++;
		} else if (peek("+".code))
			fail("possessive quantifiers are not supported");
		return node;
	}

	/** Reads decimal digits; -1 when there are none. */
	function readNumber():Int {
		var start = position, value = 0;
		while (position < pattern.length && isDigit(pattern.charCodeAt(position))) {
			value = value * 10 + pattern.charCodeAt(position) - "0".code;
			position++;
		}
		return position == start ? -1 : value;
	}

	function parseAtom():RegexNode {
		var code = pattern.charCodeAt(position);
		switch code {
			case "(".code:
				position++;
				var node:RegexNode;
				if (peek("?".code)) {
					position++;
					if (peek(":".code))
						node = new RegexNode(RegexNode.GROUP);
					else if (peek("=".code))
						node = new RegexNode(RegexNode.LOOKAHEAD);
					else if (peek("!".code))
						node = new RegexNode(RegexNode.NEGATIVE_LOOKAHEAD);
					else
						return fail("group syntax (?" + pattern.charAt(position) + " is not supported");
					position++;
				} else {
					node = new RegexNode(RegexNode.GROUP);
					node.group = ++groupCount;
				}
				node.children.push(parseAlternation());
				if (!peek(")".code))
					fail("missing closing parenthesis");
				position++;
				return node;
			case "[".code:
				position++;
				return parseClass();
			case ".".code:
				position++;
				return new RegexNode(RegexNode.ANY);
			case "^".code:
				position++;
				return new RegexNode(RegexNode.LINE_START);
			case "$".code:
				position++;
				return new RegexNode(RegexNode.LINE_END);
			case "\\".code:
				position++;
				return parseEscape();
			case "*".code | "+".code | "?".code:
				return fail("quantifier does not follow a repeatable item");
			case _:
		}
		return literal(readCodePoint());
	}

	function parseEscape():RegexNode {
		if (position >= pattern.length)
			return fail("pattern ends with a backslash");
		var code = pattern.charCodeAt(position);
		switch code {
			case "d".code | "D".code | "w".code | "W".code | "s".code | "S".code:
				position++;
				var set = new RegexClass();
				set.shorthands.push(code);
				var node = new RegexNode(RegexNode.CLASS);
				node.set = set;
				return node;
			case "b".code:
				position++;
				return new RegexNode(RegexNode.WORD_BOUNDARY);
			case "B".code:
				position++;
				return new RegexNode(RegexNode.NOT_WORD_BOUNDARY);
			case _:
		}
		return literal(escapedCode());
	}

	/** The code point of a character escape after its backslash, shared by atoms and classes. */
	function escapedCode():Int {
		var code = pattern.charCodeAt(position);
		switch code {
			case "t".code:
				position++;
				return 9;
			case "n".code:
				position++;
				return 10;
			case "r".code:
				position++;
				return 13;
			case "f".code:
				position++;
				return 12;
			case "v".code:
				position++;
				return 11;
			case "0".code:
				position++;
				return 0;
			case "x".code:
				position++;
				return readHex(2);
			case "u".code:
				position++;
				return readHex(4);
			case _:
		}
		if (isDigit(code))
			fail("backreferences are not supported");
		if (isWordCode(code))
			fail("escape \\" + pattern.charAt(position) + " is not supported");
		return readCodePoint();
	}

	function readHex(digits:Int):Int {
		var value = 0;
		for (index in 0...digits) {
			if (position >= pattern.length)
				fail("incomplete hexadecimal escape");
			var code = pattern.charCodeAt(position++);
			var digit = isDigit(code) ? code - "0".code : code >= "a".code && code <= "f".code ? code - "a".code + 10 : code >= "A".code
				&& code <= "F".code ? code - "A".code + 10 : -1;
			if (digit < 0)
				fail("invalid hexadecimal escape");
			value = value * 16 + digit;
		}
		return value;
	}

	function parseClass():RegexNode {
		var node = new RegexNode(RegexNode.CLASS);
		var set = new RegexClass();
		node.set = set;
		if (peek("^".code)) {
			set.negated = true;
			position++;
		}
		var firstItem = true;
		while (true) {
			if (position >= pattern.length)
				fail("missing terminating ] for character class");
			var code = pattern.charCodeAt(position);
			// A leading `]` is a literal member, as in PCRE.
			if (code == "]".code && !firstItem) {
				position++;
				return node;
			}
			firstItem = false;
			var low:Int;
			if (code == "\\".code) {
				position++;
				if (position >= pattern.length)
					fail("pattern ends with a backslash");
				var escaped = pattern.charCodeAt(position);
				if (escaped == "d".code || escaped == "D".code || escaped == "w".code || escaped == "W".code || escaped == "s".code || escaped == "S".code) {
					position++;
					set.shorthands.push(escaped);
					continue;
				}
				if (escaped == "b".code) {
					// Inside a class, \b is a backspace as in PCRE.
					position++;
					low = 8;
				} else
					low = escapedCode();
			} else if (code == "[".code && position + 1 < pattern.length && pattern.charCodeAt(position + 1) == ":".code)
				return fail("POSIX character classes are not supported");
			else
				low = readCodePoint();
			var high = low;
			if (peek("-".code) && position + 1 < pattern.length && pattern.charCodeAt(position + 1) != "]".code) {
				position++;
				if (peek("\\".code)) {
					position++;
					high = escapedCode();
				} else
					high = readCodePoint();
				if (high < low)
					fail("range out of order in character class");
			}
			set.ranges.push(low);
			set.ranges.push(high);
		}
	}

	function literal(code:Int):RegexNode {
		var node = new RegexNode(RegexNode.CHAR);
		node.code = code;
		return node;
	}

	function readCodePoint():Int {
		var code = Regex.codePointAt(pattern, position, pattern.length);
		position = Regex.nextCodePoint(pattern, position, pattern.length);
		return code;
	}

	inline function peek(code:Int):Bool
		return position < pattern.length && pattern.charCodeAt(position) == code;

	static function isDigit(code:Int):Bool
		return code >= "0".code && code <= "9".code;

	static function isWordCode(code:Int):Bool
		return isDigit(code) || code >= "a".code && code <= "z".code || code >= "A".code && code <= "Z".code;

	function fail(reason:String):RegexNode
		throw 'Invalid regular expression "$pattern" at offset $position: $reason';
}

/** Lowers `RegexNode` trees to the instructions `Regex.run` executes. */
private class RegexCompiler {
	final program:Regex;

	public var nextSlot:Int;

	public function new(program:Regex, firstFreeSlot:Int) {
		this.program = program;
		nextSlot = firstFreeSlot;
	}

	public function compile(node:RegexNode):Void {
		switch node.kind {
			case RegexNode.CHAR:
				program.emit(Regex.CHAR, node.code, 0);
			case RegexNode.ANY:
				program.emit(Regex.ANY, 0, 0);
			case RegexNode.CLASS:
				program.emit(Regex.CLASS, program.addClass(node.set), 0);
			case RegexNode.LINE_START:
				program.emit(Regex.LINE_START, 0, 0);
			case RegexNode.LINE_END:
				program.emit(Regex.LINE_END, 0, 0);
			case RegexNode.WORD_BOUNDARY:
				program.emit(Regex.WORD_BOUNDARY, 0, 0);
			case RegexNode.NOT_WORD_BOUNDARY:
				program.emit(Regex.NOT_WORD_BOUNDARY, 0, 0);
			case RegexNode.CONCAT:
				for (child in node.children)
					compile(child);
			case RegexNode.GROUP:
				if (node.group >= 0)
					program.emit(Regex.SAVE, node.group * 2, 0);
				compile(node.children[0]);
				if (node.group >= 0)
					program.emit(Regex.SAVE, node.group * 2 + 1, 0);
			case RegexNode.ALTERNATION:
				var jumps:Array<Int> = [];
				for (index in 0...node.children.length) {
					if (index < node.children.length - 1) {
						var split = program.emit(Regex.SPLIT, 0, 0);
						compile(node.children[index]);
						jumps.push(program.emit(Regex.JUMP, 0, 0));
						program.patch(split, split + 1, program.programLength());
					} else
						compile(node.children[index]);
				}
				for (jump in jumps)
					program.patch(jump, program.programLength(), 0);
			case RegexNode.LOOKAHEAD, RegexNode.NEGATIVE_LOOKAHEAD:
				// The assertion's body follows it and ends in MATCH; success resumes after that.
				var assertion = program.emit(node.kind == RegexNode.LOOKAHEAD ? Regex.LOOKAHEAD : Regex.NEGATIVE_LOOKAHEAD, 0, 0);
				compile(node.children[0]);
				program.emit(Regex.MATCH, 0, 0);
				program.patch(assertion, program.programLength(), 0);
			case RegexNode.REPEAT:
				compileRepeat(node);
			case kind:
				throw 'Invalid regular-expression node $kind';
		}
	}

	function compileRepeat(node:RegexNode):Void {
		var child = node.children[0];
		for (index in 0...node.minimum)
			compile(child);
		if (node.maximum < 0) {
			// loop: SPLIT body, exit; body: MARK; child; PROGRESS; JUMP loop
			var slot = nextSlot++;
			var loop = program.emit(Regex.SPLIT, 0, 0);
			program.emit(Regex.MARK, slot, 0);
			compile(child);
			program.emit(Regex.PROGRESS, slot, 0);
			program.emit(Regex.JUMP, loop, 0);
			var exit = program.programLength();
			program.patch(loop, node.greedy ? loop + 1 : exit, node.greedy ? exit : loop + 1);
			return;
		}
		var splits:Array<Int> = [];
		for (index in node.minimum...node.maximum) {
			splits.push(program.emit(Regex.SPLIT, 0, 0));
			compile(child);
		}
		var exit = program.programLength();
		for (split in splits)
			program.patch(split, node.greedy ? split + 1 : exit, node.greedy ? exit : split + 1);
	}
}
#end

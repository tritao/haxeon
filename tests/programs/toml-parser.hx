import toml.TomlDateTime;
import toml.TomlError;
import toml.TomlParser;
import toml.TomlPrinter;

// TOML 1.0 (lib/haxeon-io/toml): every value type, table forms and their redefinition rules, errors with line and column, and printing back.
function main():Int {
	var document:Dynamic = TomlParser.parse([
		"# A comment",
		"title = \"TOML \\\"example\\\" \\u00e9\\U0001F642\" # trailing comment",
		"literal = 'C:\\Users\\nodejs'",
		"bare_key-1 = 1",
		"\"quoted key\" = true",
		"site.\"google.com\" = true",
		"multi = \"\"\"",
		"Roses are red",
		"Violets are \\",
		"    blue\"\"\"",
		"raw = '''",
		"first line",
		"  'quoted' ''''",
		"quotes = \"\"\"Here are two quotation marks: \"\". Simple enough.\"\"\"\"",
		"",
		"[numbers]",
		"positive = +99",
		"negative = -17",
		"zero = 0",
		"thousands = 1_000",
		"big = 9_223_372_036_854_775_807",
		"hex = 0xDEAD_beef",
		"octal = 0o755",
		"binary = 0b1101",
		"float = -3.25e-2",
		"exponent = 5E+22",
		"infinity = -inf",
		"not_a_number = nan",
		"",
		"[dates]",
		"offset = 1979-05-27T07:32:00Z",
		"spaced = 1979-05-27 00:32:00.999999-07:00",
		"local = 1979-05-27T07:32:00",
		"day = 2024-02-29",
		"time = 07:32:00",
		"",
		"[arrays]",
		"integers = [ 1, 2, 3 ]",
		"mixed = [ \"a\", 1, [2, 3], { x = 1 } ]",
		"multiline = [",
		"  1, # one",
		"  2,",
		"]",
		"empty = []",
		"",
		"[dependencies]",
		"local = { path = \"../local\" }",
		"git = { git = \"https://example.org/a.git\", rev = \"v1\" }",
		"",
		"[a.b.c]",
		"d = 1",
		"[a]",
		"e = 2",
		"",
		"[fruit]",
		"apple.color = \"red\"",
		"apple.taste.sweet = true",
		"[fruit.apple.texture]",
		"smooth = true",
		"",
		"[[products]]",
		"name = \"Hammer\"",
		"[[products]]",
		"[[products]]",
		"name = \"Nail\"",
		"[products.size]",
		"length = 2",
	].join("\r\n"));

	if (document.title != "TOML \"example\" é🙂")
		return 1;
	if (document.literal != "C:\\Users\\nodejs")
		return 2;
	if (Reflect.field(document, "bare_key-1") != 1 || Reflect.field(document, "quoted key") != true)
		return 3;
	if (Reflect.field(document.site, "google.com") != true)
		return 4;
	if (document.multi != "Roses are red\r\nViolets are blue")
		return 5;
	if (document.raw != "first line\r\n  'quoted' '")
		return 6;
	if (document.quotes != "Here are two quotation marks: \"\". Simple enough.\"")
		return 7;
	var numbers:Dynamic = document.numbers;
	if (numbers.positive != 99 || numbers.negative != -17 || numbers.zero != 0 || numbers.thousands != 1000)
		return 8;
	if (!(numbers.big > 9.2e18) || numbers.hex != 3735928559.0 || numbers.octal != 493 || numbers.binary != 13)
		return 9;
	if (numbers.float != -0.0325 || numbers.exponent != 5e22 || numbers.infinity != Math.NEGATIVE_INFINITY
		|| !Math.isNaN(numbers.not_a_number))
		return 10;
	var dates:Dynamic = document.dates;
	if (!dateIs(dates.offset, OffsetDateTime, "1979-05-27T07:32:00Z")
		|| !dateIs(dates.spaced, OffsetDateTime, "1979-05-27 00:32:00.999999-07:00")
		|| !dateIs(dates.local, LocalDateTime, "1979-05-27T07:32:00") || !dateIs(dates.day, LocalDate, "2024-02-29")
		|| !dateIs(dates.time, LocalTime, "07:32:00"))
		return 11;
	var arrays:Dynamic = document.arrays, mixed:Array<Dynamic> = arrays.mixed;
	if ((arrays.integers:Array<Dynamic>).length != 3 || mixed.length != 4 || mixed[0] != "a"
		|| (mixed[2]:Array<Dynamic>)[1] != 3 || mixed[3].x != 1)
		return 12;
	if ((arrays.multiline:Array<Dynamic>).length != 2 || (arrays.empty:Array<Dynamic>).length != 0)
		return 13;
	if (document.dependencies.local.path != "../local" || document.dependencies.git.rev != "v1")
		return 14;
	if (document.a.b.c.d != 1 || document.a.e != 2)
		return 15;
	if (document.fruit.apple.color != "red" || document.fruit.apple.taste.sweet != true
		|| document.fruit.apple.texture.smooth != true)
		return 16;
	var products:Array<Dynamic> = document.products;
	if (products.length != 3 || products[0].name != "Hammer" || Reflect.fields(products[1]).length != 0
		|| products[2].size.length != 2)
		return 17;

	// Invalid documents: the message's position, then a fragment of its reason.
	var invalid:Array<Array<String>> = [
		["a = 1\na = 2", "2:1", "defined twice"],
		["[t]\n[t]", "2:2", "already defined"],
		["a.b = 1\n[a.b]", "2:2", "already defined"],
		["[x.y]\nz = 1\n[x]\ny.z = 2", "4:1", "cannot be extended"],
		["[a]\nb = 1\n[a.b]", "3:2", "already defined"],
		["t = {a = 1}\n[t]", "2:2", "already defined"],
		["t = {a = 1}\nt.b = 2", "2:1", "cannot be extended"],
		["a = [1]\n[[a]]", "2:3", "not as an array of tables"],
		["key = \"unterminated", "1:7", "unterminated"],
		["key = \"line\nbreak\"", "1:12", "cannot span lines"],
		["key = \"\\x\"", "1:8", "unknown escape"],
		["key = \"\\uD800\"", "1:8", "not a Unicode scalar"],
		["key = 01", "1:7", "leading zeros"],
		["key = 1__0", "1:7", "invalid value"],
		["key = 1.", "1:7", "fraction"],
		["key = 9223372036854775808", "1:7", "64 bits"],
		["key = 0x8000000000000000", "1:7", "64 bits"],
		["key = 2023-02-29", "1:7", "invalid date"],
		["key = 25:00:00", "1:7", "invalid time"],
		["key = { a = 1, }", "1:16", "expected a key"],
		["key = { a = 1\n}", "1:14", "expected , or }"],
		["key = [1 2]", "1:10", "expected , or ]"],
		["key = tru", "1:7", "invalid value"],
		["key = 1 2", "1:9", "end of the line"],
		["key =", "1:6", "end of the document"],
		["= 1", "1:1", "expected a key"],
		["[a]]", "1:4", "end of the line"],
		["[[a]", "1:5", "expected ]]"],
		["é = 1", "1:1", "expected a key"],
		["s = 'é' x", "1:9", "end of the line"],
		["a = 1\rb = 2", "1:6", "carriage return"],
		["k = \"\"\"a\"\"\"\"\"\"", "1:9", "too many quotes"],
	];
	for (index in 0...invalid.length) {
		var item = invalid[index], position = null, message = null;
		try {
			TomlParser.parse(item[0]);
		} catch (error:TomlError) {
			position = '${error.line}:${error.column}';
			message = error.reason;
		}
		if (position != item[1] || message == null || message.indexOf(item[2]) < 0)
			return 100 + index;
	}

	// Printing: the document reads back to the same values, sections and inline tables where expected.
	var printed = TomlPrinter.print(TomlParser.parse([
		"version = 1",
		"name = \"tab\\there \\\"quoted\\\" é\"",
		"list = [\"a\", \"b\"]",
		"ratio = 0.5",
		"whole = 2.0",
		"large = 5_000_000_000",
		"when = 2024-01-02",
		"[dependencies]",
		"b = { git = \"g\", rev = \"r\" }",
		"\"needs quotes\" = { path = \"../x\" }",
		"[native.cmake]",
		"source = \"cmake\"",
	].join("\n")), [
		"version",
		"name"
	]);
	var expected = [
		"version = 1",
		"name = \"tab\\there \\\"quoted\\\" é\"",
		"large = 5000000000",
		"list = [\"a\", \"b\"]",
		"ratio = 0.5",
		"when = 2024-01-02",
		"whole = " + (Std.isOfType((2.0:Dynamic), Int) ? "2" : "2.0"),
		"",
		"[dependencies]",
		"b = { git = \"g\", rev = \"r\" }",
		"\"needs quotes\" = { path = \"../x\" }",
		"",
		"[native]",
		"cmake = { source = \"cmake\" }",
		""
	].join("\n");
	if (printed != expected)
		return 30;
	var reread:Dynamic = TomlParser.parse(printed);
	if (reread.name != "tab\there \"quoted\" é" || reread.large != 5000000000.0
		|| Reflect.field(reread.dependencies, "needs quotes").path != "../x" || reread.native.cmake.source != "cmake")
		return 31;
	return 42;
}

function dateIs(value:Dynamic, kind:TomlDateTimeKind, text:String):Bool {
	if (!Std.isOfType(value, TomlDateTime))
		return false;
	var date:TomlDateTime = value;
	return date.kind == kind && date.text == text;
}

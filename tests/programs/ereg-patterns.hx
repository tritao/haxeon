// EReg over the pattern forms applications use. HashLink runs PCRE2 and Wasm runs the Haxe
// engine in runtime.Regex, so the parity suite holds both to the same answers.
function anchoredClasses():Int {
	var hash = ~/^[0-9a-f]{64}$/;
	var digest = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08";
	if (!hash.match(digest) || hash.match(digest + "0") || hash.match(digest.substr(1)) || hash.match("Z" + digest.substr(1)))
		return 1;
	var ifc = ~/^Ifc[A-Za-z0-9]+$/;
	if (!ifc.match("IfcWallStandardCase") || ifc.match("IfcWall_Case") || ifc.match("Ifc") || ifc.match("xIfcWall"))
		return 1;
	var guid = ~/^[0-3][0-9A-Za-z_$]{21}$/;
	if (!guid.match("2O2Fr$t4X7Zf8NOew3FLOH") || guid.match("4O2Fr$t4X7Zf8NOew3FLOH") || guid.match("2O2Fr$t4X7Zf8NOew3FLO"))
		return 1;
	var drive = ~/^[A-Za-z]:/;
	if (!drive.match("C:\\models") || drive.match("/home/c:") || drive.match("1:"))
		return 1;
	var negated = ~/[^a-z ]+/;
	if (!negated.match("some words 42 here") || negated.matched(0) != "42")
		return 1;
	return 0;
}

function captures():Int {
	var stamp = ~/^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})$/;
	if (!stamp.match("2026-09-30T14:05:59") || stamp.matched(1) != "2026" || stamp.matched(2) != "09" || stamp.matched(3) != "30"
		|| stamp.matched(4) != "14" || stamp.matched(5) != "05" || stamp.matched(6) != "59")
		return 2;
	if (stamp.match("2026-09-30T14:05:5") || stamp.match("2026-9-30T14:05:59"))
		return 2;
	var optional = ~/(a)|(b)/;
	if (!optional.match("xb") || optional.matched(2) != "b" || optional.matchedPos().pos != 1 || optional.matchedLeft() != "x")
		return 2;
	var nonCapturing = ~/(?:ab)+(c)/;
	if (!nonCapturing.match("zababcd") || nonCapturing.matched(0) != "ababc" || nonCapturing.matched(1) != "c" || nonCapturing.matchedRight() != "d")
		return 2;
	var position = nonCapturing.matchedPos();
	return position.pos == 1 && position.len == 5 ? 0 : 2;
}

function quantifiers():Int {
	var greedy = ~/<.+>/, lazy = ~/<.+?>/;
	if (!greedy.match("<a><b>") || greedy.matched(0) != "<a><b>" || !lazy.match("<a><b>") || lazy.matched(0) != "<a>")
		return 4;
	var counted = ~/^x{2,3}y{2,}z?$/;
	if (!counted.match("xxyy")
		|| !counted.match("xxxyyyyz")
		|| counted.match("xyy")
		|| counted.match("xxxxyy")
		|| counted.match("xxy"))
		return 4;
	var shorthand = ~/\w+\s*=\s*\S+/;
	if (!shorthand.match("  name =  value;") || shorthand.matched(0) != "name =  value;")
		return 4;
	var alternatives = ~/^(cat|category|dog)s?$/;
	if (!alternatives.match("categorys")
		|| alternatives.matched(1) != "category"
		|| !alternatives.match("dogs")
		|| alternatives.match("cow"))
		return 4;
	var literalBrace = ~/a{,2}/;
	if (!literalBrace.match("xa{,2}") || literalBrace.matched(0) != "a{,2}")
		return 4;
	var escapes = ~/\$\d+\.\d{2}/;
	return escapes.match("cost: $12.50!") && escapes.matched(0) == "$12.50" ? 0 : 4;
}

function flags():Int {
	var insensitive = ~/^ifc[a-z]+$/i;
	if (!insensitive.match("IFCWALL") || !insensitive.match("IfcSlab") || insensitive.match("IFC_WALL"))
		return 8;
	var global = ~/\s+/g;
	if (global.replace("a  b \t c", " ") != "a b c")
		return 8;
	var parts = global.split("one two  three");
	if (parts.length != 3 || parts[0] != "one" || parts[2] != "three")
		return 8;
	var single = ~/,/;
	if (single.replace("a,b,c", ";") != "a;b,c" || single.split("a,b,c").length != 2)
		return 8;
	var swap = ~/(\w+)@(\w+)/g;
	if (swap.replace("x@y and p@q", "$2 at $1") != "y at x and q at p")
		return 8;
	var lines = ~/^\w+$/m;
	if (!lines.match("first line\nsecond\nthird line") || lines.matched(0) != "second")
		return 8;
	var mapped = ~/\d+/g.map("a1b22c333", expression -> "<" + expression.matched(0).length + ">");
	return mapped == "a<1>b<2>c<3>" ? 0 : 8;
}

function main():Int {
	var failures = anchoredClasses() | captures() | quantifiers() | flags();
	return failures == 0 ? 42 : failures;
}

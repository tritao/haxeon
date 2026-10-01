// Wasm-only behaviour of the runtime.Regex engine: syntax it refuses at construction (PCRE2 on
// HashLink accepts some of it), UTF-8 subjects, and loops whose body can match nothing.
function refuses(pattern:String):Bool {
	try {
		new EReg(pattern, "");
		return false;
	} catch (error:String) {
		return StringTools.startsWith(error, "Invalid regular expression");
	}
}

function main():Int {
	var refused = [
		"(",
		"a)",
		"[a-",
		"(a)\\1",
		"(?<=a)b",
		"(?<name>a)",
		"\\p{L}",
		"a++",
		"*a",
		"[[:alpha:]]",
		"[z-a]",
		"a{3,2}"
	];
	for (pattern in refused)
		if (!refuses(pattern))
			return 1;
	var badOption = false;
	try
		new EReg("a", "x")
	catch (error:String)
		badOption = true;
	if (!badOption)
		return 2;
	var lookahead = ~/(?=.)/g;
	if (lookahead.replace("ab", "_") != "_a_b" || !~/^a(?!b)/.match("ac") || ~/^a(?!b)/.match("ab"))
		return 3;
	var empty = ~/(a*)*b/;
	if (!empty.match("aaab") || empty.matched(0) != "aaab" || empty.match("aaaa"))
		return 4;
	// `.` and classes take whole code points; positions stay UTF-16 offsets like String.
	var accented = ~/^caf.$/;
	if (!accented.match("café") || !~/[é]/.match("é") || ~/^[^é]$/.match("é"))
		return 5;
	var word = ~/é+/;
	if (!word.match("xééy") || word.matched(0) != "éé" || word.matchedPos().pos != 1)
		return 6;
	if (~/x*/g.replace("ée", "-") != "-é-e-")
		return 7;
	var emoji = ~/🙂+/;
	if (!~/^.$/.match("🙂") || !emoji.match("a🙂🙂b") || emoji.matchedPos().pos != 1 || emoji.matchedPos().len != 4 || emoji.matched(0) != "🙂🙂"
		|| ~/x*/g.replace("🙂e", "-") != "-🙂-e-")
		return 8;
	var long = new StringBuf();
	for (index in 0...20000)
		long.add("ab");
	if (!~/^(ab)+$/.match(long.toString()) || !~/^.*$/.match(long.toString()))
		return 8;
	var dollar = ~/end$/;
	if (!dollar.match("the end\n") || dollar.match("the end\n\n"))
		return 9;
	return 42;
}

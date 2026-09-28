// Xml reports malformed documents as XmlParserException with positions, and edits trees through the node API.
function main():Int {
	var unclosed = parseError("<robot>\n  <link name=\"base\">\n</robot>");
	if (unclosed == null || unclosed.message != "Expected </link>" || unclosed.lineNumber != 3)
		return 1;
	var open = parseError("<robot><link/>");
	if (open == null || open.message != "Unclosed node <robot>")
		return 2;
	if (parseError("</robot>") == null || parseError("<robot a=\"1\" a=\"2\"/>") == null || parseError("<robot a=1/>") == null)
		return 3;
	var strict = parseError("<a>&bogus;</a>", true);
	if (strict == null || strict.message != "Undefined entity: bogus")
		return 4;
	if (strict.toString() != "haxe.xml.XmlParserException: Undefined entity: bogus at line 1 char 9")
		return 5;
	// Lenient parsing keeps unknown entities and bare ampersands as text.
	var lenient = Xml.parse("<a>&bogus; & x</a>").firstElement().firstChild();
	if (lenient.nodeValue != "&bogus; & x")
		return 6;
	var doc = Xml.parse("<!DOCTYPE robot><robot><a/><b/></robot>");
	if (doc.firstChild().nodeType != Xml.DocType || doc.firstChild().nodeValue != "robot")
		return 7;
	var robot = doc.firstElement();
	robot.set("name", "r2");
	robot.set("version", "1");
	var names:Array<String> = [];
	for (name in robot.attributes())
		names.push(name);
	names.sort(Reflect.compare);
	if (names.join(",") != "name,version")
		return 8;
	robot.remove("version");
	if (robot.exists("version"))
		return 9;
	var c = Xml.createElement("c");
	robot.insertChild(c, 0);
	var b = robot.elementsNamed("b").next();
	if (!robot.removeChild(b) || b.parent != null || c.parent != robot)
		return 10;
	robot.firstElement().nodeName = "first";
	robot.addChild(Xml.createComment(" end "));
	if (doc.toString() != '<!DOCTYPE robot><robot name="r2"><first/><a/><!-- end --></robot>')
		return 11;
	// Accessing a node value on an element, or attributes on text, throws.
	var threw = false;
	try {
		robot.nodeValue;
	} catch (e:String) {
		threw = e == "Bad node type, unexpected Element";
	}
	if (!threw)
		return 12;
	threw = false;
	try {
		Xml.createPCData("t").get("x");
	} catch (e:String) {
		threw = e == "Bad node type, expected Element but found PCData";
	}
	if (!threw)
		return 13;
	return 42;
}

function parseError(text:String, strict:Bool = false):Null<haxe.xml.Parser.XmlParserException> {
	try {
		Xml.parse(text);
		if (strict)
			haxe.xml.Parser.parse(text, true);
	} catch (e:haxe.xml.Parser.XmlParserException) {
		return e;
	}
	return null;
}

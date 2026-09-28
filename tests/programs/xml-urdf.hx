// Xml parses a URDF-like robot description, exposes elements and attributes, and round-trips through haxe.xml.Printer.
function main():Int {
	var source = '<?xml version="1.0" encoding="utf-8"?>\n'
		+ '<!-- two-link arm -->\n'
		+ '<robot name="arm&amp;co">\n'
		+ '  <link name=\'base_link\'>\n'
		+ '    <inertial>\n'
		+ '      <origin xyz="0 0 0.1" rpy="0 0 0"/>\n'
		+ '      <mass value="1.5"/>\n'
		+ '    </inertial>\n'
		+ '  </link>\n'
		+ '  <link name="tool"/>\n'
		+ '  <joint name="j1" type="revolute">\n'
		+ '    <parent link="base_link"/>\n'
		+ '    <child link="tool"/>\n'
		+ '    <limit lower="-1.57" upper="1.57"/>\n'
		+ '    <note>a &lt; b &gt; c &quot;q&quot; &apos;s&apos; &#65;&#x42; &#233;&#x1F600;</note>\n'
		+ '    <script><![CDATA[x < y && z]]></script>\n'
		+ '  </joint>\n'
		+ '</robot>\n';
	var doc = Xml.parse(source);
	var robot = doc.firstElement();
	if (robot == null || robot.nodeName != "robot")
		return 1;
	if (robot.get("name") != "arm&co")
		return 2;
	var names:Array<String> = [];
	for (link in robot.elementsNamed("link"))
		names.push(link.get("name"));
	if (names.join(",") != "base_link,tool")
		return 3;
	var tags:Array<String> = [];
	for (e in robot.elements())
		tags.push(e.nodeName);
	if (tags.join(",") != "link,link,joint")
		return 4;
	var origin = robot.firstElement().firstElement().firstElement();
	if (origin.nodeName != "origin" || origin.get("xyz") != "0 0 0.1" || origin.get("rpy") != "0 0 0")
		return 5;
	if (!origin.exists("xyz") || origin.exists("missing") || origin.get("missing") != null)
		return 6;
	origin.set("xyz", "1 2 3");
	if (origin.get("xyz") != "1 2 3")
		return 7;
	var joint = robot.elementsNamed("joint").next();
	var note = joint.elementsNamed("note").next();
	if (note.firstChild().nodeValue != "a < b > c \"q\" 's' AB é😀")
		return 8;
	var script = joint.elementsNamed("script").next().firstChild();
	if (script.nodeType != Xml.CData || script.nodeValue != "x < y && z")
		return 9;
	// Document-level nodes: declaration, whitespace, comment, whitespace, robot, trailing whitespace.
	var kinds:Array<String> = [];
	for (child in doc)
		kinds.push(kindName(child.nodeType));
	if (kinds.join(",") != "ProcessingInstruction,PCData,Comment,PCData,Element,PCData")
		return 10;
	var comment = [for (child in doc) if (child.nodeType == Xml.Comment) child][0];
	if (comment.nodeValue != " two-link arm ")
		return 11;
	// Whitespace text nodes are preserved between elements.
	var link = robot.firstElement();
	if (link.firstChild().nodeType != Xml.PCData || StringTools.trim(link.firstChild().nodeValue) != "")
		return 12;
	// Malformed input throws.
	if (!throws("<robot><link></robot>"))
		return 13;
	if (!throws("<robot><link name=\"a\"/>"))
		return 14;
	if (!throws("<robot name=\"a></robot>"))
		return 15;
	// Printer round-trip.
	var printed = doc.toString();
	var reparsed = Xml.parse(printed);
	if (reparsed.toString() != printed)
		return 16;
	if (reparsed.firstElement().get("name") != "arm&co")
		return 17;
	if (Xml.parse('<a x="1">t&amp;<b/></a>').toString() != '<a x="1">t&amp;<b/></a>')
		return 18;
	var built = Xml.createElement("visual");
	built.set("name", "v<1>");
	built.addChild(Xml.createPCData("m & n"));
	if (haxe.xml.Printer.print(built) != '<visual name="v&lt;1&gt;">m &amp; n</visual>')
		return 19;
	var pretty = haxe.xml.Printer.print(Xml.parse("<a><b/></a>"), true);
	if (pretty != "<a>\n\t<b/>\n</a>\n")
		return 20;
	return 42;
}

function throws(text:String):Bool {
	try {
		Xml.parse(text);
	} catch (e:haxe.xml.Parser.XmlParserException) {
		return e.message.length > 0;
	}
	return false;
}

function kindName(kind:Xml.XmlType):String {
	return switch kind {
		case Element: "Element";
		case PCData: "PCData";
		case CData: "CData";
		case Comment: "Comment";
		case DocType: "DocType";
		case ProcessingInstruction: "ProcessingInstruction";
		case Document: "Document";
		default: "?";
	};
}

typedef SyntaxInfo = {
	final nodeKinds:Map<String, FormatNodeKind>;
	final matching:Map<Int, Int>;
	final pairs:Array<{a:Int, b:Map<String, Int>}>;
}

class A {
	final omitted:Map<String, Bool> = [];
}

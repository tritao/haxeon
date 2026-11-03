class NullVirtualProbe {
	public static var entered:Int = 0;
}

class NullVirtualBase {
	public function new() {}
	public function get():Int { NullVirtualProbe.entered++; return 7; }
}

class NullVirtualChild extends NullVirtualBase {
	public function new() { super(); }
	override public function get():Int return 8;
}

function missingVirtual(flag:Bool):NullVirtualBase {
	if (flag) return new NullVirtualChild();
	var value:Dynamic = null;
	return cast value;
}

function main():Int {
	try return missingVirtual(false).get();
	catch (error:Dynamic) return NullVirtualProbe.entered == 0 ? 42 : 1;
}

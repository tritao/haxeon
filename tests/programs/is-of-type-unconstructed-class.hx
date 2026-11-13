class NeverConstructed {
	public function new() {}
}

// A class that is only named by a type test: its type value must keep it in the module written for the build.
function main():Int {
	var value:Dynamic = 1;
	return Std.isOfType(value, NeverConstructed) ? 0 : 42;
}

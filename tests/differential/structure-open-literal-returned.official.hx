// A literal returned from a function is closed when the function's body is typed: a caller that wants an optional field it
// lacks is an error, in both compilers (Haxeon asks to annotate the function's result).
class Main {
	static function make() {
		var made = {name: "x"};
		return made;
	}

	static function main():Void {
		var c:{name:String, ?debug:Bool} = make();
		Sys.println(c.name);
	}
}

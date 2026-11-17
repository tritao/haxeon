// An instance field's initializer cannot read another member: Haxe reports "Cannot access this or other member field in variable
// initialization" (tests/compiler/MemberInitializerAccessMain.hx checks the message and position).
class Main {
	var width = 2;
	var area = width * width;

	function new() {}

	static function main() {
		Sys.println(new Main().area);
	}
}

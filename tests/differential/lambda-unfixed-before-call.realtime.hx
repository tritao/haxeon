// A local's empty array passed to a generic function before anything fixes its element type: Haxe fixes it by the later push.
// Haxeon types a generic call's specialization when it types the call, so it cannot follow the type variable yet.
class Main {
	static function main():Void {
		var values = [];
		Sys.println(Lambda.count(values));
		values.push(1);
		Sys.println(Lambda.count(values));
	}
}

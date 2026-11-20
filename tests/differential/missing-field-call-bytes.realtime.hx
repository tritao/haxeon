// A method Bytes does not have is missing from haxe.io.Bytes, as Haxe reports it, not a call on a non-object.
class Main {
	static function main() {
		var bytes = haxe.io.Bytes.alloc(4);
		bytes.reverse();
	}
}

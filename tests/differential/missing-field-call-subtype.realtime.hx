// A missing static of a sub-type of another module (Lib.Helper) is missing from that type, as Haxe reports it, not an unknown
// static field of the module's main type.
class Main {
	static function main() {
		trace(Lib.Helper.yes());
		Lib.Helper.no();
	}
}

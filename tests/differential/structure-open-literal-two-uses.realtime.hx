// An open literal meeting two structures with different optional fields gains both, whatever their order, and a narrower use
// does not close it (docs/design/STRUCTURE_VALUES.md). A known divergence: once a literal has met one structure its record is
// that structure's, and standing for a structure with fewer fields waits for structure views (step 2.6, slice 4);
// tests/differential/run.sh fails once Haxeon compiles it.
class Main {
	static function useA(value:{name:String, ?x:Int}):String
		return value.name + ":" + value.x;

	static function useB(value:{name:String, ?y:String}):String
		return value.name + ":" + value.y;

	static function useN(value:{name:String}):String
		return value.name;

	static function main():Void {
		var c = {name: "c"};
		Sys.println(useA(c));
		Sys.println(useB(c));
		var e = {name: "e"};
		Sys.println(useN(e));
		Sys.println(useA(e));
	}
}

// A declared structure is closed: unlike a literal's, it never gains an optional field, in both compilers.
class Main {
	static function main():Void {
		var b:{b:Int} = {b: 1};
		var c:{b:Int, ?a:Int} = b;
		Sys.println(c.b);
	}
}

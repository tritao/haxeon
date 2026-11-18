// The first use that adds an optional field to an open literal fixes the field's type: a later use that wants it with another
// type is an error, in both compilers.
class Main {
	static function main():Void {
		var c = {n: 1};
		var d:{n:Int, ?x:Int} = c;
		var e:{n:Int, ?x:String} = c;
		Sys.println(d.n + e.n);
	}
}

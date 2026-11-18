// An open literal gains only optional fields: a structure with a required field it lacks is an error, in both compilers.
class Main {
	static function main():Void {
		var c = {n: 1};
		var d:{n:Int, m:Int} = c;
		Sys.println(d.n);
	}
}

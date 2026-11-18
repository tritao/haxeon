// A class named as a value is no Int: `Main.twice()` names a static of Main, which it lacks, not the extension.
using Main.Tools;

class Tools {
	public static function twice(x:Int):Int
		return x * 2;
}

class Main {
	static function main():Void {
		Sys.println(Main.twice());
	}
}

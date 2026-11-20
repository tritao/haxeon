// Type.createEnumIndex, Type.createEnum and Type.allEnums on an enum named at the call: the values they make, and what
// they throw for an index out of range, an unknown name, a constructor with arguments given none and a wrong count.
enum Color {
	Red;
	Green;
	Rgb(r:Int, g:Int, b:Float);
	Blue;
}

enum Shade {
	Light;
	Dark(level:Int);
}

enum Opt<T> {
	None;
	Some(v:T);
}

class Main {
	static function attempt(label:String, f:() -> Dynamic) {
		try {
			Sys.println(label + ": " + Std.string(f()));
		} catch (e:Dynamic) {
			Sys.println(label + " threw " + Std.string(e));
		}
	}

	static function main() {
		var i = 1;
		var c:Color = Type.createEnumIndex(Color, i);
		Sys.println(c);
		Sys.println(Type.createEnumIndex(Color, 3));
		Sys.println(Type.createEnumIndex(Color, 2, [1, 2, 3.5]));
		Sys.println(Type.createEnum(Color, "Blue"));
		Sys.println(Type.createEnum(Color, "Rgb", [4, 5, 6]));
		Sys.println(Type.allEnums(Color));
		Sys.println(Type.allEnums(Shade));
		Sys.println(Type.createEnumIndex(Shade, 1, [7]));
		var o:Opt<Int> = Type.createEnumIndex(Opt, 1, [9]);
		Sys.println(o);
		Sys.println(Type.createEnumIndex(Opt, 0));
		attempt("negative", () -> Type.createEnumIndex(Color, -1));
		attempt("past", () -> Type.createEnumIndex(Color, 4));
		attempt("needs", () -> Type.createEnumIndex(Color, 2));
		attempt("empty", () -> Type.createEnumIndex(Color, 2, []));
		attempt("count", () -> Type.createEnumIndex(Color, 2, [1]));
		attempt("extra", () -> Type.createEnumIndex(Color, 0, [1]));
		attempt("unknown", () -> Type.createEnum(Color, "Purple"));
		attempt("shade", () -> Type.createEnumIndex(Shade, 1));
		attempt("shadeunknown", () -> Type.createEnum(Shade, "Mid"));
		attempt("nullparams", () -> Type.createEnumIndex(Color, 0, null));
		for (k in 0...4)
			attempt("loop" + k, () -> Type.createEnumIndex(Color, k));
	}
}

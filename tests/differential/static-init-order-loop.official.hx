// Loops in the static initialization order, which Haxe warns about ("maybe loop in static generation of A", at the class
// declaration) and keeps in the order its walk found: a read of a static set later reads its default value. A class reading its
// own statics is no loop. Every looping class warns once here; Haxe prints the warning each time its walk reaches the class.
class A {
	public static var a:Int = B.b + 1;
	public static var a2:Int = B.c + 1;

	public static function f():Int
		return 5;
}

class B {
	public static var b:Int = A.f();
	public static var c:Int = A.f() + A.a;
	public static var self:Int = B.b * 2;
}

class C {
	public static var c:Int = D.d + 1;
}

class D {
	public static var d:Int = E.e + 1;
}

class E {
	public static var e:Int = C.c + 1;
}

class Main {
	static function main() {
		Sys.println(A.a + " " + A.a2);
		Sys.println(B.b + " " + B.c + " " + B.self);
		Sys.println(C.c + " " + D.d + " " + E.e);
	}
}

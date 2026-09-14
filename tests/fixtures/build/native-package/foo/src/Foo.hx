package foo;

@:hlNative("foo", "foo_answer")
extern function nativeAnswer():Int;

class Foo {
	public static function answer():Int
		return nativeAnswer();
}

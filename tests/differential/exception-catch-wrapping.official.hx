// What a catch clause tests on HashLink, where `throw` throws a value as it is: `catch (e:haxe.Exception)` wraps a value that is
// no exception in a haxe.ValueException, a catch of another type tests the value a ValueException wraps, and
// `catch (e:Dynamic)` binds the thrown value itself. Rethrowing a caught exception throws the wrapper.
class MyError extends haxe.Exception {}

class Plain {
	public function new() {}

	public function toString()
		return "Plain";
}

class Main {
	static function thrower(kind:Int):Void {
		switch kind {
			case 0: throw "x";
			case 1: throw 42;
			case 2: throw new MyError("mine");
			case 3: throw new haxe.Exception("plain");
			case 4: throw {
					code:7
				};
			case _: throw new haxe.ValueException("wrapped", null, null);
		}
	}

	static function rethrowAsException(v:Dynamic):Void {
		try {
			throw v;
		} catch (e:haxe.Exception) {
			throw e;
		}
	}

	static function deep(n:Int):Void {
		if (n == 0) throw "bottom";
		deep(n - 1);
	}

	static function main() {
		for (kind in 0...6) {
			try {
				thrower(kind);
			} catch (e:haxe.Exception) {
				Sys.println('Exception: message=${e.message} string=${Std.string(e)} isValue=${Std.isOfType(e, haxe.ValueException)} isMine=${Std.isOfType(e, MyError)}');
				if (Std.isOfType(e, haxe.ValueException)) {
					var v:haxe.ValueException = cast e;
					Sys.println('  value=${Std.string(v.value)}');
				}
				Sys.println('  unwrap=${Std.string(e.details() != null)}');
			}
		}
		for (kind in 0...6) {
			try {
				thrower(kind);
			} catch (e:Dynamic) {
				Sys.println('Dynamic: ${Std.string(e)} isException=${Std.isOfType(e, haxe.Exception)} isString=${Std.isOfType(e, String)}');
			}
		}
		for (kind in 0...6) {
			try {
				try {
					thrower(kind);
				} catch (e:String) {
					Sys.println('String: $e');
				} catch (e:Int) {
					Sys.println('Int: $e');
				}
			} catch (e:Dynamic) {
				Sys.println('outer: ${Std.string(e)}');
			}
		}
		// rethrow a caught exception
		try {
			try {
				thrower(0);
			} catch (e:haxe.Exception) {
				throw e;
			}
		} catch (e:String) {
			Sys.println('rethrown as String: $e');
		} catch (e:Dynamic) {
			Sys.println('rethrown other: ${Std.string(e)}');
		}
		try {
			try {
				thrower(1);
			} catch (e:haxe.Exception) {
				throw e;
			}
		} catch (e:haxe.Exception) {
			Sys.println('rethrown as Exception: ${e.message} ${Std.isOfType(e, haxe.ValueException)}');
		}
		try {
			try {
				thrower(0);
			} catch (e:Dynamic) {
				throw e;
			}
		} catch (e:haxe.ValueException) {
			Sys.println('ValueException catch: ${e.message} ${Std.string(e.value)}');
		}
		var ve = new haxe.ValueException(5);
		Sys.println('ve: ${ve.message} ${Std.string(ve.value)}');
		try {
			thrower(0);
		} catch (e:haxe.Exception) {
			Sys.println('stack nonempty: ${e.stack.length > 0}');
			Sys.println('previous null: ${e.previous == null} native: ${Std.string(e.native)}');
		}

		for (v in ([("s":Dynamic), 1, new Plain(), new MyError("m"), new haxe.ValueException("v")]:Array<Dynamic>)) {
			try {
				rethrowAsException(v);
			} catch (e:Dynamic) {
				Sys.println('rethrown raw: ${Std.string(e)} isException=${Std.isOfType(e, haxe.Exception)} same=${e == v}');
			}
		}
		try {
			throw new Plain();
		} catch (e:Plain) {
			Sys.println('Plain caught ${Std.string(e)}');
		}
		try {
			throw new Plain();
		} catch (e:haxe.ValueException) {
			Sys.println('Plain as ValueException ${e.message} ${Std.isOfType(e.value, Plain)}');
		}
		try {
			throw new haxe.ValueException(new Plain());
		} catch (e:Plain) {
			Sys.println('ValueException(Plain) caught as Plain');
		}
		try {
			throw new haxe.ValueException(3, null, "nat");
		} catch (e:Dynamic) {
			Sys.println('explicit native: ${Std.string(e)}');
		}
		try {
			throw new MyError("x");
		} catch (e:haxe.ValueException) {
			Sys.println('wrong');
		} catch (e:MyError) {
			Sys.println('MyError ${e.message} native same=${e.native == e}');
		}
		try {
			throw "str";
		} catch (e:MyError) {
			Sys.println('wrong');
		} catch (e:haxe.Exception) {
			Sys.println('fallback ${e.message} ${e.native} ${Std.isOfType(e, haxe.ValueException)}');
		}
		var ex:haxe.Exception = null;
		try {
			throw "same";
		} catch (e:haxe.Exception) {
			ex = e;
		}
		Sys.println('toString: ${ex.toString()}');
		try {
			deep(3);
		} catch (e:haxe.Exception) {
			Sys.println('deep: ${e.message} stack nonempty ${e.stack.length > 0}');
		}
		try {
			try {
				throw 5;
			} catch (e:String) {
				Sys.println('wrong');
			}
		} catch (e:Int) {
			Sys.println('outer Int ${e + 1}');
		}
		try {
			var nothing:Dynamic = null;
			throw nothing;
		} catch (e:haxe.Exception) {
			Sys.println('null as Exception: ${e.message} ${Std.isOfType(e, haxe.ValueException)}');
		}
	}
}

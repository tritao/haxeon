package runtime;

/** HashLink's varargs closure preserves omitted optional parameters on a reflected method. */
@:hlNative("std", "make_var_args")
extern function makeStringMethod(callback:Array<Dynamic>->Dynamic):Dynamic;

/** Bound method values for the compiler-owned String representation. */
class StringMethods {
	public static function field(value:String, name:String):Dynamic {
		if (name == "length")
			return value.length;
		switch name {
			case "charAt", "charCodeAt", "indexOf", "lastIndexOf", "split", "substr", "substring", "toLowerCase", "toUpperCase", "toString":
				return makeStringMethod(arguments -> invoke(value, name, arguments));
			default:
				return null;
		}
	}

	static function invoke(value:String, name:String, arguments:Array<Dynamic>):Dynamic {
		var required = name == "toLowerCase" || name == "toUpperCase" || name == "toString" ? 0 : 1;
		if (arguments.length < required)
			throw 'Missing argument to String.$name';
		switch name {
			case "charAt":
				var index:Int = arguments[0];
				return value.charAt(index);
			case "charCodeAt":
				var index:Int = arguments[0];
				return index < 0 || index >= value.length ? null : value.charCodeAt(index);
			case "indexOf":
				var needle:String = arguments[0];
				var start:Int = arguments.length < 2 || arguments[1] == null ? 0 : arguments[1];
				return value.indexOf(needle, start);
			case "lastIndexOf":
				var needle:String = arguments[0];
				if (arguments.length < 2 || arguments[1] == null)
					return value.lastIndexOf(needle);
				var start:Int = arguments[1];
				return value.lastIndexOf(needle, start);
			case "split":
				var separator:String = arguments[0];
				return value.split(separator);
			case "substr":
				var start:Int = arguments[0];
				if (arguments.length < 2 || arguments[1] == null)
					return value.substr(start);
				var length:Int = arguments[1];
				return value.substr(start, length);
			case "substring":
				var start:Int = arguments[0];
				if (arguments.length < 2 || arguments[1] == null)
					return value.substring(start);
				var end:Int = arguments[1];
				return value.substring(start, end);
			case "toLowerCase":
				return value.toLowerCase();
			case "toUpperCase":
				return value.toUpperCase();
			default:
				return value;
		}
	}
}

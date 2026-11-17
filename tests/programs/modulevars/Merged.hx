package modulevars;

// A module-level variable of a module that declares a class of its name joins that class's statics.
var label = "merged";

// Shares its name with the class's static: `Merged.own` is the static, as in Haxe; only the full path names this one.
var own = "module";

class Merged {
	public static var own = "own";
}

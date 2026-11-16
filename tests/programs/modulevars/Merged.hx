package modulevars;

// A module-level variable of a module that declares a class of its name joins that class's statics.
var label = "merged";

class Merged {
	public static var own = "own";
}

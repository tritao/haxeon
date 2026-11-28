package typetests;

// `Lonely` is named only by these type tests: they load its module.
class Probe {
	public static function tests(value:Dynamic):Bool
		return Std.isOfType(value, Lonely);

	public static function downcasts(value:Dynamic):Bool
		return Std.downcast(value, Lonely) != null;
}

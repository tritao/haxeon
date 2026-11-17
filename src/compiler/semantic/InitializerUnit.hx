package compiler.semantic;

/**
 * The name of the unit a field's initializer is typed in: `<Class>.__init.<field>`. Each field initializer is a unit of its own
 * (docs/design/LAZY_DECLARATION_TYPING.md, "Merging the output"): its body context, its output, the names it generates and the
 * query records kept for it all carry this name. An unannotated field's type is its initializer's, typed in this unit, so a
 * record against the unit is a record against that field's type.
 *
 * This is the one place that knows the format: build names with `of` and take them apart with `ownerClass` and `field`. A class
 * name can contain dots; a field name cannot, so the last `.__init.` separates them.
 */
class InitializerUnit {
	static inline final SEPARATOR = ".__init.";

	public static inline function of(className:String, field:String):String
		return className + SEPARATOR + field;

	/** The class whose field initializer `unit` is, or null when `unit` is no initializer unit. */
	public static function ownerClass(unit:String):Null<String> {
		var index = unit.lastIndexOf(SEPARATOR);
		return index <= 0 ? null : unit.substr(0, index);
	}

	/** The declaration `unit` types the initializer of, `<Class>.<field>`, or null when `unit` is no initializer unit. */
	public static function field(unit:String):Null<String> {
		var index = unit.lastIndexOf(SEPARATOR);
		return index <= 0 ? null : unit.substr(0, index) + "." + unit.substr(index + SEPARATOR.length);
	}
}

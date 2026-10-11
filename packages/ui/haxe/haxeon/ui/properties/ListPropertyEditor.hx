package haxeon.ui.properties;

/** Staged list controls share recursive structured-value editing. */
class ListPropertyEditor extends StructuredPropertyEditor {
	public static inline var TYPE = "ui.list";
	public function new(id:String = TYPE, vector:Bool = false) { super(id, vector); }
}

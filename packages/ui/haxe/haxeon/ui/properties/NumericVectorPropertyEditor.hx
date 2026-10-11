package haxeon.ui.properties;

/** Fixed component controls for numeric vectors; dimensions remain schema-owned. */
class NumericVectorPropertyEditor extends ListPropertyEditor {
	public static inline var TYPE = "ui.numeric-vector";
	public function new() { super(TYPE, true); }
}

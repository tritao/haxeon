package haxeon.ui.properties;

/** A staged named-field object editor sharing the list transaction/draft owner. */
class RecordPropertyEditor extends StructuredPropertyEditor {
	public static inline var TYPE = "ui.record";
	public function new() { super(TYPE, false, true); }
}

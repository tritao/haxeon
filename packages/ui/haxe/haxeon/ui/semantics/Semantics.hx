package haxeon.ui.semantics;

import haxeon.ui.widgets.text.Utf8Text;

/** Haxe-owned accessible name, value, role, state, and supported actions. */
class Semantics {
	public final role:AccessibilityRole;
	public var label:Null<String>;
	public var value(get, set):Null<String>;
	var storedValue:Null<String>;
	/** Where a deferred value is read from, and the source's revision when it was set. */
	var valueSource:Null<SemanticsValueSource>;
	var valueRevision:Int;
	public var states:Int;
	public var actions:Int;
	public var numericValue:Float;
	public var numericMinimum:Float;
	public var numericMaximum:Float;
	public var textStart:Int;
	public var documentLength:Int;
	public var selectionStart:Int;
	public var selectionEnd:Int;
	public var setSize:Int;
	public var positionInSet:Int;
	public var rowCount:Int;
	public var columnCount:Int;
	/** Zero-based row index; -1 means unspecified. */
	public var rowIndex:Int;
	/** Zero-based column index; -1 means unspecified. */
	public var columnIndex:Int;
	public var rowSpan:Int;
	public var columnSpan:Int;
	/** One-based hierarchy depth; zero means unspecified. */
	public var hierarchyLevel:Int;
	public var orientation:AccessibilityOrientation;

	public function new(role:AccessibilityRole, ?label:String, ?value:String,
			?knownDocumentLength:Int) {
		this.role = role;
		this.label = label;
		storedValue = value;
		valueSource = null;
		valueRevision = 0;
		states = 0;
		actions = 0;
		numericValue = 0.0;
		numericMinimum = 0.0;
		numericMaximum = 0.0;
		textStart = 0;
		documentLength = knownDocumentLength == null ? Utf8Text.length(value) : knownDocumentLength;
		selectionStart = -1;
		selectionEnd = -1;
		setSize = 0;
		positionInSet = 0;
		rowCount = 0;
		columnCount = 0;
		rowIndex = -1;
		columnIndex = -1;
		rowSpan = 0;
		columnSpan = 0;
		hierarchyLevel = 0;
		orientation = AccessibilityOrientation.Unspecified;
	}

	function set_value(next:Null<String>):Null<String> {
		storedValue = next;
		valueSource = null;
		documentLength = Utf8Text.length(next);
		return next;
	}

	/** Sets an editor value when its code-point length is already cached. */
	public function setValueWithLength(next:Null<String>, length:Int):Void {
		if (length < 0)
			throw "Document length cannot be negative";
		storedValue = next;
		valueSource = null;
		documentLength = length;
	}

	/** Defers assembling an editable document until a consumer reads its value. */
	public function setValueSource(source:SemanticsValueSource, length:Int):Void {
		if (length < 0)
			throw "Document length cannot be negative";
		storedValue = null;
		valueSource = source;
		valueRevision = source.semanticsValueRevision();
		documentLength = length;
	}

	/** Whether this value equals `other`'s. Two values from the same source are compared by revision without reading
		either: a deferred value reads its source as it is now, so reading one set at an older revision would compare the
		current value with itself. */
	public function sameValue(other:Semantics):Bool {
		if (valueSource != null && valueSource == other.valueSource)
			return valueRevision == other.valueRevision;
		return value == other.value;
	}

	function get_value():Null<String> {
		var source = valueSource;
		if (storedValue == null && source != null)
			storedValue = source.semanticsValue();
		return storedValue;
	}
}

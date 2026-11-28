package haxeon.ui.semantics;

import haxeon.ui.widgets.text.Utf8Text;

/** Haxe-owned accessible name, value, role, state, and supported actions. */
class Semantics {
	/** What kind of control or content it is. */
	public final role:AccessibilityRole;

	/** Its accessible name. */
	public var label:Null<String>;

	/** Its value as text, such as a field's contents; setting it updates `documentLength`. */
	public var value(get, set):Null<String>;
	var storedValue:Null<String>;
	/** Where a deferred value is read from, and the source's revision when it was set. */
	var valueSource:Null<SemanticsValueSource>;
	var valueRevision:Int;

	/** Its states, such as checked, selected or disabled. */
	public var states:AccessibilityState;

	/** The actions assistive technology may request of it. */
	public var actions:AccessibilityAction;

	/** Its value, for a slider, progress bar or other range. */
	public var numericValue(get, set):Float;

	/** The range's minimum. */
	public var numericMinimum:Float;

	/** The range's maximum. */
	public var numericMaximum(get, set):Float;

	var storedNumericValue:Float;
	var storedNumericMaximum:Float;
	/** Where the range's value and maximum are read from, when they follow state rather than being set. */
	var rangeSource:Null<SemanticsRangeSource>;

	/** Where `value` starts within the whole document, in code points, when it holds only part of it. */
	public var textStart:Int;

	/** The whole document's length, in code points. */
	public var documentLength:Int;

	/** Where the text selection starts, in document code points, or -1 for none. */
	public var selectionStart:Int;

	/** Where it ends, or -1 for none. */
	public var selectionEnd:Int;

	/** How many items its group has, or zero when unspecified. */
	public var setSize:Int;

	/** Its one-based position in that group, or zero when unspecified. */
	public var positionInSet:Int;

	/** How many rows a table or grid has, or zero when unspecified. */
	public var rowCount:Int;

	/** How many columns, or zero when unspecified. */
	public var columnCount:Int;
	/** Zero-based row index; -1 means unspecified. */
	public var rowIndex:Int;
	/** Zero-based column index; -1 means unspecified. */
	public var columnIndex:Int;

	/** How many rows a cell spans, or zero when unspecified. */
	public var rowSpan:Int;

	/** How many columns a cell spans, or zero when unspecified. */
	public var columnSpan:Int;
	/** One-based hierarchy depth; zero means unspecified. */
	public var hierarchyLevel:Int;

	/** Which way it is laid out, for lists, sliders and scroll bars. */
	public var orientation:AccessibilityOrientation;

	/** Semantics with `role`, `label` and `value`; `knownDocumentLength` saves measuring `value`. */
	public function new(role:AccessibilityRole, ?label:String, ?value:String,
			?knownDocumentLength:Int) {
		this.role = role;
		this.label = label;
		storedValue = value;
		valueSource = null;
		valueRevision = 0;
		states = AccessibilityState.empty();
		actions = AccessibilityAction.empty();
		storedNumericValue = 0.0;
		numericMinimum = 0.0;
		storedNumericMaximum = 0.0;
		rangeSource = null;
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

	/**
	 * Reads the range's value and maximum from `source` whenever a consumer asks, as a scrollbar's follow its scroll
	 * offset, which layout settles after the node is built. Setting either one drops the source.
	 */
	public function setRangeSource(source:SemanticsRangeSource):Void rangeSource = source;

	function get_numericValue():Float {
		var source = rangeSource;
		return source == null ? storedNumericValue : source.semanticsRangeValue();
	}

	function set_numericValue(value:Float):Float {
		takeRange();
		return storedNumericValue = value;
	}

	function get_numericMaximum():Float {
		var source = rangeSource;
		return source == null ? storedNumericMaximum : source.semanticsRangeMaximum();
	}

	function set_numericMaximum(value:Float):Float {
		takeRange();
		return storedNumericMaximum = value;
	}

	/** Keeps the source's current range as set values, before one of them is set. */
	function takeRange():Void {
		var source = rangeSource;
		if (source == null) return;
		storedNumericValue = source.semanticsRangeValue();
		storedNumericMaximum = source.semanticsRangeMaximum();
		rangeSource = null;
	}

	/** Whether this range equals `other`'s. Two ranges from the same source are the same: both read it as it is now. */
	function sameRange(other:Semantics):Bool {
		if (rangeSource != null && rangeSource == other.rangeSource) return true;
		return numericValue == other.numericValue && numericMaximum == other.numericMaximum;
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

	/**
	 * Whether two accessible descriptions are the same to a consumer. Written out by hand rather than generated (haxeon.Equality)
	 * because the value is compared through `sameValue`, which does not read a deferred source, and the source and its revision
	 * are not fields to compare. Every other field must be listed here: the structural test in RestyleInPlaceTests changes each
	 * field in turn and requires the difference to be seen.
	 */
	public static function same(left:Null<Semantics>, right:Null<Semantics>):Bool {
		if (left == right)
			return true;
		if (left == null || right == null)
			return false;
		return left.role == right.role && left.label == right.label && left.sameValue(right)
			&& left.states == right.states && left.actions == right.actions && left.sameRange(right)
			&& left.numericMinimum == right.numericMinimum
			&& left.textStart == right.textStart && left.documentLength == right.documentLength && left.selectionStart
			== right.selectionStart && left.selectionEnd == right.selectionEnd && left.setSize == right.setSize
			&& left.positionInSet == right.positionInSet && left.rowCount == right.rowCount && left.columnCount
			== right.columnCount && left.rowIndex == right.rowIndex && left.columnIndex == right.columnIndex
			&& left.rowSpan == right.rowSpan && left.columnSpan == right.columnSpan
			&& left.hierarchyLevel == right.hierarchyLevel && left.orientation == right.orientation;
	}

	function get_value():Null<String> {
		var source = valueSource;
		if (storedValue == null && source != null)
			storedValue = source.semanticsValue();
		return storedValue;
	}
}

/**
	A value `Semantics` defers: read only when a consumer asks for it, and compared by revision instead of by content, so
	an editor's whole document is neither assembled nor compared on frames where it did not change.
**/
interface SemanticsValueSource {
	/** The current value. */
	function semanticsValue():String;

	/** A number that changes whenever `semanticsValue` would return something different. */
	function semanticsValueRevision():Int;
}

/** A range `Semantics` reads when asked, for a range that follows state, such as a scroll offset. */
interface SemanticsRangeSource {
	/** The range's current value. */
	function semanticsRangeValue():Float;

	/** The range's current maximum. */
	function semanticsRangeMaximum():Float;
}

/** Roles already understood by NativeKit's virtual accessibility tree. */
typedef AccessibilityRole = nativekit.ffi.NativeKitTypes.NativeAccessibilityRole;

/** State bits shared with NativeKit's accessibility backend. */
typedef AccessibilityState = nativekit.ffi.NativeKitTypes.AccessibilityStates;

/** Action capability bits shared with NativeKit's accessibility backend. */
typedef AccessibilityAction = nativekit.ffi.NativeKitTypes.AccessibilityActions;

/** Generic orientation values shared with NativeKit's accessibility ABI. */
typedef AccessibilityOrientation = nativekit.ffi.NativeKitTypes.NativeAccessibilityOrientation;

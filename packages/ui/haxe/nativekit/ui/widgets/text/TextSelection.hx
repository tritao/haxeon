package nativekit.ui.widgets.text;

/** Anchored selection in absolute document codepoints, retaining direction and caret affinity. */
class TextSelection {
	public final anchor:Int;
	public final focus:Int;
	public final anchorAffinity:Int;
	public final focusAffinity:Int;

	public function new(anchor:Int, focus:Int, anchorAffinity:Int = 0, focusAffinity:Int = 0) {
		if (anchor < 0 || focus < 0) throw "Selection offsets must be non-negative";
		this.anchor = anchor;
		this.focus = focus;
		this.anchorAffinity = anchorAffinity;
		this.focusAffinity = focusAffinity;
	}
}

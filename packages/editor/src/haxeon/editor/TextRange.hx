package haxeon.editor;

/** A half-open Unicode code-point range in an editor document. */
class TextRange {
	/** Its first code point. */
	public final start:CodepointOffset;

	/** The code point after its last. */
	public final end:CodepointOffset;

	/** The code points from `start` to `end`. */
	public function new(start:CodepointOffset, end:CodepointOffset) {
		this.start = start;
		this.end = end;
	}
}

package compiler.formatter;

/**
 * How the line after a break is indented. LayoutSolver follows each physical line's indent and the indent of the element it belongs
 * to (the base): a wrapped line is placed relative to its element, never to the statement, so an element of an expanded list that
 * wraps stays inside that element.
 */
enum BreakLayout {
	/** A fill or operator break: `levels` continuation levels past the element's base; the base stays. */
	Wrap(levels:Int);

	/** The opening bracket of an expanded group: its elements go one level past the line that opened it. */
	Open;

	/** Between the elements of an expanded group: the next element at the element base. */
	Separator;

	/** The closing bracket of an expanded group: back at the indent of the line that opened it. */
	Close;

	/** A fixed indent, for the declarators of a declaration laid out one per line. */
	At(indent:Int);
}

/** Formatting policy for one boundary between adjacent logical-line tokens. */
typedef Boundary = {
	final spaces:Int;
	final canBreak:Bool;
	final mustBreak:Bool;
	final penalty:Int;
	final layout:BreakLayout;
}

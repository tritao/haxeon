package haxeon.ui;

/** Cross-axis alignment for children in a left-to-right layout. */
enum LayoutAlignmentY implements Hashable {
	Start;
	End;
	Center;
	/** Aligns baselines; baseline-less children use their bottom edge. */
	Baseline;
}

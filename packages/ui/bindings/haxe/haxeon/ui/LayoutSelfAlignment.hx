package haxeon.ui;

/** Optional per-child cross-axis alignment override. */
enum LayoutSelfAlignment implements Hashable {
	Inherit;
	Start;
	End;
	Center;
	/** Aligns baselines in a left-to-right parent. */
	Baseline;
}

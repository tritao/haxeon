package haxeon.ui;

/**
 * Where an absolutely positioned node goes, placed by the layout after the flow solve against an anchor (ADR 0002,
 * decision 6): on a side of it, aligned on the cross axis, flipped to the opposite side when it does not fit there and fits
 * better, and kept inside a region. The node's `positionX` and `positionY` then offset it from that placement. A popup,
 * a tooltip or a dropdown says this once, instead of measuring itself after layout and asking for another solve.
 *
 * A referenced node (the anchor, or the region) must come before the anchored node in tree order, such as an ancestor
 * or an earlier sibling, so its bounds are final when the node is placed.
 */
struct LayoutAnchor implements Equatable {
	/** What the node is placed against. */
	public final target:AnchorTarget;

	/** The side of the anchor the node goes on; `Overlap` places it at the anchor's origin. */
	public final side:AnchorSide = AnchorSide.Overlap;

	/** The distance from the anchor along the side's axis. */
	public final gap:Float = 0.0;

	/**
	 * On the cross axis, this fraction of the anchor's extent meets `boxAlign` of the node's: 0 and 0 align their starts,
	 * 0.5 and 0.5 their centres, 1 and 1 their ends.
	 */
	public final align:Float = 0.0;

	/** The node's fraction that meets `align` of the anchor's. */
	public final boxAlign:Float = 0.0;

	/** Whether the node takes the opposite side when it overflows on its own and the opposite has more room. */
	public final flip:Bool = false;

	/** Whether the node aligns the opposite edges on the cross axis when it would overflow the region there. */
	public final flipCross:Bool = false;

	/** The region the node is kept inside. */
	public final within:AnchorBounds = AnchorBounds.Viewport;

	/** How far inside the region the node is kept. */
	public final margin:Float = 0.0;
}

/** What an anchored node is placed against. */
enum AnchorTarget implements Equatable {
	/** The bounds, as laid out and transformed, of the node whose widget ID is `id` (`WidgetId.value`). */
	Node(id:Int);

	/** A rectangle in viewport coordinates, such as a pointer position. */
	Area(rect:Rect);
}

/** The region an anchored node is kept inside. */
enum AnchorBounds implements Equatable {
	/** The window's viewport. */
	Viewport;

	/** The bounds, as laid out and transformed, of the node whose widget ID is `id` (`WidgetId.value`). */
	Node(id:Int);

	/** A rectangle in viewport coordinates. */
	Area(rect:Rect);
}

/** The side of its anchor an anchored node goes on. */
typedef AnchorSide = NativeKitUI.UiLayoutAnchorSide;

package haxeon.ui.core;

import haxeon.ui.ResolvedLayoutItem;

/**
 * What a view's build returns: the root of what it built, which only its own build changes. A parent places it in its
 * tree with `RenderNode.add` and can read it; to add listeners, flags, semantics or children to it, the caller passes a
 * `RootModifier` to `BuildContext.build` instead, which the framework applies after every build of that view.
 * (`RootModifier.onRoot` hands it the root each time.)
 */
abstract ViewRoot(RenderNode) {
	inline function new(node:RenderNode) this = node;

	/** A node a build made becomes its root as it is returned. */
	@:from static inline function fromNode(node:RenderNode):ViewRoot return new ViewRoot(node);

	/**
	 * The node itself, for the framework that places, compares, caches and replaces roots: the core, components
	 * (`TrackedScope` applies its own style option) and the dock's pane caches.
	 */
	@:allow(haxeon.ui.core) @:allow(haxeon.ui.component) @:allow(haxeon.ui.docking)
	@:allow(haxeon.ui.widgets.overlays.TooltipOverlayHost) inline function node():RenderNode
		return this;

	/** The root's widget ID. */
	public var id(get, never):WidgetId;

	inline function get_id():WidgetId return this.id;

	/** Where layout placed the root, or null before layout. */
	public var resolved(get, never):Null<ResolvedLayoutItem>;

	inline function get_resolved():Null<ResolvedLayoutItem> return this.resolved;

	/** The root's background, for a parent that matches it around the root. */
	public var background(get, never):haxeon.ui.Color;

	inline function get_background():haxeon.ui.Color return this.layout.style.background;

	/** Calls `visit` with the root and each node below it, in tree order, to read them. */
	public function walk(visit:NodeInfo->Void):Void this.walk(node -> visit(new NodeInfo(node)));

	/** Whether the node `id` is the root or below it. */
	public inline function contains(id:WidgetId):Bool return this.find(id) != null;

	/** The root's bounds in viewport coordinates. Throws before layout. */
	public inline function globalBounds():haxeon.ui.Rect return this.globalBounds();
}

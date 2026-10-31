package haxeon.ui.widgets.docking;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.KeyHash;
import haxeon.ui.core.View;

typedef DockPanelBuilder = BuildContext->View;
typedef WidthAwareDockPanelBuilder = BuildContext->Float->View;
typedef DockPanelCacheKeyBuilder = Void->String;
/** Adds the panel's revision inputs to a key hash, in place of building a string. Do not reset the hash. */
typedef DockPanelCacheKeyHasher = KeyHash->Void;

/** Lazy view factory kept separate from the view-independent dock model. */
class DockPanelContent {
	public final panelId:String;
	/** Builds the panel when it has no `buildWithWidth`. */
	public final build:Null<DockPanelBuilder>;
	/** Builder for panels that adapt to their dock pane width; used in place of `build` when given. */
	public final buildWithWidth:Null<WidthAwareDockPanelBuilder>;
	/** Optional application-owned revision key enabling retained panel trees. */
	public final cacheKey:Null<DockPanelCacheKeyBuilder>;
	/** Allocation-free alternative to `cacheKey`; when both are given this one is used. */
	public final cacheKeyHash:Null<DockPanelCacheKeyHasher>;
	/**
	 * Retain the panel by what its build reads through BuildContext.observeInt and friends (and the widget state it uses),
	 * with no key: a read cannot be left out of a key that does not exist. See `observing`.
	 */
	public var observed:Bool = false;

	/** A panel retained by what its build observes; the preferred way to make a panel retained. */
	public static function observing(panelId:String, build:DockPanelBuilder,
			?buildWithWidth:WidthAwareDockPanelBuilder):DockPanelContent {
		var content = new DockPanelContent(panelId, build, buildWithWidth);
		content.observed = true;
		return content;
	}

	/** Like `observing`, for a panel that is always built at its pane width. */
	public static function observingWithWidth(panelId:String, buildWithWidth:WidthAwareDockPanelBuilder):DockPanelContent {
		var content = new DockPanelContent(panelId, null, buildWithWidth);
		content.observed = true;
		return content;
	}

	public function new(panelId:String, build:Null<DockPanelBuilder>,
			?buildWithWidth:WidthAwareDockPanelBuilder,
			?cacheKey:DockPanelCacheKeyBuilder, ?cacheKeyHash:DockPanelCacheKeyHasher) {
		if (panelId == null || panelId.length == 0 || (build == null && buildWithWidth == null))
			throw "Dock panel content requires a stable panel ID and builder";
		this.panelId = panelId;
		this.build = build;
		this.buildWithWidth = buildWithWidth;
		this.cacheKey = cacheKey;
		this.cacheKeyHash = cacheKeyHash;
	}
}

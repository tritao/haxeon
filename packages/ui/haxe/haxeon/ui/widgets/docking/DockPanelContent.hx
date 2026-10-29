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
	public final build:DockPanelBuilder;
	/** Optional builder for panels that adapt to their dock pane width. */
	public final buildWithWidth:Null<WidthAwareDockPanelBuilder>;
	/** Optional application-owned revision key enabling retained panel trees. */
	public final cacheKey:Null<DockPanelCacheKeyBuilder>;
	/** Allocation-free alternative to `cacheKey`; when both are given this one is used. */
	public final cacheKeyHash:Null<DockPanelCacheKeyHasher>;

	public function new(panelId:String, build:DockPanelBuilder,
			?buildWithWidth:WidthAwareDockPanelBuilder,
			?cacheKey:DockPanelCacheKeyBuilder, ?cacheKeyHash:DockPanelCacheKeyHasher) {
		if (panelId == null || panelId.length == 0 || build == null)
			throw "Dock panel content requires a stable panel ID and builder";
		this.panelId = panelId;
		this.build = build;
		this.buildWithWidth = buildWithWidth;
		this.cacheKey = cacheKey;
		this.cacheKeyHash = cacheKeyHash;
	}
}

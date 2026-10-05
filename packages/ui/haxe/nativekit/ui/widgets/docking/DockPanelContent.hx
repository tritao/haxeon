package nativekit.ui.widgets.docking;

import nativekit.ui.core.BuildContext;
import nativekit.ui.core.View;

typedef DockPanelBuilder = BuildContext->View;
typedef WidthAwareDockPanelBuilder = BuildContext->Float->View;
typedef DockPanelCacheKeyBuilder = Void->String;

/** Lazy view factory kept separate from the view-independent dock model. */
class DockPanelContent {
	public final panelId:String;
	public final build:DockPanelBuilder;
	/** Optional builder for panels that adapt to their dock pane width. */
	public final buildWithWidth:Null<WidthAwareDockPanelBuilder>;
	/** Optional application-owned revision key enabling retained panel trees. */
	public final cacheKey:Null<DockPanelCacheKeyBuilder>;

	public function new(panelId:String, build:DockPanelBuilder,
			?buildWithWidth:WidthAwareDockPanelBuilder,
			?cacheKey:DockPanelCacheKeyBuilder) {
		if (panelId == null || panelId.length == 0 || build == null)
			throw "Dock panel content requires a stable panel ID and builder";
		this.panelId = panelId;
		this.build = build;
		this.buildWithWidth = buildWithWidth;
		this.cacheKey = cacheKey;
	}
}

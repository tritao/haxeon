package haxeon.ui.widgets.docking;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.View;

/** Builds a panel's view. */
typedef DockPanelBuilder = BuildContext->View;

/** Builds a panel's view for the width of its pane. */
typedef WidthAwareDockPanelBuilder = BuildContext->Float->View;
/** Lazy view factory kept separate from the view-independent dock model. */
class DockPanelContent {
	/** The panel in the dock model whose view this builds. */
	public final panelId:String;
	/** Builds the panel when it has no `buildWithWidth`. */
	public final build:Null<DockPanelBuilder>;
	/** Builder for panels that adapt to their dock pane width; used in place of `build` when given. */
	public final buildWithWidth:Null<WidthAwareDockPanelBuilder>;
	/**
	 * Retain the panel by the observable fields and signals its build reads (and the widget state it uses),
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
	public static function observingWithWidth(panelId:String,
			buildWithWidth:WidthAwareDockPanelBuilder):DockPanelContent {
		var content = new DockPanelContent(panelId, null, buildWithWidth);
		content.observed = true;
		return content;
	}

	/**
	 * Content for the panel `panelId`, built by `build` or `buildWithWidth`. Throws when `panelId` is empty or there
	 * is no builder.
	 */
	public function new(panelId:String, build:Null<DockPanelBuilder>,
			?buildWithWidth:WidthAwareDockPanelBuilder) {
		if (panelId == null || panelId.length == 0 || (build == null && buildWithWidth == null))
			throw "Dock panel content requires a stable panel ID and builder";
		this.panelId = panelId;
		this.build = build;
		this.buildWithWidth = buildWithWidth;
	}
}

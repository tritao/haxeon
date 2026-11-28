package shell;

import UiExplorer;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.View;
import haxeon.ui.widgets.layout.AppShell;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.SplitView;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.text.DefaultTextStyle;
import shell.CatalogSidebar;
import shell.TopBar;

/** Persistent resizable catalog/content/inspector shell around Explorer pages. */
class ExplorerShell {
	public static function build(explorer:UiExplorer):View {
		var mainStyle = new LayoutStyle();
		mainStyle.width = LayoutAxis.grow();
		mainStyle.height = LayoutAxis.grow();
		mainStyle.padding = new Insets(22.0, 18.0, 22.0, 18.0);
		var scrollStyle = new LayoutStyle();
		scrollStyle.width = LayoutAxis.grow();
		scrollStyle.height = LayoutAxis.grow();
		scrollStyle.clipVertical = true;
		var pageScroll = new ScrollView("page-scroll", explorer.buildPage(), scrollStyle,
			ScrollAxis.Vertical);
		var main:View = new Column("main-content", [explorer.keyed("page", pageScroll)], mainStyle);
		if (explorer.state.inspector.open && explorer.width >= 880.0) {
			var dividerStyle = new LayoutStyle();
			dividerStyle.background = explorer.state.lightTheme
				? UiExplorer.color(0.78, 0.82, 0.89) : UiExplorer.color(0.13, 0.17, 0.24);
			main = new SplitView("main-inspector", main, explorer.buildInspector(), resizableSide: SplitSide.Trailing,
				extent: explorer.state.inspector.width, minimumExtent: 220.0, maximumExtent: 420.0, dividerExtent: 8.0,
				dividerStyle:, onResize: value -> {
					explorer.state.inspector.width = value;
				});
		}

		var catalogDividerStyle = new LayoutStyle();
		catalogDividerStyle.background = explorer.state.lightTheme
			? UiExplorer.color(0.78, 0.82, 0.89) : UiExplorer.color(0.13, 0.17, 0.24);
		var shellContent:View = new SplitView("catalog-content",
			CatalogSidebar.build(explorer), main, resizableSide: SplitSide.Leading,
			extent: explorer.state.catalogWidth > 0.0
			? explorer.state.catalogWidth : (explorer.width < 760.0 ? 176.0 : 212.0),
			minimumExtent: explorer.width < 760.0 ? 160.0 : 176.0, maximumExtent: 300.0, dividerExtent: 8.0,
			dividerStyle: catalogDividerStyle, onResize: value -> {
				explorer.state.catalogWidth = value;
			});

		var shellStyle = new LayoutStyle();
		shellStyle.width = LayoutAxis.grow();
		shellStyle.height = LayoutAxis.grow();
		shellStyle.background = explorer.paletteBackground();
		var shell = new AppShell("app-shell", shellContent, TopBar.build(explorer),
			null, null, shellStyle);
		return new DefaultTextStyle(shell, TextStyleOverride.text(15.0));
	}
}

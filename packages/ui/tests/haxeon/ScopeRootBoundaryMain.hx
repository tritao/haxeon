import haxeon.ui.LayoutAxis;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.ScopeRootBoundary;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.WidgetId;

/** The boundary records what a body built on its root and reports any change a caller made by hand. */
class ScopeRootBoundaryMain {
	static function main():Int {
		var first = new RenderNode(new WidgetId(1));
		first.layout.style.width = LayoutAxis.fixed(10);
		var body = first.add(new RenderNode(new WidgetId(2)));
		first.on(UiEventKind.Focus, _ -> {});
		var boundary = new ScopeRootBoundary(first);
		if (boundary.callerChanges(first) != null || !boundary.owns(body)) return 1;
		first.layout.style.width = LayoutAxis.fixed(100);
		if (boundary.callerChanges(first) == null) return 2;
		first.layout.style.width = LayoutAxis.fixed(10);
		var overlay = first.add(new RenderNode(new WidgetId(3)));
		if (boundary.callerChanges(first) != "children" || boundary.owns(overlay)) return 3;
		overlay.detach();
		first.on(UiEventKind.Blur, _ -> {});
		if (boundary.callerChanges(first) != "listeners") return 4;
		var next = new RenderNode(first.id);
		next.layout.style.width = LayoutAxis.fixed(40);
		var nextBody = next.add(new RenderNode(new WidgetId(4)));
		boundary.reset(next);
		if (boundary.callerChanges(next) != null || !boundary.owns(nextBody) || boundary.owns(body)) return 5;
		next.focusable = !next.focusable;
		if (boundary.callerChanges(next) != "node fields") return 6;
		return 42;
	}
}

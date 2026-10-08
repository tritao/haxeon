import haxeon.ui.LayoutFrame;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.overlays.Menu;
import haxeon.ui.widgets.overlays.MenuItem;

/** Behavioral coverage for opening modality, navigation, activation and dismissal. */
class MenuInteractionTests {
	public static function run(context:UiContext):Void {
		var dialogFrame = new LayoutFrame(320.0, 240.0);
		var returnFocusView = new Button("Menu origin", null, null, "menu-focus-origin");
		// Pointer invocation owns keyboard focus without choosing an action.
		var origin = context.submit(returnFocusView, dialogFrame);
		context.focusWidget(origin.id);
		var pointerChoice = "";
		var menuFocusLabel = function():String {
			var focused = context.focus.focusedNode();
			return focused == null || focused.semantics == null ? "" : focused.semantics.label;
		};
		var pointerDismissals = 0;
		var pointerMenu = new Menu("pointer-menu-smoke", [
			new MenuItem("disabled-first", "Unavailable", null, false),
			new MenuItem("first", "First", function() { pointerChoice = "first"; }),
			new MenuItem("disabled-middle", "Unavailable", null, false),
			new MenuItem("last", "Last", function() { pointerChoice = "last"; })
		], 16.0, 16.0, function() { pointerDismissals++; });
		var pointerRoot = context.submit(pointerMenu, dialogFrame);
		if (context.focus.focusedId == null || !context.focus.focusedId.equals(pointerRoot.id))
			throw "Pointer menu must focus the menu without selecting an item";
		context.key(UiEventKind.KeyDown, UiKey.Enter);
		context.key(UiEventKind.KeyDown, UiKey.Space);
		if (pointerChoice != "" || pointerDismissals != 0)
			throw "An unselected menu must ignore Enter and Space";
		context.key(UiEventKind.KeyDown, UiKey.Down);
		if (menuFocusLabel() != "First")
			throw "Down must select the first enabled action";
		pointerRoot = context.submit(pointerMenu, dialogFrame);
		if (menuFocusLabel() != "First")
			throw "Rebuilding a menu must preserve its selection";
		context.key(UiEventKind.KeyRepeat, UiKey.Down);
		if (menuFocusLabel() != "Last") throw "Held Down must skip disabled actions";
		context.key(UiEventKind.KeyRepeat, UiKey.Up);
		if (menuFocusLabel() != "First") throw "Held Up must skip disabled actions";
		context.key(UiEventKind.KeyDown, UiKey.Up);
		if (menuFocusLabel() != "Last")
			throw "Up must wrap past disabled actions";
		context.key(UiEventKind.KeyDown, UiKey.Enter);
		if (pointerChoice != "last" || pointerDismissals != 1)
			throw "Enter must activate the selected action exactly once";
		origin = context.submit(returnFocusView, dialogFrame);
		if (!origin.id.equals(context.focus.focusedId))
			throw "Menu dismissal must restore the originating focus";
		pointerRoot = context.submit(pointerMenu, dialogFrame);
		if (!pointerRoot.id.equals(context.focus.focusedId))
			throw "Reopening a pointer menu must clear the previous selection";
		context.key(UiEventKind.KeyDown, UiKey.Up);
		if (menuFocusLabel() != "Last")
			throw "Up from an unselected menu must select the last enabled action";
		var firstPointerItem:Null<RenderNode> = null;
		pointerRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.MenuItem &&
				node.semantics.label == "First") firstPointerItem = node;
		});
		if (firstPointerItem == null) throw "Missing first menu item";
		var firstItemId = firstPointerItem.id;
		var firstBounds = firstPointerItem.globalBounds();
		context.pointerMove(firstBounds.x + firstBounds.width / 2, firstBounds.y + firstBounds.height / 2);
		if (!firstItemId.equals(context.focus.focusedId))
			throw "Pointer movement must replace the keyboard selection";
		context.key(UiEventKind.KeyDown, UiKey.Escape);
		if (pointerDismissals != 2) throw "Escape must dismiss an unactivated menu";
		context.submit(returnFocusView, dialogFrame);
		pointerMenu.selectFirstOnOpen = true;
		context.submit(pointerMenu, dialogFrame);
		if (menuFocusLabel() != "First")
			throw "Keyboard invocation must select the first enabled action";
		context.submit(returnFocusView, dialogFrame);
		var emptyDismissals = 0;
		var emptyMenuRoot = context.submit(new Menu("empty-menu-smoke", [], 16.0, 16.0,
			function() { emptyDismissals++; }), dialogFrame);
		if (!emptyMenuRoot.id.equals(context.focus.focusedId)) throw "Empty menus must own keyboard focus";
		context.key(UiEventKind.KeyDown, UiKey.Down);
		context.key(UiEventKind.KeyDown, UiKey.Enter);
		context.key(UiEventKind.KeyDown, UiKey.Escape);
		if (emptyDismissals != 1) throw "Empty menus must ignore activation and support Escape";
		context.submit(returnFocusView, dialogFrame);
		Sys.println("PASS: menu opening modality, navigation, pointer takeover, activation and focus restoration");
	}
}

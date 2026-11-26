package haxeon.ui.core;

import haxeon.ui.LayoutStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.ComputedStyle;

/**
 * What a component's body built on its root: its children, listener counts, semantics and fields. A caller never edits a
 * component's root (it passes a RootModifier, which the scope takes off before reading this), so the root differs from
 * this baseline only when one did, which `callerChanges` reports. Stored by value on the native scope.
 */
@:access(haxeon.ui.core.RenderNode) internal struct ScopeRootBoundary {
	final style:LayoutStyle;
	final children:Array<RenderNode>;
	var semantics:Null<Semantics>;
	var cursor:Null<CursorShape>;
	var tabIndex:Int;
	var commandScope:Null<String>;
	var windowDecoration:Null<nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind>;
	var windowDecorationCursor:Null<CursorShape>;
	var hitTestBehavior:HitTestBehavior;
	var focusTrap:Bool;
	var hitTestSelf:Bool;
	var commandShortcutFilter:Null<String->Bool>;
	var computedStyle:Null<ComputedStyle>;
	var focusable:Bool;
	var enabled:Bool;
	var handlers:Int;
	var outside:Int;
	var resolved:Int;
	var paint:Int;
	var decorations:Int;

	public function new(root:RenderNode) {
		style = root.layout.style.copy();
		children = [];
		reset(root);
	}

	/** Records what a new body built on `root`, reusing this boundary's storage. */
	public function reset(root:RenderNode):Void {
		haxeon.Diff.apply(style, style, root.layout.style);
		children.resize(0);
		for (child in root.children) children.push(child);
		semantics = root.semantics;
		cursor = root.cursor;
		tabIndex = root.tabIndex;
		commandScope = root.commandScope;
		windowDecoration = root.windowDecoration;
		windowDecorationCursor = root.windowDecorationCursor;
		hitTestBehavior = root.hitTestBehavior;
		focusTrap = root.focusTrap;
		hitTestSelf = root.hitTestSelf;
		commandShortcutFilter = root.commandShortcutFilter;
		computedStyle = root.computedStyle;
		focusable = root.focusable;
		enabled = root.enabled;
		handlers = root.handlers == null ? 0 : root.handlers.length;
		outside = root.outsidePointerDownHandlers == null ? 0 : root.outsidePointerDownHandlers.length;
		resolved = root.resolvedHandlers == null ? 0 : root.resolvedHandlers.length;
		paint = root.paintHandlers == null ? 0 : root.paintHandlers.length;
		decorations = root.decorations == null ? 0 : root.decorations.length;
	}

	/** Whether `child` is one the body built, or the current root of a nested scope it built. */
	public function owns(child:RenderNode):Bool {
		for (declared in children) {
			if (declared == child) return true;
			var owner = declared.scopeOwner();
			if (owner != null && owner.currentRoot(declared) == child) return true;
		}
		return false;
	}

	/** What a caller changed on `root` since its body built it, or null when nothing did. */
	public function callerChanges(root:RenderNode):Null<String> {
		var styleBits = haxeon.Diff.mask(style, root.layout.style) & LayoutStyle.valueFields;
		if (styleBits != 0) return "layout style (fields " + styleBits + ")";
		if (root.cursor != cursor || root.tabIndex != tabIndex || root.commandScope != commandScope
			|| root.windowDecoration != windowDecoration || root.windowDecorationCursor != windowDecorationCursor
			|| root.hitTestBehavior != hitTestBehavior || root.focusTrap != focusTrap || root.hitTestSelf != hitTestSelf
			|| root.commandShortcutFilter != commandShortcutFilter || root.focusable != focusable
			|| root.enabled != enabled) return "node fields";
		if (root.computedStyle != computedStyle) return "computed style";
		if (root.semantics != semantics) return "semantics";
		if ((root.handlers == null ? 0 : root.handlers.length) != handlers) return "listeners";
		if ((root.outsidePointerDownHandlers == null ? 0 : root.outsidePointerDownHandlers.length) != outside)
			return "outside-press listeners";
		if ((root.resolvedHandlers == null ? 0 : root.resolvedHandlers.length) != resolved) return "resolved callbacks";
		if ((root.paintHandlers == null ? 0 : root.paintHandlers.length) != paint) return "paint";
		if ((root.decorations == null ? 0 : root.decorations.length) != decorations) return "decorations";
		if (root.children.length != children.length) return "children";
		// A nested scope that ran again replaced its own root here; the declared child resolves to it.
		for (child in root.children) if (!owns(child)) return "children";
		return null;
	}
}

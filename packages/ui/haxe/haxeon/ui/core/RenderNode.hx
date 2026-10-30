package haxeon.ui.core;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.Paint;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.TextLayout;
import haxeon.ui.TextStyle;
import haxeon.ui.Transform2D;

import haxeon.ui.widgets.text.Text;


import nativekit.ffi.NativeKitTypes.WindowDecorationRegionKind;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Canvas;
import haxeon.ui.CompositeMode;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.Point;
import haxeon.ui.Rect;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.style.Decoration;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleDiff;
import haxeon.ui.style.StyleImpact;
import haxeon.ui.semantics.Semantics;

/** One Haxe-owned node joins visual layout, interaction, focus, and state identity. */
class RenderNode {
	public final id:WidgetId;
	public final layout:LayoutNode;
	/** Shared and empty until the first `add`, so leaves allocate no array; change it only through `add`, `remove` and `replaceWith`. */
	public var children(default, null):Array<RenderNode>;
	static final NoChildren:Array<RenderNode> = [];
	public var parent(default, null):Null<RenderNode>;
	public var resolved:Null<ResolvedLayoutItem>;
	public var focusable:Bool;
	public var focusTrap:Bool;
	public var hitTestSelf:Bool;
	public var hitTestBehavior:HitTestBehavior;
	/** Controls GPU raster reuse for this node's custom paint. */
	public var cachePolicy:CachePolicy;
	public var enabled:Bool;
	/** Generic pseudo-state flags maintained by the routed interaction system. */
	/** Interaction state (hover, press, focus) the widget saw when it built this node. */
	public var states(default, set):Int;
	/**
	 * Whether a widget recorded interaction state on this node. Structural nodes that never read it have no reason to rebuild
	 * when the pointer moves over them, so cache validation ignores them.
	 */
	public var recordsInteraction(default, null):Bool = false;

	/** Invalidate a retained custom display list without changing geometry or text. */
	public function invalidatePaint():Void {
		contentRevision++;
		invalidationFlags = UiDirtyFlag.NeedsPaint;
	}

	inline function set_states(value:Int):Int {
		recordsInteraction = true;
		return states = value;
	}

	/** Keeps the routed state on the node without claiming that a widget built from it: that is what `recordsInteraction` says. */
	@:allow(haxeon.ui.core.EventDispatcher)
	function routeStates(value:Int):Void {
		var recorded = recordsInteraction;
		states = value;
		recordsInteraction = recorded;
	}
	public var styleType:Null<String>;
	public var styleKey:Null<String>;
	public var styleId:Null<String>;
	public var styleClasses:Array<String>;
	public var styleTags:Array<String>;
	/** Optional command scope contributed by this node and its focused subtree. */
	public var commandScope:Null<String>;
	/** Focused input widgets may route selected commands before consuming their keys.
	 * The predicate receives the winning command ID, after scope and binding resolution.
	 * Other keys still reach the widget; modal focus traps suppress this routing.
	 */
	public var commandShortcutFilter:Null<String->Bool> = null;
	public var computedStyle:Null<ComputedStyle>;
	public var tabIndex:Int;
	/** Cursor intent used while this node is hovered or holds pointer capture. */
	public var cursor:Null<CursorShape>;
	/** Native hit-test behavior assigned to this node's resolved bounds. */
	public var windowDecoration:Null<WindowDecorationRegionKind>;
	/** Optional native cursor override for this node's window-chrome region. */
	public var windowDecorationCursor:Null<CursorShape>;
	public var semantics:Null<Semantics>;
	/** Revision of paint/text content consumed by retained scene caches. */
	public var contentRevision(default, null):Int;
	/** Revision of resolved bounds, transforms, clips, and paint order. */
	public var geometryRevision(default, null):Int;
	/** Revision of opacity/effects and other compositing inputs. */
	public var compositeRevision(default, null):Int;
	/** Categories raised while this node was compared with its prior frame. */
	public var invalidationFlags(default, null):Int;
	/** Most nodes never take handlers, custom paint or decorations, so these are allocated on first use. */
	var handlers:Null<Array<HandlerEntry>>;
	var outsidePointerDownHandlers:Null<Array<UiEvent->Void>>;
	var resolvedHandlers:Null<Array<ResolvedLayoutItem->Void>>;
	var paintHandlers:Null<Array<Canvas->ResolvedLayoutItem->Void>>;
	var paintCacheKeys:Null<Array<Null<String>>>;
	var basePaintKey:Null<String>;
	var basePaintKeyResolved:Bool = false;
	var decorations:Null<Array<Decoration>>;
	var decorationCacheKeys:Null<Array<Null<String>>>;
	/** Shared by every node without classes or tags; never mutated. */
	static final NoStrings:Array<String> = [];

	/** `sharedLayout` is for stand-ins that compare as the node they stand for (snapshotForCompare); it is never submitted. */
	public function new(id:WidgetId, kind:LayoutVisualKind = LayoutVisualKind.Box, ?style:LayoutStyle, ?sharedLayout:LayoutNode) {
		if (id == null)
			throw "Render nodes require a stable widget ID";
		this.id = id;
		layout = sharedLayout != null ? sharedLayout : new LayoutNode(id.value, kind, style);
		children = NoChildren;
		parent = null;
		resolved = null;
		focusable = false;
		focusTrap = false;
		hitTestSelf = true;
		hitTestBehavior = HitTestBehavior.Auto;
		cachePolicy = CachePolicy.None;
		enabled = true;
		states = 0;
		recordsInteraction = false;
		styleType = null;
		styleKey = null;
		styleId = null;
		styleClasses = NoStrings;
		styleTags = NoStrings;
		commandScope = null;
		computedStyle = null;
		tabIndex = 0;
		cursor = null;
		windowDecoration = null;
		windowDecorationCursor = null;
		semantics = null;
		contentRevision = 1;
		geometryRevision = 1;
		compositeRevision = 1;
		invalidationFlags = UiDirtyFlag.NeedsBuild | UiDirtyFlag.NeedsStyle |
			UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint |
			UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsSemantics | UiDirtyFlag.NeedsHitGeometry;
		handlers = null;
		outsidePointerDownHandlers = null;
		resolvedHandlers = null;
		paintHandlers = null;
		paintCacheKeys = null;
		decorations = null;
		decorationCacheKeys = null;
	}

	/** Publishes the typed selector identity associated with this render node. */
	public function setStyleIdentity(type:String, ?key:String, ?id:String,
			?classes:Array<String>, ?tags:Array<String>):RenderNode {
		if (type == null || type.length == 0)
			throw "Styled render nodes require a type";
		styleType = type;
		styleKey = key;
		styleId = id;
		styleClasses = classes == null || classes.length == 0 ? NoStrings : haxeon.ui.style.StyleTarget.shared(classes);
		styleTags = tags == null || tags.length == 0 ? NoStrings : haxeon.ui.style.StyleTarget.shared(tags);
		return this;
	}

	public function add(child:RenderNode):RenderNode {
		if (child == null || child == this || child.parent != null)
			throw "A render node must have one parent and cannot contain itself";
		var ancestor:Null<RenderNode> = this;
		while (ancestor != null) {
			if (ancestor == child)
				throw "Render tree contains a cycle";
			ancestor = ancestor.parent;
		}
		child.parent = this;
		if (children == NoChildren)
			children = [];
		children.push(child);
		layout.add(child.layout);
		return child;
	}

	/** Detaches this node from its current parent so a retained subtree can move. */
	public function detach():RenderNode {
		if (parent == null)
			return this;
		var previous = parent;
		previous.children.remove(this);
		previous.layout.remove(layout);
		parent = null;
		return this;
	}

	/** Set when this node was rebuilt in place: the node that took its place. Retained caches that still hold this one follow it. */
	public var replacedBy:Null<RenderNode> = null;

	/** This node, or the node that finally took its place if it was rebuilt in place (possibly more than once). */
	public static function latest(node:RenderNode):RenderNode {
		var current = node;
		var next = current.replacedBy;
		while (next != null) {
			current = next;
			next = current.replacedBy;
		}
		return current;
	}

	/** Puts `next` where this node is in its parent, in the render tree and the layout tree, and detaches this node. */
	public function replaceWith(next:RenderNode):RenderNode {
		if (next == null || next == this || next.parent != null)
			throw "A replacement render node must be a fresh, unparented node";
		var owner = parent;
		if (owner == null)
			throw "Only a node with a parent can be replaced in place";
		var index = owner.children.indexOf(this);
		if (index < 0)
			throw "Render tree is inconsistent: node is missing from its parent";
		owner.children[index] = next;
		owner.layout.children[index] = next.layout;
		next.parent = owner;
		parent = null;
		replacedBy = next;
		return next;
	}

	static final fingerprintHash:KeyHash = new KeyHash();

	/**
	 * A hash of what this node shows and how it lays out, from what the frame comparison reads. A debug check compares it
	 * across frames to find changes to the submitted tree that nobody announced (UiContext.verifyRetentionEvery).
	 */
	public function fingerprint():Int {
		var hash = fingerprintHash.reset();
		hash.addInt(haxeon.Structural.hash(layout.style)).addInt(cast layout.visualKind).addString(layout.text)
			.addInt(layout.measureVersion).addBool(hitTestSelf).addBool(focusable).addBool(enabled)
			.addString(semantics == null ? null : semantics.label);
		var text = layout.textColor;
		if (text != null) hash.addInt(haxeon.Structural.hash(text));
		hash.addInt(children.length);
		return hash.a ^ (hash.b * 31);
	}

	/**
	 * A detached copy of what the frame comparison reads from this node (style, layout inputs, hit testing, semantics, revisions,
	 * parent and child order), taken before the node is changed in place so the change is still seen as one.
	 */
	public function snapshotForCompare(shareLayout:Bool = false):RenderNode {
		var prior = shareLayout ? new RenderNode(id, layout.visualKind, null, layout) : new RenderNode(id, layout.visualKind, layout.style.copy());
		prior.computedStyle = computedStyle;
		prior.states = states;
		if (!shareLayout) {
			prior.layout.text = layout.text;
			prior.layout.textColor = layout.textColor;
			prior.layout.measureVersion = layout.measureVersion;
			prior.layout.intrinsicContent = layout.intrinsicContent;
		}
		prior.parent = parent;
		prior.children = children.copy();
		prior.contentRevision = contentRevision;
		prior.geometryRevision = geometryRevision;
		prior.compositeRevision = compositeRevision;
		prior.hitTestSelf = hitTestSelf;
		prior.hitTestBehavior = hitTestBehavior;
		prior.semantics = semantics;
		prior.enabled = enabled;
		prior.focusable = focusable;
		prior.focusTrap = focusTrap;
		prior.tabIndex = tabIndex;
		prior.resolved = resolved;
		return prior;
	}

	/**
	 * What a builder made on this node when it returned it, to be taken before callers decorate the node: a later rebuild
	 * (reconcile) replaces just that and leaves the listeners, paint callbacks, children and style changes callers add after.
	 */
	public function snapshotBuilt():BuiltNode {
		var built = new BuiltNode(layout.style.copy(), children.copy(), semantics);
		countCallbacks(built);
		return built;
	}

	function countCallbacks(built:BuiltNode):Void {
		built.handlers = handlers == null ? 0 : handlers.length;
		built.outsidePointerDownHandlers = outsidePointerDownHandlers == null ? 0 : outsidePointerDownHandlers.length;
		built.resolvedHandlers = resolvedHandlers == null ? 0 : resolvedHandlers.length;
		built.paintHandlers = paintHandlers == null ? 0 : paintHandlers.length;
		built.decorations = decorations == null ? 0 : decorations.length;
	}

	/**
	 * Whether `fresh`, a new build of this node, can be applied to it in place. A box a caller or the frame promoted to a custom
	 * one (decorations, paint) still takes a box build; any other change of kind needs a replacement.
	 */
	public function canReconcile(fresh:RenderNode):Bool {
		var kind = layout.visualKind, next = fresh.layout.visualKind;
		return fresh.id.value == id.value && (kind == next || (kind == LayoutVisualKind.Custom && next == LayoutVisualKind.Box));
	}

	/**
	 * The one way a widget's rebuild reaches the node it built before. Applies `fresh`, the node the builder just made, to this
	 * one, which stays in the tree with everything callers attached after `built` was taken:
	 *
	 * - style: only the properties the builder changed between the two builds (`built` is updated to the new build);
	 * - computed style, interaction state and semantics (unless a caller replaced them);
	 * - listeners, outside-pointer, geometry and paint callbacks and decorations the builder made, replaced by the new build's;
	 * - children the builder made, each swapped for its new build in the same place (a new build's callbacks refer to the nodes it
	 *   made, so those must be the ones in the tree); surplus ones are removed and further ones inserted after the last.
	 *
	 * Properties of the node other than these (focusable, enabled, cursor, tab index, command scope) come from the widget
	 * instance, which a rebuild keeps. Returns a stand-in for the node as it was, for the frame comparison.
	 */
	public function reconcile(fresh:RenderNode, built:BuiltNode):RenderNode {
		// A rebuild that changed nothing the frame comparison reads (typing in a field whose appearance stays) is compared with the node itself.
		var styleChanged = haxeon.Structural.changedMask(built.style, fresh.layout.style) != 0;
		// The layout is only shared with the stand-in when the rebuild leaves the style as it is.
		var prior = styleChanged || appearanceChanged(fresh, built) ? snapshotForCompare(!styleChanged) : this;
		computedStyle = fresh.computedStyle;
		states = fresh.states;
		haxeon.Structural.assignChanged(layout.style, built.style, fresh.layout.style);
		haxeon.Structural.assignChanged(built.style, built.style, fresh.layout.style);
		if (semantics == built.semantics) semantics = fresh.semantics;
		built.semantics = fresh.semantics;
		// The counts of the new build, taken before its lists take what callers added to this node.
		var madeHandlers = built.handlers, madeOutside = built.outsidePointerDownHandlers, madeResolved = built.resolvedHandlers;
		var madePaint = built.paintHandlers, madeDecorations = built.decorations;
		fresh.countCallbacks(built);
		handlers = swapBuilt(handlers, madeHandlers, fresh.handlers);
		outsidePointerDownHandlers = swapBuilt(outsidePointerDownHandlers, madeOutside, fresh.outsidePointerDownHandlers);
		resolvedHandlers = swapBuilt(resolvedHandlers, madeResolved, fresh.resolvedHandlers);
		paintCacheKeys = swapBuilt(paintCacheKeys, madePaint, fresh.paintCacheKeys);
		paintHandlers = swapBuilt(paintHandlers, madePaint, fresh.paintHandlers);
		decorationCacheKeys = swapBuilt(decorationCacheKeys, madeDecorations, fresh.decorationCacheKeys);
		decorations = swapBuilt(decorations, madeDecorations, fresh.decorations);
		basePaintKeyResolved = false;
		swapChildren(fresh, built.children);
		return prior;
	}

	/** Whether `fresh` differs from this node in anything but style the root of a reconcile takes from it (callbacks aside). */
	function appearanceChanged(fresh:RenderNode, built:BuiltNode):Bool {
		if (computedStyle != fresh.computedStyle || states != fresh.states || !Semantics.same(semantics, fresh.semantics) ||
			built.children.length != fresh.children.length)
			return true;
		for (index in 0...built.children.length)
			if (built.children[index].parent != this || built.children[index].id.value != fresh.children[index].id.value)
				return true;
		return false;
	}

	/** `current` with the first `count` entries, which the builder made, replaced by `fresh`: what is left of `current` was added by callers. */
	static function swapBuilt<T>(current:Null<Array<T>>, count:Int, fresh:Null<Array<T>>):Null<Array<T>> {
		var total = current == null ? 0 : current.length;
		if (total <= count)
			return fresh;
		var result:Array<T> = fresh == null ? [] : fresh;
		var source:Array<T> = cast current;
		for (index in count...total)
			result.push(source[index]);
		return result;
	}

	/**
	 * Replaces the children the builder made (`built`) by those of `fresh`, each in the place of the one before it; children
	 * callers added stay where they are. `built` becomes the new build's children.
	 */
	function swapChildren(fresh:RenderNode, built:Array<RenderNode>):Void {
		var count = fresh.children.length;
		var position = -1;
		// Each new child is taken from the front of the new build's list as it is detached, and recorded in `built` over the
		// old one it replaces.
		for (index in 0...built.length) {
			var old = built[index];
			if (index < count) {
				var child = fresh.children[0].detach();
				built[index] = child;
				if (old.parent != this) continue;
				old.replaceWith(child);
				position = children.indexOf(child);
			} else if (old.parent == this) {
				position = children.indexOf(old) - 1;
				old.detach();
			}
		}
		for (index in built.length...count) {
			var child = fresh.children[0].detach();
			built.push(child);
			if (position < 0 || children == NoChildren) {
				add(child);
				position = children.length - 1;
			} else {
				position++;
				child.parent = this;
				children.insert(position, child);
				layout.children.insert(position, child.layout);
			}
		}
		built.resize(count);
	}

	/** Converts a point in this node's local space into viewport/global space. */
	public function localToGlobal(point:Point):Point
		return requireResolved().localToViewport(point);

	/** Converts a viewport/global point into this node's local space. */
	public function globalToLocal(point:Point):Point
		return requireResolved().viewportToLocal(point);

	/** Converts a point from this node's local space into another node's local space. */
	public function localToNode(point:Point, other:RenderNode):Point {
		if (other == null)
			throw "Coordinate conversion requires another render node";
		return other.globalToLocal(localToGlobal(point));
	}

	public function localBounds():Rect
		return requireResolved().localBounds();

	public function globalBounds():Rect
		return requireResolved().viewportBounds();

	public function containsGlobalPoint(point:Point):Bool {
		if (point == null)
			throw "Global points cannot be null";
		return requireResolved().hitTest(point.x, point.y);
	}

	/** Copies resolved typography onto this node's concrete layout payload. */
	public function applyTextStyle(style:ResolvedTextStyle):RenderNode {
		if (style == null)
			throw "Render text styles cannot be null";
		layout.textColor = style.textColor;
		layout.textStyle.font = style.textStyle.font;
		layout.textStyle.fontSize = style.textStyle.fontSize;
		layout.textStyle.letterSpacing = style.textStyle.letterSpacing;
		layout.paragraphStyle.wrap = style.paragraphStyle.wrap;
		layout.paragraphStyle.alignment = style.paragraphStyle.alignment;
		layout.paragraphStyle.lineHeight = style.paragraphStyle.lineHeight;
		layout.paragraphStyle.direction = style.paragraphStyle.direction;
		layout.paragraphStyle.tabWidth = style.paragraphStyle.tabWidth;
		return this;
	}

	public function on(kind:String, handler:UiEvent->Void, phase:String = "bubble"):RenderNode {
		if (kind == null || kind.length == 0 || handler == null ||
			(phase != "capture" && phase != "target" && phase != "bubble"))
			throw "Event handlers require a kind and callback";
		if (handlers == null)
			handlers = [];
		handlers.push(new HandlerEntry(kind, phase, handler));
		return this;
	}

	/** Primary pointer clicks and semantic activation (keyboard/accessibility).
	 * Other mouse buttons remain available to raw Click/context-menu handlers.
	 */
	public function onActivate(handler:UiEvent->Void, phase:String = "bubble"):RenderNode {
		if (handler == null) throw "Activation handlers require a callback";
		on(UiEventKind.Click, function(event) {
			if (event.button == 0) handler(event);
		}, phase);
		return on(UiEventKind.Activate, handler, phase);
	}

	/** Runs when a pointer press targets a node outside this node's subtree. */
	public function onPointerDownOutside(handler:UiEvent->Void):RenderNode {
		if (handler == null)
			throw "Outside pointer handlers require a callback";
		if (outsidePointerDownHandlers == null)
			outsidePointerDownHandlers = [];
		outsidePointerDownHandlers.push(handler);
		return this;
	}

	public function onResolved(handler:ResolvedLayoutItem->Void):RenderNode {
		if (handler == null)
			throw "Resolved geometry handlers cannot be null";
		if (resolvedHandlers == null)
			resolvedHandlers = [];
		resolvedHandlers.push(handler);
		return this;
	}

	/** Assigns this node's bounds to the native window-chrome hit-test map. */
	public function setWindowDecoration(kind:WindowDecorationRegionKind,
			?decorationCursor:CursorShape):RenderNode {
		if (kind == null)
			throw "Window decoration regions require a kind";
		windowDecoration = kind;
		windowDecorationCursor = decorationCursor;
		if (decorationCursor != null)
			cursor = decorationCursor;
		if (cursor == null)
			cursor = cursorForWindowDecoration(kind);
		return this;
	}

	static function cursorForWindowDecoration(kind:WindowDecorationRegionKind):CursorShape {
		return switch kind {
			// A drag region behaves like a native title bar: the platform owns
			// the move cursor during the active drag, not while hovering.
			case WindowDecorationRegionKind.Drag: CursorShape.Arrow;
			case WindowDecorationRegionKind.ResizeNorth | WindowDecorationRegionKind.ResizeSouth:
				CursorShape.VerticalResize;
			case WindowDecorationRegionKind.ResizeWest | WindowDecorationRegionKind.ResizeEast:
				CursorShape.HorizontalResize;
			case WindowDecorationRegionKind.ResizeNorthwest | WindowDecorationRegionKind.ResizeSoutheast:
				CursorShape.DiagonalResize;
			case WindowDecorationRegionKind.ResizeNortheast | WindowDecorationRegionKind.ResizeSouthwest:
				CursorShape.DiagonalResizeNesw;
			case WindowDecorationRegionKind.Client: CursorShape.Arrow;
			case _: CursorShape.Arrow;
		};
	}

	/**
	 * Adds a custom paint callback. The callback draws in node-local coordinates
	 * with (0, 0) at the node's top-left corner; native layout owns placement,
	 * transforms, and ancestor clipping. A cache key opts the callback into
	 * retained display-list reuse and must change whenever its local output can
	 * change for reasons other than size or computed style.
	 */
	public function onPaint(handler:Canvas->ResolvedLayoutItem->Void,
			?cacheKey:String):RenderNode {
		if (layout.visualKind != LayoutVisualKind.Custom)
			throw "Custom paint handlers require a Custom render node";
		if (handler == null)
			throw "Render paint handlers cannot be null";
		if (cacheKey != null && cacheKey.length == 0)
			throw "Render paint cache keys cannot be empty";
		if (paintHandlers == null) {
			paintHandlers = [];
			paintCacheKeys = [];
		}
		paintHandlers.push(handler);
		paintCacheKeys.push(cacheKey);
		basePaintKeyResolved = false;
		return this;
	}

	/**
	 * Adds a decoration. Supplying a cache key opts it into retained display
	 * list reuse; the key must include any external inputs read by the
	 * decoration that are not represented by computed style or geometry.
	 */
	public function addDecoration(decoration:Decoration, ?cacheKey:String):RenderNode {
		if (layout.visualKind != LayoutVisualKind.Custom)
			throw "Render decorations require a Custom render node";
		if (decoration == null)
			throw "Render decorations cannot be null";
		if (cacheKey != null && cacheKey.length == 0)
			throw "Render decoration cache keys cannot be empty";
		if (decorations == null) {
			decorations = [];
			decorationCacheKeys = [];
		}
		decorations.push(decoration);
		decorationCacheKeys.push(cacheKey);
		basePaintKeyResolved = false;
		return this;
	}

	@:allow(haxeon.ui.core.UiContext)
	function hasPaintHandler():Bool
		return paintHandlers != null || decorations != null || hasStyleDecorations();

	/** Normalize styled boxes before comparing or submitting native layout. */
	@:allow(haxeon.ui.core.UiContext)
	function syncPaintKind():Void {
		if (!hasPaintHandler() || layout.visualKind == LayoutVisualKind.Custom) return;
		if (layout.visualKind != LayoutVisualKind.Box)
			throw "Custom decorations require a Box or Custom render node (" + styleKey + ")";
		layout.visualKind = LayoutVisualKind.Custom;
	}

	/** Copies the framework hit policy into the native transaction payload. */
	@:allow(haxeon.ui.core.UiContext)
	function syncHitTestPolicy():Void {
		switch hitTestBehavior {
			case HitTestBehavior.None:
				layout.hitSelf = false;
				layout.hitChildren = false;
			case HitTestBehavior.SelfOnly:
				layout.hitSelf = hitTestSelf;
				layout.hitChildren = false;
			case HitTestBehavior.ChildrenOnly:
				layout.hitSelf = false;
				layout.hitChildren = true;
			case HitTestBehavior.Auto:
				layout.hitSelf = hitTestSelf;
				layout.hitChildren = true;
		}
	}

	/** Copies retained scene revisions into the native layout transaction payload. */
	@:allow(haxeon.ui.core.UiContext)
	function syncSceneRevisions():Void {
		layout.contentRevision = contentRevision;
		layout.geometryRevision = geometryRevision;
		layout.compositeRevision = compositeRevision;
	}

	/** Returns the complete opt-in fingerprint for safe retained paint reuse. */
	@:allow(haxeon.ui.core.UiContext)
	function retainedPaintKey():Null<String> {
		if (!hasPaintHandler()) return null;
		if (!basePaintKeyResolved) {
			basePaintKey = buildBasePaintKey();
			basePaintKeyResolved = true;
		}
		if (basePaintKey == null) return null;
		var style = computedStyle == null ? null : computedStyle.getReadOnly(StyleProperty.Decorations);
		var result = style != null && style.decorations.length > 0
			? basePaintKey + "|style-decorations:" + style.key() : basePaintKey;
		// Hover alone repaints this node without rebuilding it (BuildContext.hoverRebuilds), so the key says whether it was hovered.
		return recordsInteraction ? result + "|hover:" + (states & haxeon.ui.style.StyleState.Hovered) : result;
	}

	function buildBasePaintKey():Null<String> {
		var result = "paint";
		if (paintCacheKeys != null) for (key in paintCacheKeys) {
			if (key == null) return null;
			result += "|handler:" + key;
		}
		if (decorationCacheKeys != null) for (key in decorationCacheKeys) {
			if (key == null) return null;
			result += "|decoration:" + key;
		}
		return result;
	}

	/** Fingerprint for local compositor metadata; transforms are native placement. */
	@:allow(haxeon.ui.core.UiContext)
	function retainedCompositeKey():Null<String> {
		if (!hasCompositePaint())
			return null;
		var style = computedStyle == null ? new ComputedStyle() : computedStyle;
		var effects = style.getReadOnly(StyleProperty.Effects);
		var backdropEffects = style.getReadOnly(StyleProperty.BackdropEffects);
		var mask = style.getReadOnly(StyleProperty.Mask);
		var maskKey = mask == null ? "" : mask.describe();
		if (mask != null && mask.image != null)
			maskKey += ":image=" + mask.image.identity;
		return "opacity:" + Std.string(style.get(StyleProperty.Opacity)) +
			"|effects:" + (effects == null ? "" : effects.key()) +
			"|backdrop:" + (backdropEffects == null ? "" : backdropEffects.key()) +
			"|mask:" + maskKey;
	}

	@:allow(haxeon.ui.core.UiContext)
	function setResolved(item:Null<ResolvedLayoutItem>):Void {
		resolved = item;
		if (item != null && resolvedHandlers != null)
			for (handler in resolvedHandlers)
				handler(item);
	}

	@:allow(haxeon.ui.core.UiContext)
	function paintContent(canvas:Canvas):Bool {
		if (resolved == null || !resolved.visible || !hasPaintHandler())
			return false;
		var style = computedStyle;
		var styleDecorations = style == null ? null : style.getReadOnly(StyleProperty.Decorations);
		if (styleDecorations != null)
			for (decoration in styleDecorations.decorations)
				decoration.paint(canvas, resolved, style);
		if (decorations != null && decorations.length > 0) {
			var decorationStyle = style == null ? new ComputedStyle() : style;
			for (decoration in decorations)
				decoration.paint(canvas, resolved, decorationStyle);
		}
		if (paintHandlers != null)
			for (handler in paintHandlers)
				handler(canvas, resolved);
		return true;
	}

	@:allow(haxeon.ui.core.UiContext)
	function hasCompositePaint():Bool {
		if (computedStyle == null || resolved == null || !resolved.visible || !hasPaintHandler())
			return false;
		var style = computedStyle;
		var opacity = style.get(StyleProperty.Opacity);
		var effects = style.getReadOnly(StyleProperty.Effects);
		var hasEffects = effects != null && effects.effects.length > 0;
		var backdropEffects = style.getReadOnly(StyleProperty.BackdropEffects);
		var hasBackdropEffects = backdropEffects != null && backdropEffects.effects.length > 0;
		var mask = style.getReadOnly(StyleProperty.Mask);
		return opacity < 1.0 || hasEffects || hasBackdropEffects || mask != null;
	}

	/** Emits only the framework-owned layer metadata; it has no draw commands. */
	@:allow(haxeon.ui.core.UiContext)
	function paintComposite(canvas:Canvas):Bool {
		if (!hasCompositePaint())
			return false;
		var style = computedStyle == null ? new ComputedStyle() : computedStyle;
		var opacity = style.get(StyleProperty.Opacity);
		var effects = style.get(StyleProperty.Effects);
		var hasEffects = effects != null && effects.effects.length > 0;
		var backdropEffects = style.get(StyleProperty.BackdropEffects);
		var hasBackdropEffects = backdropEffects != null && backdropEffects.effects.length > 0;
		var mask = style.get(StyleProperty.Mask);
		canvas.beginLayer(opacity, CompositeMode.SourceOver, resolved.localBounds(),
			hasEffects ? effects : null, mask, hasBackdropEffects ? backdropEffects : null);
		canvas.endLayer();
		return true;
	}

	@:allow(haxeon.ui.core.UiContext)
	function paint(canvas:Canvas):Bool {
		if (!hasPaintHandler() || resolved == null || !resolved.visible)
			return false;
		if (hasCompositePaint()) {
			var content:Canvas->Void = function(target:Canvas) {
				paintContent(target);
			};
			var style = computedStyle == null ? new ComputedStyle() : computedStyle;
			var effects = style.get(StyleProperty.Effects);
			var backdropEffects = style.get(StyleProperty.BackdropEffects);
			var mask = style.get(StyleProperty.Mask);
			canvas.withLayer(style.get(StyleProperty.Opacity), content, CompositeMode.SourceOver,
				resolved.bounds(), effects != null && effects.effects.length > 0 ? effects : null,
				mask, backdropEffects != null && backdropEffects.effects.length > 0 ? backdropEffects : null);
		} else {
			paintContent(canvas);
		}
		return true;
	}

	function hasStyleDecorations():Bool {
		if (computedStyle == null)
			return false;
		var value = computedStyle.getReadOnly(StyleProperty.Decorations);
		return value != null && value.decorations.length > 0;
	}

	/**
	 * Carries retained-scene revisions across freshly built trees. The view
	 * layer still submits a complete layout transaction, but downstream work
	 * can now distinguish content, geometry, and composition changes.
	 */
	@:allow(haxeon.ui.debug.UiStyleInvalidationMetrics)
	function syncRevisions(previous:Null<RenderNode>, diff:StyleDiff):Void {
		if (previous == null) {
			invalidationFlags = UiDirtyFlag.NeedsBuild | UiDirtyFlag.NeedsStyle |
				UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsPaint |
				UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsSemantics | UiDirtyFlag.NeedsHitGeometry;
			return;
		}

		contentRevision = previous.contentRevision;
		geometryRevision = previous.geometryRevision;
		compositeRevision = previous.compositeRevision;
		invalidationFlags = UiDirtyFlag.None;
		var contentChanged = false;
		var geometryChanged = false;
		var compositeChanged = false;
		if (diff.changed) {
			invalidationFlags = UiDirtyFlag.NeedsStyle | UiDirtyFlag.fromStyleImpact(diff.impact);
			if ((diff.impact & (StyleImpact.Paint | StyleImpact.TextLayout)) != 0)
				contentChanged = true;
			if ((diff.impact & (StyleImpact.Layout | StyleImpact.TextLayout |
				StyleImpact.HitGeometry)) != 0)
				geometryChanged = true;
			if ((diff.impact & StyleImpact.Composite) != 0)
				compositeChanged = true;
		}

		var rawFlags = layoutInputDiffFlags(previous);
		invalidationFlags |= rawFlags;
		if ((rawFlags & (UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsTextLayout)) != 0)
			contentChanged = true;
		if ((rawFlags & (UiDirtyFlag.NeedsLayout | UiDirtyFlag.NeedsTextLayout |
			UiDirtyFlag.NeedsHitGeometry)) != 0)
			geometryChanged = true;
		if ((rawFlags & UiDirtyFlag.NeedsComposite) != 0)
			compositeChanged = true;

		// Text and external intrinsic content are not represented by computed
		// style, so classify them explicitly as both content and geometry.
		if (layout.visualKind != previous.layout.visualKind || layout.text != previous.layout.text ||
			layout.measureVersion != previous.layout.measureVersion ||
			layout.intrinsicContent != previous.layout.intrinsicContent) {
			contentChanged = true;
			geometryChanged = true;
			invalidationFlags |= UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsLayout |
				UiDirtyFlag.NeedsPaint;
		}

		if (hitTestSelf != previous.hitTestSelf || hitTestBehavior != previous.hitTestBehavior) {
			geometryChanged = true;
			invalidationFlags |= UiDirtyFlag.NeedsHitGeometry;
		}
		if (!Semantics.same(semantics, previous.semantics) || enabled != previous.enabled ||
			focusable != previous.focusable || focusTrap != previous.focusTrap ||
			tabIndex != previous.tabIndex)
			invalidationFlags |= UiDirtyFlag.NeedsSemantics;
		if (contentChanged)
			contentRevision++;
		if (geometryChanged)
			geometryRevision++;
		if (compositeChanged)
			compositeRevision++;
	}

	/** LayoutStyle fields by what a change to them invalidates; every field is in at least one (styleFieldsClassified). */
	static final StyleLayoutFields:Int = haxeon.Structural.fieldBit(LayoutStyle, "width") | haxeon.Structural.fieldBit(LayoutStyle, "height")
		| haxeon.Structural.fieldBit(LayoutStyle, "aspectRatio") | haxeon.Structural.fieldBit(LayoutStyle, "direction")
		| haxeon.Structural.fieldBit(LayoutStyle, "childAlignX") | haxeon.Structural.fieldBit(LayoutStyle, "childAlignY")
		| haxeon.Structural.fieldBit(LayoutStyle, "childDistribution") | haxeon.Structural.fieldBit(LayoutStyle, "positioning")
		| haxeon.Structural.fieldBit(LayoutStyle, "wrapMode") | haxeon.Structural.fieldBit(LayoutStyle, "rowGap")
		| haxeon.Structural.fieldBit(LayoutStyle, "columnGap") | haxeon.Structural.fieldBit(LayoutStyle, "alignSelf")
		| haxeon.Structural.fieldBit(LayoutStyle, "positionX") | haxeon.Structural.fieldBit(LayoutStyle, "positionY")
		| haxeon.Structural.fieldBit(LayoutStyle, "padding") | haxeon.Structural.fieldBit(LayoutStyle, "childGap");
	static final StyleHitFields:Int = haxeon.Structural.fieldBit(LayoutStyle, "zIndex") | haxeon.Structural.fieldBit(LayoutStyle, "clipToParent")
		| haxeon.Structural.fieldBit(LayoutStyle, "overlay") | haxeon.Structural.fieldBit(LayoutStyle, "clipHorizontal")
		| haxeon.Structural.fieldBit(LayoutStyle, "clipVertical") | haxeon.Structural.fieldBit(LayoutStyle, "visible");
	static final StylePaintFields:Int = StyleHitFields | haxeon.Structural.fieldBit(LayoutStyle, "background")
		| haxeon.Structural.fieldBit(LayoutStyle, "radiusTopLeft") | haxeon.Structural.fieldBit(LayoutStyle, "radiusTopRight")
		| haxeon.Structural.fieldBit(LayoutStyle, "radiusBottomRight") | haxeon.Structural.fieldBit(LayoutStyle, "radiusBottomLeft");
	static final StyleTransformFields:Int = haxeon.Structural.fieldBit(LayoutStyle, "transform")
		| haxeon.Structural.fieldBit(LayoutStyle, "transformOriginX") | haxeon.Structural.fieldBit(LayoutStyle, "transformOriginY");

	/** Whether every LayoutStyle field invalidates something when it changes: a new field must join a group above. */
	public static function styleFieldsClassified():Bool
		return (StyleLayoutFields | StylePaintFields | StyleHitFields | StyleTransformFields) == haxeon.Structural.allFieldsMask(LayoutStyle);

	/** Classifies concrete LayoutNode mutations that bypass computed styles. */
	function layoutInputDiffFlags(previous:RenderNode):Int {
		var before = previous.layout;
		var after = layout;
		var flags = 0;
		var beforeStyle = before.style;
		var afterStyle = layout.style;
		// Generated from LayoutStyle's fields (haxeon.Structural); styleFieldsClassified checks each is in a group below.
		var changed = beforeStyle == afterStyle ? 0 : haxeon.Structural.changedMask(beforeStyle, afterStyle);
		if ((changed & StyleLayoutFields) != 0)
			flags |= UiDirtyFlag.NeedsLayout;
		if ((changed & StylePaintFields) != 0 || !haxeon.Equality.equals(before.textColor, after.textColor))
			flags |= UiDirtyFlag.NeedsPaint;
		if ((changed & StyleHitFields) != 0)
			flags |= UiDirtyFlag.NeedsHitGeometry;
		if ((changed & StyleTransformFields) != 0)
			flags |= UiDirtyFlag.NeedsComposite | UiDirtyFlag.NeedsHitGeometry;
		if (!haxeon.Equality.equals(before.peekTextStyle(), after.peekTextStyle()) ||
			!haxeon.Equality.equals(before.peekParagraphStyle(), after.peekParagraphStyle()))
			flags |= UiDirtyFlag.NeedsTextLayout | UiDirtyFlag.NeedsPaint | UiDirtyFlag.NeedsLayout;
		return flags;
	}

	@:allow(haxeon.ui.core.EventDispatcher)
	function invoke(event:UiEvent):Void {
		if (event.phase == "target") {
			invokePhase(event, "target");
			if (!event.immediatePropagationStopped)
				invokePhase(event, "bubble");
		} else
			invokePhase(event, event.phase);
	}

	@:allow(haxeon.ui.core.EventDispatcher)
	function invokePointerDownOutside(event:UiEvent):Void {
		if (outsidePointerDownHandlers == null)
			return;
		for (handler in outsidePointerDownHandlers) {
			event.currentTarget = id;
			event.phase = "outside";
			handler(event);
			if (event.propagationStopped)
				return;
		}
	}

	function invokePhase(event:UiEvent, phase:String):Void {
		var entries = handlers;
		if (entries == null)
			return;
		// Handlers registered while one runs are visited too, as when each kind and phase had its own list.
		var index = 0;
		while (index < entries.length) {
			var entry = entries[index++];
			if (entry.phase != phase || entry.kind != event.kind)
				continue;
			entry.handler(event);
			if (event.immediatePropagationStopped)
				return;
		}
	}

	public function find(id:WidgetId):Null<RenderNode> {
		if (id == null)
			return null;
		return findFrom(this, id, ++findCounter);
	}

	/** Identifies one find() call, so a node reached twice (a cycle, or two parents) is searched once. */
	static var findCounter:Int = 0;
	var findStamp:Int = 0;

	/** Pre-order search that allocates nothing: each node carries the stamp of the last search that visited it. */
	static function findFrom(node:RenderNode, id:WidgetId, stamp:Int):Null<RenderNode> {
		if (node.findStamp == stamp)
			return null;
		node.findStamp = stamp;
		if (node.id.equals(id))
			return node;
		var children = node.children;
		for (index in 0...children.length) {
			var child = children[index];
			if (child == null)
				continue;
			var found = findFrom(child, id, stamp);
			if (found != null)
				return found;
		}
		return null;
	}

	public function walk(visit:RenderNode->Void):Void {
		visit(this);
		for (child in children)
			child.walk(visit);
	}

	function requireResolved():ResolvedLayoutItem {
		if (resolved == null)
			throw "Render node has no resolved geometry; submit the UI first";
		return cast resolved;
	}
}

/** What a builder made on a node, as taken by RenderNode.snapshotBuilt and kept up to date by RenderNode.reconcile. */
class BuiltNode {
	/** The style as the builder left it, before callers changed the node: the base of the next build's difference. */
	public final style:LayoutStyle;
	/** The children the builder made; others may have added more. */
	public final children:Array<RenderNode>;
	public var semantics:Null<Semantics>;
	/** How many of each list of callbacks the builder made; callers append theirs after. */
	public var handlers:Int = 0;
	public var outsidePointerDownHandlers:Int = 0;
	public var resolvedHandlers:Int = 0;
	public var paintHandlers:Int = 0;
	public var decorations:Int = 0;

	public function new(style:LayoutStyle, children:Array<RenderNode>, semantics:Null<Semantics>) {
		this.style = style;
		this.children = children;
		this.semantics = semantics;
	}
}

/** One event handler and the kind and phase it listens to; a node has few, so a flat list beats a map per node. */
private class HandlerEntry {
	public final kind:String;
	public final phase:String;
	public final handler:UiEvent->Void;

	public function new(kind:String, phase:String, handler:UiEvent->Void) {
		this.kind = kind;
		this.phase = phase;
		this.handler = handler;
	}
}

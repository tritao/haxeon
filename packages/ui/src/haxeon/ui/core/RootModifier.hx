package haxeon.ui.core;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.semantics.Semantics;

/**
 * What a caller adds to the root a view builds: layout placement, node flags, semantics, listeners and overlay children.
 * A caller never edits a component's root itself; it passes a modifier to `BuildContext.build`, and the framework applies
 * it after every run of the component's body, and takes it off again before the next one or when an equal description
 * keeps the body.
 */
class RootModifier {
	/** Replaces the root's width (`LayoutStyle.width`); null, like every field here, keeps what the body built. */
	public var width:Null<LayoutAxis> = null;

	/** Replaces the root's height (`LayoutStyle.height`). */
	public var height:Null<LayoutAxis> = null;

	/** Replaces how the root is placed: in its parent's flow or at an offset (`LayoutStyle.positioning`). */
	public var positioning:Null<LayoutPositioning> = null;

	/** Replaces the root's horizontal offset when it is positioned (`LayoutStyle.positionX`). */
	public var positionX:Null<Float> = null;

	/** Replaces the root's vertical offset when it is positioned (`LayoutStyle.positionY`). */
	public var positionY:Null<Float> = null;

	/** Replaces the root's stacking order among its siblings (`LayoutStyle.zIndex`). */
	public var zIndex:Null<Int> = null;

	/** Replaces whether the root is laid out and drawn (`LayoutStyle.visible`). */
	public var visible:Null<Bool> = null;

	/** Replaces whether the root's content is clipped to its parent (`LayoutStyle.clipToParent`). */
	public var clipToParent:Null<Bool> = null;

	/** Replaces the root's semantics. */
	public var semantics:Null<Semantics> = null;

	/** Replaces whether the root and its subtree take input (`RenderNode.enabled`). */
	public var enabled:Null<Bool> = null;

	/** Replaces whether the root can take keyboard focus (`RenderNode.focusable`). */
	public var focusable:Null<Bool> = null;

	/** Replaces whether the root itself is hit by pointer input, not only its children (`RenderNode.hitTestSelf`). */
	public var hitTestSelf:Null<Bool> = null;

	/** Replaces the root's place in keyboard focus order (`RenderNode.tabIndex`). */
	public var tabIndex:Null<Int> = null;

	/** Replaces the command scope the root's subtree resolves shortcuts in (`RenderNode.commandScope`). */
	public var commandScope:Null<String> = null;

	/** Replaces the pointer shape over the root (`RenderNode.cursor`). */
	public var cursor:Null<CursorShape> = null;

	final listeners:Array<ModifierListener> = [];
	final resolvedHandlers:Array<ResolvedLayoutItem->Void> = [];
	final overlays:Array<RenderNode> = [];

	/** A modifier that changes nothing until its fields are set or its methods called. */
	public function new() {}

	/** Adds a listener after the root's own, as `RenderNode.on` would. */
	public function on(kind:String, handler:UiEvent->Void, phase:UiEventPhase = UiEventPhase.Bubble):RootModifier {
		if (kind == null || kind.length == 0 || handler == null) throw "Modifier listeners require a kind and callback";
		listeners.push(new ModifierListener(kind, handler, phase));
		return this;
	}

	/** Calls `handler` each time layout places the root. */
	public function onResolved(handler:ResolvedLayoutItem->Void):RootModifier {
		if (handler == null) throw "Resolved geometry handlers cannot be null";
		resolvedHandlers.push(handler);
		return this;
	}

	/** Adds `child`, built by the caller in this pass, after the root's own children. */
	public function add(child:RenderNode):RootModifier {
		if (child == null) throw "A modifier child is required";
		overlays.push(child);
		return this;
	}

	@:allow(haxeon.ui.core.AppliedModifier) function listenerCount():Int return listeners.length;

	@:allow(haxeon.ui.core.AppliedModifier) function resolvedCount():Int return resolvedHandlers.length;

	@:allow(haxeon.ui.core.AppliedModifier) function overlayNodes():Array<RenderNode> return overlays;

	/** Applies this modifier to `root` and returns how to take it off again. */
	@:allow(haxeon.ui.core.BuildContext) @:allow(haxeon.ui.core
		.RenderScope) function apply(root:RenderNode):AppliedModifier {
		var applied = new AppliedModifier(this, root);
		var style = root.layout.style;
		if (width != null) style.width = width;
		if (height != null) style.height = height;
		if (positioning != null) style.positioning = positioning;
		if (positionX != null) style.positionX = positionX;
		if (positionY != null) style.positionY = positionY;
		if (zIndex != null) style.zIndex = zIndex;
		if (visible != null) style.visible = visible;
		if (clipToParent != null) style.clipToParent = clipToParent;
		if (semantics != null) root.semantics = semantics;
		if (enabled != null) root.enabled = enabled;
		if (focusable != null) root.focusable = focusable;
		if (hitTestSelf != null) root.hitTestSelf = hitTestSelf;
		if (tabIndex != null) root.tabIndex = tabIndex;
		if (commandScope != null) root.commandScope = commandScope;
		if (cursor != null) root.cursor = cursor;
		applied.handlerStart = root.handlerCount();
		for (listener in listeners) root.on(listener.kind, listener.handler, listener.phase);
		applied.resolvedStart = root.resolvedHandlerCount();
		for (handler in resolvedHandlers) root.onResolved(handler);
		for (child in overlays) root.add(child);
		return applied;
	}
}

/** What one application of a modifier changed on a root, and the values it replaced. */
class AppliedModifier {
	final modifier:RootModifier;
	final root:RenderNode;
	final width:LayoutAxis;
	final height:LayoutAxis;
	final positioning:LayoutPositioning;
	final positionX:Float;
	final positionY:Float;
	final zIndex:Int;
	final visible:Bool;
	final clipToParent:Bool;
	final semantics:Null<Semantics>;
	final enabled:Bool;
	final focusable:Bool;
	final hitTestSelf:Bool;
	final tabIndex:Int;
	final commandScope:Null<String>;
	final cursor:Null<CursorShape>;
	@:allow(haxeon.ui.core.RootModifier) var handlerStart = 0;
	@:allow(haxeon.ui.core.RootModifier) var resolvedStart = 0;

	@:allow(haxeon.ui.core.RootModifier) function new(modifier:RootModifier, root:RenderNode) {
		this.modifier = modifier;
		this.root = root;
		var style = root.layout.style;
		width = style.width;
		height = style.height;
		positioning = style.positioning;
		positionX = style.positionX;
		positionY = style.positionY;
		zIndex = style.zIndex;
		visible = style.visible;
		clipToParent = style.clipToParent;
		semantics = root.semantics;
		enabled = root.enabled;
		focusable = root.focusable;
		hitTestSelf = root.hitTestSelf;
		tabIndex = root.tabIndex;
		commandScope = root.commandScope;
		cursor = root.cursor;
	}

	/** Restores what the root's body built: the replaced values, without the listeners and children the modifier added. */
	@:allow(haxeon.ui.core.RenderScope) function remove():Void {
		var style = root.layout.style;
		if (modifier.width != null) style.width = width;
		if (modifier.height != null) style.height = height;
		if (modifier.positioning != null) style.positioning = positioning;
		if (modifier.positionX != null) style.positionX = positionX;
		if (modifier.positionY != null) style.positionY = positionY;
		if (modifier.zIndex != null) style.zIndex = zIndex;
		if (modifier.visible != null) style.visible = visible;
		if (modifier.clipToParent != null) style.clipToParent = clipToParent;
		if (modifier.semantics != null) root.semantics = semantics;
		if (modifier.enabled != null) root.enabled = enabled;
		if (modifier.focusable != null) root.focusable = focusable;
		if (modifier.hitTestSelf != null) root.hitTestSelf = hitTestSelf;
		if (modifier.tabIndex != null) root.tabIndex = tabIndex;
		if (modifier.commandScope != null) root.commandScope = commandScope;
		if (modifier.cursor != null) root.cursor = cursor;
		root.removeHandlers(handlerStart, modifier.listenerCount());
		root.removeResolvedHandlers(resolvedStart, modifier.resolvedCount());
		for (child in modifier.overlayNodes()) if (child.parent == root) child.detach();
	}
}

private class ModifierListener {
	public final kind:String;
	public final handler:UiEvent->Void;
	public final phase:UiEventPhase;

	public function new(kind:String, handler:UiEvent->Void, phase:UiEventPhase) {
		this.kind = kind;
		this.handler = handler;
		this.phase = phase;
	}
}

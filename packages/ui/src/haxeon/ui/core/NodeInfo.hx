package haxeon.ui.core;

import haxeon.ui.semantics.Semantics.AccessibilityRole;

/** A read-only look at one node of a built subtree (`ViewRoot.walk`): what it is, never a way to change it. */
abstract NodeInfo(RenderNode) {
	@:allow(haxeon.ui.core.ViewRoot) inline function new(node:RenderNode) this = node;

	/** The node's widget ID. */
	public var id(get, never):WidgetId;

	inline function get_id():WidgetId return this.id;

	/** Whether the node takes keyboard focus. */
	public var focusable(get, never):Bool;

	inline function get_focusable():Bool return this.focusable;

	/** Whether the node and its subtree take input. */
	public var enabled(get, never):Bool;

	inline function get_enabled():Bool return this.enabled;

	/** The widget type its style rules select on, such as "button". */
	public var styleType(get, never):Null<String>;

	inline function get_styleType():Null<String> return this.styleType;

	/** Its accessibility role, or null without semantics. */
	public var role(get, never):Null<AccessibilityRole>;

	inline function get_role():Null<AccessibilityRole> return this.semantics == null ? null : this.semantics.role;

	/** Whether it has the style class `name`. */
	public inline function hasStyleClass(name:String):Bool return this.styleClasses.indexOf(name) >= 0;
}

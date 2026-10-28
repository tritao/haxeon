package haxeon.ui.widgets.sidebar;

import haxeon.ui.core.View;

/** View-independent sidebar registration and validated persistent presentation. */
class SidebarModel {
	public final modes:Array<SidebarMode> = [];
	public var activeId(default, null):String = "";
	public var visible(default, null):Bool = true;
	public var onChange:Void->Void = function() {};
	var savedActive:String = "";
	var sequence:Int = 0;
	static final widthPattern = ~/^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$/;
	public var width(default, null):Float = 240;
	var savedVisible:Map<String, Bool> = [];
	/** The user's destination order, including saved ids that are not registered yet. Empty keeps the default order. */
	var savedOrder:Array<String> = [];
	var defaultOrder:SidebarMode->SidebarMode->Int = registrationOrder;
	/** True once the user has moved a destination; the saved order then overrides the default one. */
	public var customOrder(get, never):Bool;
	function get_customOrder():Bool return savedOrder.length > 0;
	public function new() {}

	public function register(id:String, provider:Void->View, options:SidebarModeOptions):Void {
		if (!validId(id) || provider == null || options == null || options.label.length == 0 ||
			find(id) != null) throw "Invalid or duplicate sidebar mode";
		var mode = new SidebarMode(id, provider, options, sequence++);
		if (savedVisible.exists(id)) mode.visible = savedVisible.get(id);
		modes.push(mode);
		arrange();
		if (mode.visible && (activeId == "" || savedActive == id)) activeId = id;
		onChange();
	}

	public function unregister(id:String):Bool {
		var mode = find(id);
		if (mode == null) return false;
		savedVisible.set(id, mode.visible);
		modes.remove(mode);
		var active = selected(); activeId = active == null ? "" : active.id; savedActive = activeId;
		onChange(); return true;
	}
	public function find(id:String):Null<SidebarMode> {
		for (mode in modes) if (mode.id == id) return mode;
		return null;
	}
	public function selected():Null<SidebarMode> {
		var active = find(activeId);
		if (active != null && active.visible) return active;
		for (mode in modes) if (mode.visible) return mode;
		return null;
	}
	public function select(id:String):Bool {
		var mode = find(id);
		if (mode == null || !mode.visible) return false;
		activeId = id; savedActive = id; visible = true; onChange(); return true;
	}
	public function setVisible(value:Bool):Void {
		if (visible == value) return;
		visible = value; onChange();
	}
	/** Container width is shared by every destination. Resolution records it without a rebuild. */
	public function rememberWidth(width:Float):Void {
		if (validWidth(width)) this.width = width;
	}
	public function setModeVisible(id:String, value:Bool):Bool {
		var mode = find(id);
		if (mode == null) return false;
		mode.visible = value; savedVisible.set(id, value);
		var selected = selected(); activeId = selected == null ? "" : selected.id; savedActive = activeId;
		onChange(); return true;
	}
	/** Move a destination before another one, or to the end when `before` is null. Returns false when nothing moved. */
	public function moveMode(id:String, before:Null<String>):Bool {
		var mode = find(id);
		if (mode == null || before == id) return false;
		var target = before == null ? null : find(before);
		if (before != null && target == null) return false;
		var from = modes.indexOf(mode);
		modes.remove(mode);
		var index = target == null ? modes.length : modes.indexOf(target);
		modes.insert(index, mode);
		if (index == from) return false;
		var order = [for (each in modes) each.id];
		for (saved in savedOrder) if (find(saved) == null) order.push(saved);
		savedOrder = order;
		onChange(); return true;
	}
	/** Replace the default order, such as a layout preset's; a user's saved order still wins. Does not notify. */
	public function setDefaultOrder(compare:SidebarMode->SidebarMode->Int):Void {
		defaultOrder = compare == null ? registrationOrder : compare;
		arrange();
	}
	/** Forget the user's order and return to the default one. */
	public function resetOrder():Bool {
		if (savedOrder.length == 0) return false;
		savedOrder = []; arrange(); onChange(); return true;
	}
	static function registrationOrder(a:SidebarMode, b:SidebarMode):Int
		return a.order == b.order ? a.sequence - b.sequence : a.order - b.order;
	/** Default order first; then the slots held by destinations with a saved place take them in saved order.
		Destinations without one, such as newly added ones, keep their default slots. */
	function arrange():Void {
		modes.sort(defaultOrder);
		if (savedOrder.length == 0) return;
		var slots:Array<Int> = [], placed:Array<SidebarMode> = [];
		for (i in 0...modes.length) if (savedOrder.indexOf(modes[i].id) >= 0) { slots.push(i); placed.push(modes[i]); }
		placed.sort(function(a, b) return savedOrder.indexOf(a.id) - savedOrder.indexOf(b.id));
		for (i in 0...slots.length) modes[slots[i]] = placed[i];
	}
	public function encode():String {
		return "3|" + (savedActive == "" ? activeId : savedActive) + "|" + (visible ? "1" : "0") + "|" + width + "|" + encodeShown() +
			"|" + savedOrder.join(",");
	}
	/** True when the user hid a destination or moved one, including destinations not registered now. */
	public var customDestinations(get, never):Bool;
	function get_customDestinations():Bool {
		if (savedOrder.length > 0) return true;
		for (mode in modes) if (!mode.visible) return true;
		for (id in savedVisible.keys()) if (find(id) == null && !savedVisible.get(id)) return true;
		return false;
	}
	/** The user's own destination choices alone, which destinations show and their order, without the selection, width
		or sidebar visibility; an application can keep them once for every window. */
	public function encodeDestinations():String return "1|" + encodeShown() + "|" + savedOrder.join(",");
	/** Apply choices from encodeDestinations, keeping the selection where it is still shown. Parses atomically. */
	public function restoreDestinations(value:String):Bool {
		if (value.length > 65536) return false;
		var parts = value.split("|");
		if (parts.length != 3 || parts[0] != "1") return false;
		var shown = parseShown(parts[1], false), order = parseOrder(parts[2]);
		if (shown == null || order == null) return false;
		savedVisible = shown; savedOrder = order;
		for (mode in modes) if (shown.exists(mode.id)) mode.visible = shown.get(mode.id);
		arrange();
		var active = selected(); activeId = active == null ? "" : active.id;
		onChange(); return true;
	}
	function encodeShown():String {
		var shown:Map<String, Bool> = [];
		for (id in savedVisible.keys()) shown.set(id, savedVisible.get(id));
		for (mode in modes) shown.set(mode.id, mode.visible);
		var values = [for (id in shown.keys()) id + "," + (shown.get(id) ? "1" : "0")];
		values.sort(Reflect.compare);
		return values.join(";");
	}
	/** `id,flag` rows separated by `;`, or null when malformed. */
	static function parseShown(rows:String, legacy:Bool):Null<Map<String, Bool>> {
		var shown:Map<String, Bool> = [];
		if (rows != "") for (row in rows.split(";")) {
			var fields = row.split(",");
			if (fields.length != (legacy ? 3 : 2) || !validId(fields[0]) || shown.exists(fields[0])) return null;
			var flag = fields[legacy ? 2 : 1];
			if (flag != "0" && flag != "1") return null;
			shown.set(fields[0], flag == "1");
		}
		return shown;
	}
	/** Comma-separated distinct ids, or null when malformed. */
	static function parseOrder(value:String):Null<Array<String>> {
		var order:Array<String> = [], seen:Map<String, Bool> = [];
		if (value != "") for (id in value.split(",")) {
			if (!validId(id) || seen.exists(id)) return null;
			seen.set(id, true); order.push(id);
		}
		return order;
	}
	/** Parse atomically. Legacy layouts migrate using the saved active destination's width; layouts before
		version 3 carry no order and restore the default one. */
	public function restore(value:String):Bool {
		if (value.length > 65536) return false;
		var parts = value.split("|");
		var legacy = parts[0] == "1";
		var expected = legacy ? 4 : parts[0] == "2" ? 5 : parts[0] == "3" ? 6 : -1;
		if (parts.length != expected ||
			(parts[1] != "" && !validId(parts[1])) || (parts[2] != "0" && parts[2] != "1")) return false;
		var nextWidth = width;
		if (!legacy) {
			if (!widthPattern.match(parts[3])) return false;
			nextWidth = Std.parseFloat(parts[3]);
			if (!validWidth(nextWidth)) return false;
		}
		var rows = parts[legacy ? 3 : 4];
		var shown = parseShown(rows, legacy);
		if (shown == null) return false;
		if (legacy && rows != "") for (row in rows.split(";")) {
			var fields = row.split(",");
			if (!widthPattern.match(fields[1])) return false;
			var oldWidth = Std.parseFloat(fields[1]);
			if (!validWidth(oldWidth)) return false;
			if (fields[0] == parts[1]) nextWidth = oldWidth;
		}
		var order = parts.length == 6 ? parseOrder(parts[5]) : [];
		if (order == null) return false;
		savedActive = parts[1]; savedVisible = shown; width = nextWidth; savedOrder = order;
		visible = parts[2] == "1";
		for (mode in modes) if (shown.exists(mode.id)) mode.visible = shown.get(mode.id);
		arrange();
		activeId = savedActive;
		var active = selected(); activeId = active == null ? "" : active.id;
		onChange(); return true;
	}
	static function validWidth(width:Float):Bool return (width == width && width - width == 0.0) && width >= 80.0 && width <= 4096.0;
	static function validId(id:String):Bool {
		if (id.length == 0 || id.length > 128) return false;
		for (i in 0...id.length) {
			var c = id.charCodeAt(i);
			if (!(c >= 97 && c <= 122 || c >= 65 && c <= 90 || c >= 48 && c <= 57 || c == 45 || c == 95)) return false;
		}
		return true;
	}
}

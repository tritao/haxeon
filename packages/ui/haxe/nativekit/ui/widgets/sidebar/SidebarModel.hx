package nativekit.ui.widgets.sidebar;

import nativekit.ui.core.View;

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
	public function new() {}

	public function register(id:String, provider:Void->View, options:SidebarModeOptions):Void {
		if (!validId(id) || provider == null || options == null || options.label.length == 0 ||
			find(id) != null) throw "Invalid or duplicate sidebar mode";
		var mode = new SidebarMode(id, provider, options, sequence++);
		if (savedVisible.exists(id)) mode.visible = savedVisible.get(id);
		modes.push(mode);
		modes.sort(function(a, b) return a.order == b.order ? a.sequence - b.sequence : a.order - b.order);
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
	public function encode():String {
		var shown:Map<String, Bool> = [];
		for (id in savedVisible.keys()) shown.set(id, savedVisible.get(id));
		for (mode in modes) shown.set(mode.id, mode.visible);
		var values = [for (id in shown.keys()) id + "," + (shown.get(id) ? "1" : "0")];
		values.sort(Reflect.compare);
		return "2|" + (savedActive == "" ? activeId : savedActive) + "|" + (visible ? "1" : "0") + "|" + width + "|" + values.join(";");
	}
	/** Parse atomically. Legacy layouts migrate using the saved active destination's width. */
	public function restore(value:String):Bool {
		if (value.length > 65536) return false;
		var parts = value.split("|");
		var legacy = parts[0] == "1";
		if ((legacy ? parts.length != 4 : parts.length != 5 || parts[0] != "2") ||
			(parts[1] != "" && !validId(parts[1])) || (parts[2] != "0" && parts[2] != "1")) return false;
		var nextWidth = width;
		if (!legacy) {
			if (!widthPattern.match(parts[3])) return false;
			nextWidth = Std.parseFloat(parts[3]);
			if (!validWidth(nextWidth)) return false;
		}
		var shown:Map<String, Bool> = [];
		var rows = parts[legacy ? 3 : 4];
		if (rows != "") for (row in rows.split(";")) {
			var fields = row.split(",");
			if (fields.length != (legacy ? 3 : 2) || !validId(fields[0]) || shown.exists(fields[0])) return false;
			var flag = fields[legacy ? 2 : 1];
			if (flag != "0" && flag != "1") return false;
			if (legacy) {
				if (!widthPattern.match(fields[1])) return false;
				var oldWidth = Std.parseFloat(fields[1]);
				if (!validWidth(oldWidth)) return false;
				if (fields[0] == parts[1]) nextWidth = oldWidth;
			}
			shown.set(fields[0], flag == "1");
		}
		savedActive = parts[1]; savedVisible = shown; width = nextWidth;
		visible = parts[2] == "1";
		for (mode in modes) if (shown.exists(mode.id)) mode.visible = shown.get(mode.id);
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

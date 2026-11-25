package haxeon.ui.host;

import haxeon.platform.event.EventPump;
import haxeon.platform.event.PlatformEvent;

import haxe.Json;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import sys.io.File;

/** Timed, window-local logical input through the normal managed event pump.
    Times are seconds after the first content-ready frame; coordinates are window logical pixels.
    A key event presses and releases NativeKit key code `key` with `modifiers` held (NativeKit bits, default none); a
    text event types `text` as one text input per code point, as a keyboard layout would.
    Touch (phone UI): `{"type":"touch","action":"begin"|"move"|"end"|"cancel","x","y","id":0}` is one touch event;
    `{"type":"tap","x","y"}` is begin and end 60 ms apart; `{"type":"drag","x","y","dx","dy","ms":200}` is begin at
    (x,y), moves every 16 ms, end at (x+dx,y+dy) after `ms` (a short `ms` makes a fling); `{"type":"back"}` is the system
    Back request (`backHandler`); `{"type":"resize","width","height"}` sets the window's logical size (fold, unfold).
    `type` is an alias of `kind` for every event.
    Delayed events retain their original deadlines, so overload remains measurable. */
class ScriptedInput {
	/** Where a `back` event goes: the application sets it to `UiHostContext.handleBack`. */
	public static var backHandler:Null<Void->Bool> = null;

	static inline var TAP_SECONDS = 0.06;
	static inline var DRAG_STEP_SECONDS = 0.016;

	final events:Array<Dynamic>;
	var index = 0;
	var origin = -1.0;
	public var scheduledAt(default, null) = -1.0;
	public var delivered(default, null) = 0;
	public var complete(get, never):Bool;
	function get_complete():Bool return index == events.length;

	public function new(path:String) {
		var script:Dynamic = Json.parse(File.getContent(path));
		if (script.version != 1 || !Std.isOfType(script.events, Array)) throw "Invalid input script version/events";
		var source:Array<Dynamic> = cast script.events;
		if (source.length == 0) throw "Input script cannot be empty";
		var previous = -1.0;
		var expanded:Array<{at:Float, order:Int, event:Dynamic}> = [];
		for (event in source) {
			var at:Float = event.at;
			if (event.at == null || !Math.isFinite(at) || at < 0 || at < previous)
				throw "Input script times must be finite, nonnegative and ordered";
			previous = at;
			if (event.kind == null && event.type != null) event.kind = event.type;
			validate(event);
			for (part in expand(event, at)) expanded.push({at: part.at, order: expanded.length, event: part.event});
		}
		// A drag's moves can pass the next event's time: deliver in time order, keeping the script's order for ties.
		expanded.sort(function(a, b) return a.at < b.at ? -1 : a.at > b.at ? 1 : a.order - b.order);
		events = [for (item in expanded) item.event];
	}

	static function validate(event:Dynamic):Void {
		switch (Std.string(event.kind)) {
			case "move", "down", "up":
				if (event.x == null || event.y == null || !Math.isFinite(event.x) || !Math.isFinite(event.y))
					throw "Pointer events require finite x/y";
			case "scroll":
				if (event.dx == null || event.dy == null || !Math.isFinite(event.dx) || !Math.isFinite(event.dy))
					throw "Scroll events require finite dx/dy";
			case "key":
				if (event.key == null || !Std.isOfType(event.key, Int)) throw "Key events require an integer key";
				if (event.modifiers != null
					&& !Std.isOfType(event.modifiers, Int)) throw "Key modifiers must be an integer";
			case "text":
				if (!Std.isOfType(event.text, String) || (event.text:String).length == 0)
					throw "Text events require non-empty text";
			case "checkpoint":
				if (event.label == null) throw "Checkpoint requires a label";
			case "touch":
				if (event.x == null || event.y == null || !Math.isFinite(event.x) || !Math.isFinite(event.y))
					throw "Touch events require finite x/y";
				var action = Std.string(event.action);
				if (action != "begin" && action != "move" && action != "end" && action != "cancel")
					throw "Touch action must be begin, move, end or cancel";
				if (event.id != null && !Std.isOfType(event.id, Int)) throw "Touch id must be an integer";
			case "tap":
				if (event.x == null || event.y == null || !Math.isFinite(event.x) || !Math.isFinite(event.y))
					throw "Tap events require finite x/y";
			case "drag":
				if (event.x == null || event.y == null || event.dx == null || event.dy == null
					|| !Math.isFinite(event.x) || !Math.isFinite(event.y) || !Math.isFinite(event.dx)
					|| !Math.isFinite(event.dy))
					throw "Drag events require finite x/y/dx/dy";
				if (event.ms != null && (!Math.isFinite(event.ms) || event.ms <= 0)) throw "Drag ms must be positive";
			case "back":
			case "resize":
				if (event.width == null || event.height == null || !Math.isFinite(event.width)
					|| !Math.isFinite(event.height)
					|| event.width <= 0 || event.height <= 0) throw "Resize events require positive width/height";
			case _: throw "Unsupported scripted input kind: " + event.kind;
		}
	}

	static function touch(at:Float, action:String, x:Float, y:Float, id:Int):{at:Float, event:Dynamic} {
		return {at: at, event: {at: at, kind: "touch", action: action, x: x, y: y, id: id}};
	}

	/** A tap or drag becomes the touch events it is made of; any other event stays as it is. */
	static function expand(event:Dynamic, at:Float):Array<{at:Float, event:Dynamic}> {
		var id:Int = event.id == null ? 0 : event.id;
		switch (Std.string(event.kind)) {
			case "tap":
				return [touch(at, "begin", event.x, event.y, id), touch(at + TAP_SECONDS, "end", event.x, event.y, id)];
			case "drag":
				var ms:Float = event.ms == null ? 200.0 : event.ms;
				var x:Float = event.x, y:Float = event.y, dx:Float = event.dx, dy:Float = event.dy;
				var result = [touch(at, "begin", x, y, id)];
				var step = 1;
				while (step * DRAG_STEP_SECONDS * 1000.0 < ms) {
					var fraction = step * DRAG_STEP_SECONDS * 1000.0 / ms;
					result.push(touch(at + step * DRAG_STEP_SECONDS, "move", x + dx * fraction, y + dy * fraction, id));
					step++;
				}
				result.push(touch(at + ms / 1000.0, "end", x + dx, y + dy, id));
				return result;
			case _:
				return [{at: at, event: event}];
		}
	}

	public function start(now:Float):Void {
		if (origin < 0) origin = now;
	}

	/** Null means no deadline is armed. Overdue input must not put the host to sleep. */
	public function secondsUntilNext(now:Float):Null<Float> {
		return origin < 0 || complete ? null : Math.max(0.0, deadline(index) - now);
	}

	/** Typed so the scheduling arithmetic is not Dynamic. The script's times were validated as finite when it loaded. */
	function deadline(position:Int):Float {
		var at:Float = events[position].at;
		return origin + at;
	}

	/** Dispatch one due event; the host drains overdue input before requesting the next frame. */
	public function tick(now:Float, pump:EventPump, window:WindowHandle,
			checkpoint:String->Void, before:Float->Void, after:Float->Void):Bool {
		if (origin < 0 || complete || now < deadline(index)) return false;
		scheduledAt = deadline(index);
		var event = events[index++];
		if (event.kind == "checkpoint") {
			checkpoint(event.label);
			return true;
		}
		if (event.kind == "back") {
			before(scheduledAt);
			var backStarted = Sys.time();
			var handler = backHandler;
			if (handler != null) handler();
			after(Sys.time() - backStarted);
			delivered++;
			return true;
		}
		if (event.kind == "resize") {
			before(scheduledAt);
			var resizeStarted = Sys.time();
			resize(window, Std.int(event.width), Std.int(event.height));
			after(Sys.time() - resizeStarted);
			delivered++;
			return true;
		}
		var source = new Handle(window.rawValue());
		var values:Array<PlatformEvent> = switch (Std.string(event.kind)) {
			case "move": [PointerMove(source, event.x, event.y)];
			case "down", "up": [PointerButton(source, NativeKitTypes.PointerButton.Left,
				event.kind == "down" ? InputAction.Press : InputAction.Release, NativeKitTypes.Modifiers.empty(),
				event.x, event.y)];
			case "scroll": [PointerScroll(source, event.dx, event.dy)];
			case "touch":
				var action = switch (Std.string(event.action)) {
					case "begin": NativeKitTypes.TouchAction.Begin;
					case "move": NativeKitTypes.TouchAction.Move;
					case "end": NativeKitTypes.TouchAction.End;
					case _: NativeKitTypes.TouchAction.Cancel;
				};
				var id:Int = event.id == null ? 0 : event.id;
				var pressure:Float = event.action == "end" || event.action == "cancel" ? 0.0 : 1.0;
				[PlatformEvent.Touch(source, id, action, NativeKitTypes.TouchTool.Finger,
					NativeKitTypes.Modifiers.empty(),
					event.x, event.y, pressure, 0.0, 0.0)];
			case "key":
				var key:Int = event.key, modifiers:Int = event.modifiers == null ? 0 : event.modifiers;
				var nativeKey = NativeKitTypes.NativeKitTypesEnumDecoders.decodeKey(key);
				[
					Key(source, nativeKey, 0, InputAction.Press, NativeKitTypes.Modifiers.fromRaw(modifiers)),
					Key(source, nativeKey, 0, InputAction.Release, NativeKitTypes.Modifiers.fromRaw(modifiers))
				];
			case "text": [for (codepoint in codepoints(event.text)) TextInput(source, codepoint)];
			case _: throw "Invalid scripted event";
		};
		before(scheduledAt);
		var started = Sys.time();
		for (value in values) pump.dispatch(value);
		after(Sys.time() - started);
		delivered++;
		return true;
	}

	/** Sets the window's logical size, keeping its position; the surface-resize event follows through the pump. */
	static function resize(window:WindowHandle, width:Int, height:Int):Void {
		var position = NativeKit.nk_window_get_position(window);
		if (position.status != NativeKitTypes.Result.Ok)
			throw "Window position query failed: " + NativeKit.nk_last_error();
		if (NativeKit.nk_window_set_bounds(window, position.out_x, position.out_y, width, height)
			!= NativeKitTypes.Result.Ok)
			throw "Scripted resize failed: " + NativeKit.nk_last_error();
	}

	static function codepoints(text:String):Array<Int> {
		var result = [];
		var i = 0;
		while (i < text.length) {
			var unit = StringTools.fastCodeAt(text, i++);
			if (unit >= 0xD800 && unit < 0xDC00 && i < text.length) {
				var low = StringTools.fastCodeAt(text, i);
				if (low >= 0xDC00 && low < 0xE000) {
					unit = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
					i++;
				}
			}
			result.push(unit);
		}
		return result;
	}
}

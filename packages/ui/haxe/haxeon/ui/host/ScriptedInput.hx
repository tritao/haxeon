package haxeon.ui.host;

import haxe.Json;
import sys.io.File;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitEventValue;
import nativekit.ffi.NativeKitTypes;

/** Timed, window-local logical input through the normal managed event pump.
    Times are seconds after the first content-ready frame; coordinates are window logical pixels.
    A key event presses and releases NativeKit key code `key` with `modifiers` held (NativeKit bits, default none); a
    text event types `text` as one text input per code point, as a keyboard layout would.
    Delayed events retain their original deadlines, so overload remains measurable. */
class ScriptedInput {
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
    events = cast script.events;
    if (events.length == 0) throw "Input script cannot be empty";
    var previous = -1.0;
    for (event in events) {
      var at:Float = event.at;
      if (event.at == null || !Math.isFinite(at) || at < 0 || at < previous)
        throw "Input script times must be finite, nonnegative and ordered";
      previous = at;
      switch (Std.string(event.kind)) {
        case "move", "down", "up":
          if (event.x == null || event.y == null || !Math.isFinite(event.x) || !Math.isFinite(event.y))
            throw "Pointer events require finite x/y";
        case "scroll":
          if (event.dx == null || event.dy == null || !Math.isFinite(event.dx) || !Math.isFinite(event.dy))
            throw "Scroll events require finite dx/dy";
        case "key":
          if (event.key == null || !Std.isOfType(event.key, Int)) throw "Key events require an integer key";
          if (event.modifiers != null && !Std.isOfType(event.modifiers, Int)) throw "Key modifiers must be an integer";
        case "text":
          if (!Std.isOfType(event.text, String) || (event.text : String).length == 0)
            throw "Text events require non-empty text";
        case "checkpoint":
          if (event.label == null) throw "Checkpoint requires a label";
        case _: throw "Unsupported scripted input kind: " + event.kind;
      }
    }
  }

  public function start(now:Float):Void { if (origin < 0) origin = now; }

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
  public function tick(now:Float, pump:NativeKitEvents, window:WindowHandle,
      checkpoint:String->Void, before:Float->Void, after:Float->Void):Bool {
    if (origin < 0 || complete || now < deadline(index)) return false;
    scheduledAt = deadline(index);
    var event = events[index++];
    if (event.kind == "checkpoint") { checkpoint(event.label); return true; }
    var source = new Handle(window.rawValue());
    var values:Array<NativeKitEventValue> = switch (Std.string(event.kind)) {
      case "move": [PointerMove(source, event.x, event.y)];
      case "down", "up": [PointerButton(source, cast 0,
        event.kind == "down" ? InputAction.Press : InputAction.Release, cast 0, event.x, event.y)];
      case "scroll": [PointerScroll(source, event.dx, event.dy)];
      case "key":
        var key:Int = event.key, modifiers:Int = event.modifiers == null ? 0 : event.modifiers;
        [Key(source, cast key, 0, InputAction.Press, cast modifiers), Key(source, cast key, 0, InputAction.Release, cast modifiers)];
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

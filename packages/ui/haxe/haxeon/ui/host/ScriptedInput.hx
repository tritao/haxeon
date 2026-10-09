package haxeon.ui.host;

import haxe.Json;
import sys.io.File;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitEventValue;
import nativekit.ffi.NativeKitTypes;

/** Timed, window-local logical input through the normal managed event pump.
    Times are seconds after the first content-ready frame; coordinates are window logical pixels.
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
        case "checkpoint":
          if (event.label == null) throw "Checkpoint requires a label";
        case _: throw "Unsupported scripted input kind: " + event.kind;
      }
    }
  }

  public function start(now:Float):Void { if (origin < 0) origin = now; }

  /** Null means no deadline is armed. Overdue input must not put the host to sleep. */
  public function secondsUntilNext(now:Float):Null<Float> {
    return origin < 0 || complete ? null : Math.max(0.0, origin + events[index].at - now);
  }

  /** Dispatch one due event; the host drains overdue input before requesting the next frame. */
  public function tick(now:Float, pump:NativeKitEvents, window:WindowHandle,
      checkpoint:String->Void, before:Float->Void, after:Float->Void):Bool {
    if (origin < 0 || complete || now < origin + events[index].at) return false;
    var event = events[index++];
    scheduledAt = origin + event.at;
    if (event.kind == "checkpoint") { checkpoint(event.label); return true; }
    var source = new Handle(window.rawValue());
    var value:NativeKitEventValue = switch (Std.string(event.kind)) {
      case "move": PointerMove(source, event.x, event.y);
      case "down", "up": PointerButton(source, cast 0,
        event.kind == "down" ? InputAction.Press : InputAction.Release, cast 0, event.x, event.y);
      case "scroll": PointerScroll(source, event.dx, event.dy);
      case _: throw "Invalid scripted event";
    };
    before(scheduledAt);
    var started = Sys.time();
    pump.dispatch(value);
    after(Sys.time() - started);
    delivered++;
    return true;
  }
}

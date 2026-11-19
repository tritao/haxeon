package haxeon.ui.gestures;

import haxeon.ui.core.RenderNode;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.WidgetId;
import haxeon.ui.gestures.DragRecognizer;
import haxeon.ui.gestures.GestureEvent;
import haxeon.ui.gestures.GestureKind;
import haxeon.ui.gestures.GestureRecognizer;
import haxeon.ui.gestures.PinchRecognizer;
import haxeon.ui.gestures.SwipeRecognizer;
import haxeon.ui.gestures.VelocityTracker;

private class GestureSequence {
	public final target:WidgetId;
	public final pointerId:Int;
	public final startX:Float;
	public final startY:Float;
	public final recognizers:Array<GestureRecognizer>;
	public var x:Float;
	public var y:Float;
	public var elapsed:Float;
	public var moved:Bool;
	public var longPressed:Bool;
	public var dragging:Bool;
	/** Set while this pointer takes part in a pinch, or after one ended: no tap, drag or swipe follows. */
	public var suppressed:Bool;
	public var pinch:Null<PinchState>;
	public final tracker:VelocityTracker;

	public function new(target:WidgetId, event:UiEvent, recognizers:Array<GestureRecognizer>) {
		this.target = target;
		pointerId = event.pointerId;
		startX = x = event.x;
		startY = y = event.y;
		this.recognizers = recognizers.copy();
		elapsed = 0.0;
		moved = false;
		longPressed = false;
		dragging = false;
		suppressed = false;
		pinch = null;
		tracker = new VelocityTracker();
		tracker.add(Sys.time(), event.x, event.y);
	}
}

private class PinchState {
	public final first:GestureSequence;
	public final second:GestureSequence;
	public final recognizers:Array<PinchRecognizer>;
	public final startDistance:Float;
	public final startFocusX:Float;
	public final startFocusY:Float;
	public var scale:Float;
	public var focusX:Float;
	public var focusY:Float;

	public function new(first:GestureSequence, second:GestureSequence, recognizers:Array<PinchRecognizer>,
			startDistance:Float) {
		this.first = first;
		this.second = second;
		this.recognizers = recognizers;
		this.startDistance = startDistance;
		startFocusX = focusX = (first.x + second.x) * 0.5;
		startFocusY = focusY = (first.y + second.y) * 0.5;
		scale = 1.0;
	}
}

private class LastTap {
	public final target:WidgetId;
	public final x:Float;
	public final y:Float;
	public final time:Float;

	public function new(target:WidgetId, x:Float, y:Float, time:Float) {
		this.target = target;
		this.x = x;
		this.y = y;
		this.time = time;
	}
}

/** Frame-ticked Haxe gesture arena shared by rebuilt GestureDetector views. */
class GestureArena {
	final active:Map<Int, GestureSequence>;
	final lastTaps:Map<Int, LastTap>;
	var elapsedSeconds:Float;
	public var revision(default, null):Int;

	public function new() {
		active = new Map();
		lastTaps = new Map();
		elapsedSeconds = 0.0;
		revision = 0;
	}

	/** Monotonic UI time accumulated from submitted frame deltas. */
	public function timeSeconds():Float
		return elapsedSeconds;

	public function pointerDown(target:WidgetId, event:UiEvent,
			recognizers:Array<GestureRecognizer>):Void {
		if (target == null || event == null || recognizers == null)
			return;
		var sequence = new GestureSequence(target, event, recognizers);
		active.set(event.pointerId, sequence);
		tryBeginPinch(sequence);
		revision++;
	}

	/** Drops in-flight recognizers whose keyed detector left the rebuilt tree. */
	public function setRoot(root:Null<RenderNode>):Void {
		if (active.size() == 0)
			return;
		var stale:Array<Int> = [];
		for (pointerId in active.keys()) {
			var sequence = active.get(pointerId);
			if (root == null || sequence == null || root.find(sequence.target) == null)
				stale.push(pointerId);
		}
		for (pointerId in stale) {
			var dropped = active.get(pointerId);
			if (dropped != null)
				endPinch(dropped);
			active.remove(pointerId);
			revision++;
		}
	}

	public function pointerMove(event:UiEvent):Void {
		var sequence = active.get(event.pointerId);
		if (sequence == null)
			return;
		revision++;
		sequence.x = event.x;
		sequence.y = event.y;
		sequence.tracker.add(Sys.time(), event.x, event.y);
		if (sequence.pinch != null) {
			updatePinch(sequence.pinch);
			return;
		}
		if (sequence.suppressed)
			return;
		var dx = event.x - sequence.startX;
		var dy = event.y - sequence.startY;
		var distanceSquared = dx * dx + dy * dy;
		var movementTolerance = 8.0;
		for (recognizer in sequence.recognizers)
			if ((recognizer.kind == GestureKind.Tap || recognizer.kind == GestureKind.LongPress)
				&& recognizer.threshold < movementTolerance)
				movementTolerance = recognizer.threshold;
		if (distanceSquared > movementTolerance * movementTolerance)
			sequence.moved = true;
		for (recognizer in sequence.recognizers) {
			if (recognizer.kind != GestureKind.Drag || distanceSquared <= recognizer.threshold * recognizer.threshold)
				continue;
			var drag:DragRecognizer = cast recognizer;
			if (!sequence.dragging) {
				sequence.dragging = true;
				if (drag.hasStart)
					drag.onStart(makeEvent(GestureKind.DragStart, sequence, dx, dy));
			}
			if (drag.hasMove)
				drag.onMove(makeEvent(GestureKind.Drag, sequence, dx, dy));
		}
	}

	public function pointerUp(event:UiEvent):Void {
		var sequence = active.get(event.pointerId);
		active.remove(event.pointerId);
		if (sequence == null)
			return;
		sequence.x = event.x;
		sequence.y = event.y;
		if (sequence.pinch != null) {
			endPinch(sequence);
			return;
		}
		if (sequence.suppressed)
			return;
		var dx = event.x - sequence.startX;
		var dy = event.y - sequence.startY;
		sequence.tracker.add(Sys.time(), event.x, event.y);
		sequence.tracker.compute(Sys.time());
		var velocityX = sequence.tracker.velocityX;
		var velocityY = sequence.tracker.velocityY;
		for (recognizer in sequence.recognizers)
			if (recognizer.kind == GestureKind.Swipe && recognizer.hasHandler) {
				var swipe:SwipeRecognizer = cast recognizer;
				var absVelocityX = Math.abs(velocityX);
				if (Math.abs(dx) > swipe.threshold && absVelocityX > swipe.minVelocity
					&& absVelocityX > Math.abs(velocityY))
					swipe.onRecognized(makeEvent(GestureKind.Swipe, sequence, dx, dy, velocityX, velocityY,
						dx < 0.0 ? SwipeRecognizer.Left : SwipeRecognizer.Right));
			}
		if (sequence.dragging) {
			sequence.dragging = false;
			endDrag(sequence, dx, dy, velocityX, velocityY);
			return;
		}
		if (sequence.longPressed || sequence.moved)
			return;
		var last = lastTaps.get(event.pointerId);
		for (recognizer in sequence.recognizers)
			if (recognizer.kind == GestureKind.DoubleTap && last != null && last.target.equals(sequence.target)
				&& elapsedSeconds - last.time <= recognizer.interval) {
				var tapDx = event.x - last.x;
				var tapDy = event.y - last.y;
				if (tapDx * tapDx + tapDy * tapDy <= recognizer.threshold * recognizer.threshold) {
					if (recognizer.hasHandler)
						recognizer.onRecognized(makeEvent(GestureKind.DoubleTap, sequence, 0.0, 0.0));
				}
			}
		for (recognizer in sequence.recognizers)
			if (recognizer.kind == GestureKind.Tap && recognizer.hasHandler)
				recognizer.onRecognized(makeEvent(GestureKind.Tap, sequence, 0.0, 0.0));
		lastTaps.set(event.pointerId, new LastTap(sequence.target, event.x, event.y, elapsedSeconds));
	}

	public function pointerCancel(pointerId:Int):Void {
		var sequence = active.get(pointerId);
		if (sequence != null)
			endPinch(sequence);
		if (active.remove(pointerId))
			revision++;
	}

	/** Advances gesture timers by the current frame's non-negative delta time. */
	public function advance(deltaSeconds:Float):Void {
		if (!finite(deltaSeconds) || deltaSeconds < 0.0)
			throw "Gesture time must be finite and non-negative";
		var hadActive = active.size() > 0;
		elapsedSeconds += deltaSeconds;
		if (hadActive) for (sequence in active) {
			sequence.elapsed += deltaSeconds;
			if (sequence.longPressed || sequence.moved)
				continue;
			for (recognizer in sequence.recognizers)
				if (recognizer.kind == GestureKind.LongPress && sequence.elapsed >= recognizer.interval) {
					sequence.longPressed = true;
					if (recognizer.hasHandler)
						recognizer.onRecognized(makeEvent(GestureKind.LongPress, sequence, 0.0, 0.0));
				}
		}
		if (hadActive)
			revision++;
	}

	public function cancelAll():Void {
		if (active.size() > 0 || lastTaps.size() > 0) {
			for (sequence in active)
				endPinch(sequence);
			active.clear();
			lastTaps.clear();
			revision++;
		}
	}

	function makeEvent(kind:Int, sequence:GestureSequence, deltaX:Float, deltaY:Float, velocityX:Float = 0.0,
			velocityY:Float = 0.0, direction:Int = 0):GestureEvent
		return new GestureEvent(kind, sequence.target, sequence.pointerId, sequence.startX,
			sequence.startY, sequence.x, sequence.y, deltaX, deltaY, sequence.elapsed, velocityX, velocityY, 1.0, 0.0,
			0.0, direction);

	function endDrag(sequence:GestureSequence, dx:Float, dy:Float, velocityX:Float, velocityY:Float):Void {
		for (recognizer in sequence.recognizers)
			if (recognizer.kind == GestureKind.Drag) {
				var drag:DragRecognizer = cast recognizer;
				drag.setVelocity(velocityX, velocityY);
				if (drag.hasEnd)
					drag.onEnd(makeEvent(GestureKind.DragEnd, sequence, dx, dy, velocityX, velocityY));
			}
	}

	function pinchRecognizers(sequence:GestureSequence):Array<PinchRecognizer> {
		var result:Array<PinchRecognizer> = [];
		for (recognizer in sequence.recognizers)
			if (recognizer.kind == GestureKind.Pinch)
				result.push(cast recognizer);
		return result;
	}

	/** A second pointer pressed on the same detector as a free one starts a pinch between the two. */
	function tryBeginPinch(sequence:GestureSequence):Void {
		var recognizers = pinchRecognizers(sequence);
		if (recognizers.length == 0)
			return;
		for (other in active) {
			if (other == sequence || other.pinch != null || other.suppressed || !other.target.equals(sequence.target))
				continue;
			var dx = sequence.x - other.x;
			var dy = sequence.y - other.y;
			var distance = Math.sqrt(dx * dx + dy * dy);
			if (distance < 1.0)
				continue;
			if (other.dragging) {
				other.dragging = false;
				endDrag(other, other.x - other.startX, other.y - other.startY, 0.0, 0.0);
			}
			var state = new PinchState(other, sequence, recognizers, distance);
			other.pinch = state;
			sequence.pinch = state;
			other.suppressed = true;
			sequence.suppressed = true;
			other.moved = true;
			sequence.moved = true;
			for (recognizer in recognizers)
				if (recognizer.hasBegin)
					recognizer.onBegin(makePinchEvent(GestureKind.PinchStart, state));
			return;
		}
	}

	function updatePinch(state:PinchState):Void {
		var dx = state.second.x - state.first.x;
		var dy = state.second.y - state.first.y;
		state.scale = Math.sqrt(dx * dx + dy * dy) / state.startDistance;
		state.focusX = (state.first.x + state.second.x) * 0.5;
		state.focusY = (state.first.y + state.second.y) * 0.5;
		for (recognizer in state.recognizers)
			if (recognizer.hasUpdate)
				recognizer.onUpdate(makePinchEvent(GestureKind.PinchUpdate, state));
	}

	/** Ends the pinch this sequence belongs to, if any; the other pointer stays suppressed until it lifts. */
	function endPinch(sequence:GestureSequence):Void {
		var state = sequence.pinch;
		if (state == null)
			return;
		state.first.pinch = null;
		state.second.pinch = null;
		for (recognizer in state.recognizers)
			if (recognizer.hasEnd)
				recognizer.onEnd(makePinchEvent(GestureKind.PinchEnd, state));
	}

	function makePinchEvent(kind:Int, state:PinchState):GestureEvent
		return new GestureEvent(kind, state.first.target, state.first.pointerId, state.startFocusX,
			state.startFocusY, state.focusX, state.focusY, state.focusX - state.startFocusX,
			state.focusY - state.startFocusY, state.first.elapsed, 0.0, 0.0, state.scale, state.focusX, state.focusY, 0);

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

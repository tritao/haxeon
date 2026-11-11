package haxeon.ui;

import runtime.memory.Arena;
import runtime.memory.NativeSpan;
import runtime.memory.NativeSpanOwner;
import runtime.memory.RawPtr;

/** Session-owned slots in native memory. Handles are an index and a generation. */
@:noCompletion
class PaintStore implements NativeSpanOwner implements Disposable {
	static inline final Live = 1;
	static inline final Dirty = 2;
	final arena:Arena;
	var records:RawPtr<PaintRecord>;
	var bytes:NativeSpan<UInt8>;
	var capacity:Int = 0;
	var count:Int = 0;
	var freeHead:Int = -1;
	var closed:Bool = false;

	public function new() {
		arena = new Arena();
		records = RawPtr.nullPtr();
		var empty:RawPtr<UInt8> = RawPtr.nullPtr();
		bytes = new NativeSpan<UInt8>(empty, 0, this);
	}

	/** Create a dirty slot; the caller retains its index and `generation(index)`. */
	public function acquire():Int {
		ensureOpen();
		var index:Int;
		if (freeHead >= 0) {
			index = freeHead;
			var slot = records.offset(index);
			freeHead = -slot.ref.flags - 2;
			slot.ref.flags = Live | Dirty;
		} else {
			if (count == capacity) grow();
			index = count++;
			var slot = records.offset(index);
			slot.ref.generation = 1;
			slot.ref.flags = Live | Dirty;
		}
		var slot = records.offset(index);
		slot.ref.backgroundRed = 0.0;
		slot.ref.backgroundGreen = 0.0;
		slot.ref.backgroundBlue = 0.0;
		slot.ref.backgroundAlpha = 0.0;
		slot.ref.radiusTopLeft = 0.0;
		slot.ref.radiusTopRight = 0.0;
		slot.ref.radiusBottomLeft = 0.0;
		slot.ref.radiusBottomRight = 0.0;
		slot.ref.textRed = 1.0;
		slot.ref.textGreen = 1.0;
		slot.ref.textBlue = 1.0;
		slot.ref.textAlpha = 1.0;
		return index;
	}

	public function generation(index:Int):Int {
		ensureOpen();
		if (index < 0 || index >= count || records.offset(index).ref.flags < 0 ||
			(records.offset(index).ref.flags & Live) == 0)
			throw "Paint slot is not live";
		return records.offset(index).ref.generation;
	}

	public function at(index:Int, generation:Int):RawPtr<PaintRecord> {
		ensureOpen();
		if (index < 0 || index >= count) throw "Paint handle is out of range";
		var slot = records.offset(index);
		if (slot.ref.flags < 0 || (slot.ref.flags & Live) == 0 || slot.ref.generation != generation)
			throw "Paint handle is stale";
		return slot;
	}

	public function setBackground(index:Int, generation:Int, red:Float, green:Float, blue:Float, alpha:Float):Void {
		var slot = at(index, generation);
		if (sameFloat(slot.ref.backgroundRed, red) && sameFloat(slot.ref.backgroundGreen, green) &&
			sameFloat(slot.ref.backgroundBlue, blue) && sameFloat(slot.ref.backgroundAlpha, alpha)) return;
		slot.ref.backgroundRed = red; slot.ref.backgroundGreen = green;
		slot.ref.backgroundBlue = blue; slot.ref.backgroundAlpha = alpha;
		slot.ref.flags |= Dirty;
	}

	public function setRadii(index:Int, generation:Int, topLeft:Float, topRight:Float, bottomLeft:Float, bottomRight:Float):Void {
		var slot = at(index, generation);
		if (sameFloat(slot.ref.radiusTopLeft, topLeft) && sameFloat(slot.ref.radiusTopRight, topRight) &&
			sameFloat(slot.ref.radiusBottomLeft, bottomLeft) && sameFloat(slot.ref.radiusBottomRight, bottomRight)) return;
		slot.ref.radiusTopLeft = topLeft; slot.ref.radiusTopRight = topRight;
		slot.ref.radiusBottomLeft = bottomLeft; slot.ref.radiusBottomRight = bottomRight;
		slot.ref.flags |= Dirty;
	}

	public function setTextColor(index:Int, generation:Int, red:Float, green:Float, blue:Float, alpha:Float):Void {
		var slot = at(index, generation);
		if (sameFloat(slot.ref.textRed, red) && sameFloat(slot.ref.textGreen, green) &&
			sameFloat(slot.ref.textBlue, blue) && sameFloat(slot.ref.textAlpha, alpha)) return;
		slot.ref.textRed = red; slot.ref.textGreen = green; slot.ref.textBlue = blue; slot.ref.textAlpha = alpha;
		slot.ref.flags |= Dirty;
	}

	public function isDirty(index:Int, generation:Int):Bool
		return (at(index, generation).ref.flags & Dirty) != 0;

	/** A failed native submission leaves the record dirty. */
	public function acknowledge(index:Int, generation:Int):Void {
		var slot = at(index, generation);
		slot.ref.flags = Live;
	}

	public function release(index:Int, generation:Int):Void {
		var slot = at(index, generation);
		if (generation == 0x7fffffff) throw "Paint slot generation exhausted";
		slot.ref.generation = generation + 1;
		// A vacant slot is negative so it cannot be mistaken for a live flag word.
		slot.ref.flags = -freeHead - 2;
		freeHead = index;
	}

	/** The backing bytes stay live until growth or disposal; native must not retain them across either. */
	public function span():NativeSpan<UInt8> {
		ensureOpen();
		return bytes;
	}

	public function dispose():Void {
		if (closed) return;
		closed = true;
		arena.dispose();
	}

	public function isClosed():Bool return closed;

	public static inline function sameFloat(left:Float, right:Float):Bool
		return left == right && (left != 0.0 || 1.0 / left == 1.0 / right);

	function grow():Void {
		var next = capacity == 0 ? 16 : capacity * 2;
		if (next <= capacity || next > Std.int(0x7fffffff / sizeof<PaintRecord>()))
			throw "Paint store capacity exceeded";
		var replacement:RawPtr<PaintRecord> = arena.alloc(next);
		for (index in 0...count) replacement.offset(index).store(records.offset(index).load());
		for (index in count...next) {
			var slot = replacement.offset(index);
			slot.ref.generation = 0;
			slot.ref.flags = 0;
		}
		records = replacement;
		capacity = next;
		var data:RawPtr<UInt8> = records.castTo();
		bytes = new NativeSpan<UInt8>(data, next * sizeof<PaintRecord>(), this);
	}

	function ensureOpen():Void {
		if (closed) throw "Paint store is closed";
	}
}

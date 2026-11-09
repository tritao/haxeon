package haxeon.io;

import haxe.io.Bytes;
import haxe.io.Output;

/**
 * An immutable byte string kept as a list of segments. A module of a hundred megabytes is mostly the encodings of its functions, which
 * a cache already holds; a segment list refers to those instead of copying them into one buffer. `writeTo` streams the segments,
 * `flatten` makes the single buffer for the rare consumer that needs one. A segment's bytes must never be changed after they are
 * handed to a `ByteSink` as shared, because several byte strings may refer to them.
 */
final class SegmentedBytes {
	public static final EMPTY = new SegmentedBytes([], [], 0);

	/** Total length in bytes. */
	public final length:Int;

	final segments:Array<Bytes>;
	final lengths:Array<Int>;

	/** Made by `ByteSink.finish`; `lengths[i]` is how much of `segments[i]` belongs to the string (a chunk may be only partly filled). */
	public function new(segments:Array<Bytes>, lengths:Array<Int>, length:Int) {
		this.segments = segments;
		this.lengths = lengths;
		this.length = length;
	}

	public static function ofBytes(bytes:Bytes):SegmentedBytes
		return bytes.length == 0 ? EMPTY : new SegmentedBytes([bytes], [bytes.length], bytes.length);

	public var segmentCount(get, never):Int;

	function get_segmentCount():Int
		return segments.length;

	/** The buffer of a segment; only its first `segmentLength(index)` bytes belong to the string. Never change it. */
	public function segmentBytes(index:Int):Bytes
		return segments[index];

	public function segmentLength(index:Int):Int
		return lengths[index];

	/** Writes every segment to `output`, in order. */
	public function writeTo(output:Output):Void {
		for (index in 0...segments.length)
			output.writeBytes(segments[index], 0, lengths[index]);
	}

	/** The bytes as one buffer: the segment itself when there is exactly one that is whole, else a new exactly sized buffer. */
	public function flatten():Bytes {
		if (segments.length == 1 && lengths[0] == segments[0].length)
			return segments[0];
		var result = Bytes.alloc(length), offset = 0;
		for (index in 0...segments.length) {
			result.blit(offset, segments[index], 0, lengths[index]);
			offset += lengths[index];
		}
		return result;
	}

	/** Whether both hold the same bytes, whatever their segmentation. */
	public function equals(other:SegmentedBytes):Bool {
		if (other == this)
			return true;
		if (other.length != length)
			return false;
		var leftIndex = 0, leftOffset = 0, rightIndex = 0, rightOffset = 0, remaining = length;
		while (remaining > 0) {
			while (leftOffset == lengths[leftIndex]) {
				leftIndex++;
				leftOffset = 0;
			}
			while (rightOffset == other.lengths[rightIndex]) {
				rightIndex++;
				rightOffset = 0;
			}
			var take = lengths[leftIndex] - leftOffset, rightTake = other.lengths[rightIndex] - rightOffset;
			if (rightTake < take)
				take = rightTake;
			if (!sameRange(segments[leftIndex], leftOffset, other.segments[rightIndex], rightOffset, take))
				return false;
			leftOffset += take;
			rightOffset += take;
			remaining -= take;
		}
		return true;
	}

	static function sameRange(left:Bytes, leftOffset:Int, right:Bytes, rightOffset:Int, count:Int):Bool {
		for (index in 0...count)
			if (left.get(leftOffset + index) != right.get(rightOffset + index))
				return false;
		return true;
	}
}

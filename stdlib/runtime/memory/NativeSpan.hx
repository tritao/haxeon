package runtime.memory;

/** A NativeSpan's storage: the borrowed base address, its element count, and its owner. */
class NativeSpanView {
	public final base:hl.Bytes;
	public final length:Int;
	public final owner:Null<NativeSpanOwner>;

	public function new(base:hl.Bytes, length:Int, owner:Null<NativeSpanOwner>) {
		if (length < 0)
			throw "Native span length must not be negative";
		if (length > 0 && (cast base : RawPtr<Int>).isNull())
			throw "Native span with elements needs an address";
		this.base = base;
		this.length = length;
		this.owner = owner;
	}

	/** Whether the memory may still be read: there is no owner, or it is not closed. */
	public function isOpen():Bool {
		var current = owner;
		return current == null || !current.isClosed();
	}

	/** Throws unless `index` names an element of this view and its memory may still be read. */
	public function check(index:Int):Void {
		if (index < 0 || index >= length)
			throw 'Native span index $index is out of bounds for length $length';
		if (!isOpen())
			throw "Native span's owner is closed";
	}

	/** Throws when this view already has an owner other than `owner`. */
	public function checkOwner(owner:NativeSpanOwner):Void {
		if (owner == null)
			throw "Native span owner is required";
		var current = this.owner;
		if (current != null && current != owner)
			throw "Native span already has another owner";
	}

	/** Throws unless `start` and `count` select a run of this view and its memory may still be read. */
	public function checkRange(start:Int, count:Int):Void {
		if (start < 0 || count < 0 || start > length || count > length - start)
			throw 'Native span range $start+$count is out of bounds for length $length';
		if (!isOpen())
			throw "Native span's owner is closed";
	}
}

/**
	A borrowed, read-only view of `length()` consecutive fixed-layout values in
	native memory: a pointer and a count, with no copy. Reads are bounds-checked
	and, when the span has an owner, refused once that owner is closed. The
	memory belongs to native code; a span never frees it and does not keep it
	alive beyond its owner.

	`get` reads scalar and pointer elements. Native records are address-only:
	use `at` for an element's address. FFI functions declared with
	`@span("count_symbol")` return spans, and functions with `@in_array`
	parameters have a `_span` companion that passes spans to native code
	without copying.
**/
abstract NativeSpan<T>(NativeSpanView) {
	/** Borrows `length` values at `data`, readable while `owner` (when given) is open. */
	public inline function new(data:RawPtr<T>, length:Int, ?owner:NativeSpanOwner)
		this = new NativeSpanView(data, length, owner);

	/** The number of elements. */
	public inline function length():Int
		return (cast this : NativeSpanView).length;

	/** Whether the elements may still be read. */
	public inline function isOpen():Bool
		return (cast this : NativeSpanView).isOpen();

	/** The element at `index`. */
	public inline function get(index:Int):T
		return at(index).load();

	/** The address of the element at `index`; valid while the span is open. */
	public inline function at(index:Int):RawPtr<T> {
		var view:NativeSpanView = cast this;
		view.check(index);
		var base:RawPtr<T> = view.base;
		return base.offset(index);
	}

	/** The address of the first element, unchecked; valid while the span is open. */
	public inline function data():RawPtr<T> {
		var view:NativeSpanView = cast this;
		var base:RawPtr<T> = view.base;
		return base;
	}

	/** The `count` elements from `start`, borrowing from the same owner. */
	public inline function slice(start:Int, count:Int):NativeSpan<T> {
		var view:NativeSpanView = cast this;
		view.checkRange(start, count);
		var base:RawPtr<T> = view.base;
		return new NativeSpan<T>(count == 0 ? base : base.offset(start), count, view.owner);
	}

	/** The span, readable only while `owner` is open. A span that already has another owner keeps it and throws. */
	public inline function ownedBy(owner:NativeSpanOwner):NativeSpan<T> {
		var view:NativeSpanView = cast this;
		view.checkOwner(owner);
		var base:RawPtr<T> = view.base;
		return new NativeSpan<T>(base, view.length, owner);
	}

	/** Copies the elements into a new array. */
	public inline function toArray():Array<T> {
		var view:NativeSpanView = cast this;
		view.checkRange(0, view.length);
		var base:RawPtr<T> = view.base;
		return [for (index in 0...view.length) base.offset(index).load()];
	}
}

package haxeon.reactive;

/** One lazily allocated dependency source shared by every observable field on an object. */
class ObservableSource extends ReactiveSource {
	final fieldLimit:Int;

	/** The source of an object with `fieldCount` observable fields, numbered from 0. */
	public function new(fieldCount:Int) {
		super();
		fieldLimit = fieldCount;
	}

	/** Records that the running tracked computation read the field `fieldBit`. */
	public function recordFieldRead(fieldBit:Int):Void
		ReactiveRuntime.trackField(this, fieldBit);

	/** Invalidates the computations that read the field `fieldBit`. Throws for a field outside the object's. */
	public function invalidateField(fieldBit:Int):Void {
		checkRange(fieldBit);
		if (!hasFieldReaders(fieldBit))
			return;
		invalidateFieldReaders(fieldBit);
	}

	@:allow(haxeon.reactive.ReactiveDependencySet)
	override function checkFieldBit(fieldBit:Int):Void checkRange(fieldBit);

	public override function versionAt(fieldBit:Int):Int {
		checkRange(fieldBit);
		// An edge starts at zero; invalidateFieldReaders marks only matching edges as
		// stale until their readers finish tracking. No shared counter is required.
		return 0;
	}

	function checkRange(fieldBit:Int):Void
		if (fieldBit < 0 || fieldBit >= fieldLimit)
			throw 'Observable field bit $fieldBit is outside 0...${fieldLimit - 1}';
}

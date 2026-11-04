package haxeon.reactive;

/** One lazily allocated dependency source shared by every observable field on an object. */
class ObservableSource extends ReactiveSource {
	final fieldLimit:Int;
	public function new(fieldCount:Int) {
		super(fieldCount);
		fieldLimit = fieldCount;
	}

	public function recordFieldRead(fieldBit:Int):Void
		ReactiveRuntime.trackField(this, fieldBit);

	public function invalidateField(fieldBit:Int):Void {
		checkRange(fieldBit);
		if (!hasFieldReaders(fieldBit))
			return;
		invalidateFieldReaders(fieldBit);
	}

	public override function dependencyId(fieldBit:Int):haxe.Int64 {
		checkRange(fieldBit);
		return reactiveId + haxe.Int64.ofInt(fieldBit);
	}

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

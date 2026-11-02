package haxeon.ui.core;

/** One lazily allocated dependency source shared by every observable field on an object. */
class ObservableSource extends ReactiveSource {
	final fieldLimit:Int;
	var fieldVersions:Null<Array<Int>>;

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
		var versions = ensureField(fieldBit);
		versions[fieldBit] = versions[fieldBit] == 0x7fffffff ? 1 : versions[fieldBit] + 1;
		invalidateFieldReaders(fieldBit);
	}

	public override function dependencyId(fieldBit:Int):Int {
		checkRange(fieldBit);
		return reactiveId + fieldBit;
	}

	public override function versionAt(fieldBit:Int):Int {
		checkRange(fieldBit);
		var versions = fieldVersions;
		return versions != null && fieldBit < versions.length ? versions[fieldBit] : 0;
	}

	function ensureField(fieldBit:Int):Array<Int> {
		var versions = fieldVersions;
		if (versions == null) {
			versions = [];
			fieldVersions = versions;
		}
		while (versions.length <= fieldBit)
			versions.push(0);
		return versions;
	}

	function checkRange(fieldBit:Int):Void
		if (fieldBit < 0 || fieldBit >= fieldLimit)
			throw 'Observable field bit $fieldBit is outside 0...${fieldLimit - 1}';
}

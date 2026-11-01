package haxeon.ui.core;

/**
 * A retained computation's signal subscriptions plus the explicit polling reads still used by plain model fields.
 * Frame-local instances collect reads; retained instances subscribe and become dirty on writes.
 */
class Dependencies extends ReactiveDependencySet {
	static final NoIntReads:Array<Void->Int> = [];
	static final NoIntValues:Array<Int> = [];
	static final NoBoolReads:Array<Void->Bool> = [];
	static final NoBoolValues:Array<Bool> = [];
	static final NoStringReads:Array<Void->Null<String>> = [];
	static final NoStringValues:Array<Null<String>> = [];
	var invalidationContext:Null<BuildContext>;
	var invalidationBuild:Null<SelfUpdatingBuild>;
	var invalidationBuildId:Int = 0;
	var validatedEpoch:Int = -1;
	var validatedCurrent:Bool = false;
	@:allow(haxeon.ui.core.BuildContext)
	public var rootPollEpoch:Int = 0;
	@:allow(haxeon.ui.core.BuildContext)
	public var rootPollIndex:Int = -1;
	var intReads:Array<Void->Int> = NoIntReads;
	var intValues:Array<Int> = NoIntValues;
	var boolReads:Array<Void->Bool> = NoBoolReads;
	var boolValues:Array<Bool> = NoBoolValues;
	var stringReads:Array<Void->Null<String>> = NoStringReads;
	var stringValues:Array<Null<String>> = NoStringValues;

	public function new(captureOnly:Bool = false) {
		super(captureOnly);
	}

	override public function get_dirty():Bool return !current();

	public function setInvalidationOwner(context:Null<BuildContext>, build:Null<SelfUpdatingBuild>):Void {
		var buildId = build == null ? 0 : build.idValue;
		if (invalidationContext != context || invalidationBuildId != buildId)
			validatedEpoch = -1;
		invalidationContext = context;
		invalidationBuild = build;
		invalidationBuildId = buildId;
	}

	public var intCount(get, never):Int;
	inline function get_intCount():Int return intReads.length;
	public var boolCount(get, never):Int;
	inline function get_boolCount():Int return boolReads.length;
	public var stringCount(get, never):Int;
	inline function get_stringCount():Int return stringReads.length;

	public function hasPlainReads():Bool
		return intReads.length != 0 || boolReads.length != 0 || stringReads.length != 0;
	public var signalCount(get, never):Int;
	inline function get_signalCount():Int return dependencyCount();

	public function addInt(read:Void->Int, value:Int):Void {
		if (intReads == NoIntReads) { intReads = []; intValues = []; }
		intReads.push(read);
		intValues.push(value);
	}

	public function addBool(read:Void->Bool, value:Bool):Void {
		if (boolReads == NoBoolReads) { boolReads = []; boolValues = []; }
		boolReads.push(read);
		boolValues.push(value);
	}

	public function addString(read:Void->Null<String>, value:Null<String>):Void {
		if (stringReads == NoStringReads) { stringReads = []; stringValues = []; }
		stringReads.push(read);
		stringValues.push(value);
	}

	/** Appends reads of a retained child to the frame capture. */
	public function addAll(other:Dependencies):Void {
		if (other == this) return;
		other.appendDependenciesTo(this);
		for (index in 0...other.intReads.length) addInt(other.intReads[index], other.intValues[index]);
		for (index in 0...other.boolReads.length) addBool(other.boolReads[index], other.boolValues[index]);
		for (index in 0...other.stringReads.length) addString(other.stringReads[index], other.stringValues[index]);
	}

	/** Copies one frame-local slice into this retained record, reusing its arrays and subscriptions. */
	public function replaceSlice(source:Dependencies, signalMark:Int, intMark:Int, boolMark:Int, stringMark:Int):Void {
		if (captureOnly || source == this)
			throw "A retained dependency record needs a separate frame capture";
		validatedEpoch = -1;
		beginDependencies();
		var signalStart = bounded(signalMark, source.pendingCount());
		for (index in signalStart...source.pendingCount())
			track(source.pendingSourceAt(index));
		copyIntSlice(source, intMark);
		copyBoolSlice(source, boolMark);
		copyStringSlice(source, stringMark);
		finishDependencies();
	}

	/** Replaces signal subscriptions without copying temporary legacy plain-field reads. */
	public function replaceSignals(source:Dependencies, signalMark:Int):Void {
		if (captureOnly || source == this)
			throw "A retained dependency record needs a separate frame capture";
		beginDependencies();
		var signalStart = bounded(signalMark, source.pendingCount());
		for (index in signalStart...source.pendingCount())
			track(source.pendingSourceAt(index));
		finishDependencies();
	}

	function copyIntSlice(source:Dependencies, mark:Int):Void {
		if (intReads == NoIntReads) { intReads = []; intValues = []; } else { intReads.resize(0); intValues.resize(0); }
		for (index in bounded(mark, source.intReads.length)...source.intReads.length) {
			intReads.push(source.intReads[index]); intValues.push(source.intValues[index]);
		}
	}

	function copyBoolSlice(source:Dependencies, mark:Int):Void {
		if (boolReads == NoBoolReads) { boolReads = []; boolValues = []; } else { boolReads.resize(0); boolValues.resize(0); }
		for (index in bounded(mark, source.boolReads.length)...source.boolReads.length) {
			boolReads.push(source.boolReads[index]); boolValues.push(source.boolValues[index]);
		}
	}

	function copyStringSlice(source:Dependencies, mark:Int):Void {
		if (stringReads == NoStringReads) { stringReads = []; stringValues = []; } else { stringReads.resize(0); stringValues.resize(0); }
		for (index in bounded(mark, source.stringReads.length)...source.stringReads.length) {
			stringReads.push(source.stringReads[index]); stringValues.push(source.stringValues[index]);
		}
	}

	static inline function bounded(mark:Int, length:Int):Int
		return mark < 0 ? 0 : mark > length ? length : mark;

	/** Whether tracked sources and explicit reads remain current. */
	public function current():Bool {
		if (super.get_dirty()) return false;
		var context = invalidationContext;
		if (context != null && validatedEpoch == context.dependencyValidationEpoch)
			return validatedCurrent;
		for (index in 0...intReads.length)
			if (intReads[index]() != intValues[index]) { markDirty(); return false; }
		for (index in 0...boolReads.length)
			if (boolReads[index]() != boolValues[index]) { markDirty(); return false; }
		for (index in 0...stringReads.length)
			if (stringReads[index]() != stringValues[index]) { markDirty(); return false; }
		if (context != null) {
			validatedEpoch = context.dependencyValidationEpoch;
			validatedCurrent = true;
		}
		return true;
	}

	/** Validates only reactive sources; legacy plain reads are polled at their retained root boundary. */
	public function trackedSourcesDirty():Bool
		return super.get_dirty();

	override public function ensureCurrent():Void {
		current();
	}

	override public function onMaybeStale():Void {
		var context = invalidationContext;
		var build = invalidationBuild;
		if (context != null && build != null && build.root != null)
			context.requestReactivePatch(build.root.id);
	}

	override public function onInvalidated():Void {
		ReactiveRuntime.changed();
		var context = invalidationContext;
		var build = invalidationBuild;
		if (context != null && build != null && build.root != null)
			context.requestReactivePatch(build.root.id);
	}

	public function truncate(signalMark:Int, intMark:Int, boolMark:Int, stringMark:Int):Void {
		if (captureOnly) truncatePending(signalMark);
		intReads.resize(bounded(intMark, intReads.length));
		intValues.resize(intReads.length);
		boolReads.resize(bounded(boolMark, boolReads.length));
		boolValues.resize(boolReads.length);
		stringReads.resize(bounded(stringMark, stringReads.length));
		stringValues.resize(stringReads.length);
	}

	public function clear():Void {
		if (captureOnly) clearPending();
		intReads.resize(0); intValues.resize(0);
		boolReads.resize(0); boolValues.resize(0);
		stringReads.resize(0); stringValues.resize(0);
	}

	/** Unsubscribe retained readers and release the plain-field closures they captured. */
	public function dispose():Void {
		clearDependencies();
		clear();
		invalidationContext = null;
		invalidationBuild = null;
		invalidationBuildId = 0;
		validatedEpoch = -1;
	}
}

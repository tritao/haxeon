package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.types.Type.CompilerType;
import compiler.types.Type.MonomorphCell;
import compiler.types.analysis.ClosureConversion.ClosureConversionMark;

/** The type variables one function body made, and what it added that may mention them. */
class MonomorphFrame {
	public final cells:Array<MonomorphCell> = [];

	/** Where the closure conversion stood when the body began: what comes after is the body's lambdas and cells. */
	public final conversionMark:ClosureConversionMark;

	/** The lambda cache entries the body made, which hold its lambdas' types. */
	public final lambdaKeys:Array<String> = [];

	/** Checks that need a type variable's type, run when the body is typed and they are filled. */
	public final deferred:Array<Void->Void> = [];

	public function new(conversionMark:ClosureConversionMark)
		this.conversionMark = conversionMark;
}

/**
 * The type variables (`Monomorphs`) of the function bodies being typed, innermost last. A body begins a frame; the type
 * variables made while it is typed, its lambdas' included, belong to it, and are settled when it ends.
 */
class MonomorphFrames {
	final frames:Array<MonomorphFrame> = [];

	public function new() {}

	public function begin(conversionMark:ClosureConversionMark):MonomorphFrame {
		var frame = new MonomorphFrame(conversionMark);
		frames.push(frame);
		return frame;
	}

	/** Ends `frame`, and any frame left open inside it by a body whose typing failed. */
	public function end(frame:MonomorphFrame):Void {
		var index = frames.indexOf(frame);
		if (index >= 0)
			frames.splice(index, frames.length - index);
	}

	/**
	 * A new type variable standing for `origin` (`the type of local "x"`), or null where no body is being typed (a field
	 * initializer, a generated helper), which has no frame to settle one.
	 */
	public function create(origin:String, span:SourceSpan):Null<CompilerType> {
		var frame = frames.length == 0 ? null : frames[frames.length - 1];
		if (frame == null)
			return null;
		var cell = new MonomorphCell(origin, span);
		frame.cells.push(cell);
		return TMonomorph(cell);
	}

	/** Whether a body is being typed, which can settle the type variables made in it. */
	public function canCreate():Bool
		return frames.length > 0;

	/** Whether the innermost body has made a type variable: only then can a type it meets mention one. */
	public function active():Bool
		return frames.length > 0 && frames[frames.length - 1].cells.length > 0;

	/**
	 * Runs `check` once the types it needs are known: now when `type` mentions no empty type variable, otherwise when the
	 * innermost body has been typed (and the variable filled, or reported).
	 */
	public function whenKnown(type:CompilerType, check:Void->Void):Void {
		if (frames.length == 0 || !compiler.types.Monomorphs.containsUnbound(type))
			check();
		else
			frames[frames.length - 1].deferred.push(check);
	}

	/** Notes a lambda cache entry the innermost body made, so its types are settled with the body's. */
	public function recordLambda(key:String):Void
		if (frames.length > 0)
			frames[frames.length - 1].lambdaKeys.push(key);
}

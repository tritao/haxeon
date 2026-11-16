package compiler.types.typing;

import compiler.types.TypedAst.TypedExpression;

/**
 * Numbering of the names a body generates, kept per body so a name depends on its position in its own function. A counter
 * shared by the whole typing run made the name depend on how many other functions were typed before it, which differs
 * between a build that types everything and one that retypes only what changed.
 */
class BodyCounters {
	/** Typed lambdas by position and captured bindings: the copies of a switch arm with several patterns capture different locals. */
	public final lambdaCache:Map<String, TypedExpression> = [];

	/** How many variants (see `lambdaCache`) each lambda position has been typed as. */
	final lambdaVariants:Map<String, Int> = [];

	/** Function adapters (and other generated locals sharing their numbering) already made in each body. */
	final functionAdapters:Map<String, Int> = [];

	final substrings:Map<String, Int> = [];

	public function new() {}

	/** The next variant number of the lambda at `lambdaKey`: 0 for its first typing. */
	public function nextLambdaVariant(lambdaKey:String):Int
		return next(lambdaVariants, lambdaKey);

	/** The next function adapter number in body `context`. */
	public function nextFunctionAdapter(context:String):Int
		return next(functionAdapters, context);

	/** The function adapter number `nextFunctionAdapter` will give next in body `context`, without taking it. */
	public function peekFunctionAdapter(context:String):Int {
		var count = functionAdapters.get(context);
		return count == null ? 0 : count;
	}

	/** The next `substr` lowering number in body `context`. */
	public function nextSubstring(context:String):Int
		return next(substrings, context);

	static function next(counts:Map<String, Int>, key:String):Int {
		var count = counts.get(key), id = count == null ? 0 : count;
		counts.set(key, id + 1);
		return id;
	}
}

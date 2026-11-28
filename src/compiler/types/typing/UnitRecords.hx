package compiler.types.typing;

import compiler.types.Type.AnonymousField;

/** How many of each lint fact a `UnitRecords` holds: see `UnitRecords.lintFactCounts`. */
typedef LintFactCounts = {
	final unboundLocals:Int;
	final nonExceptionThrows:Int;
	final lambdaTrailingValues:Int;
}

/**
 * One unit's answers, by the name it asked about. A class rather than a nested map, so a table of them holds typed values
 * whose layout the runtime knows: an arena's copy follows a field to a map, not an untyped map stored in another
 * (docs/design/ARENAS.md, "Data rules for arenas").
 */
class UnitAnswers {
	public final answers:Map<String, Bool> = [];

	public function new() {}
}

/** The anonymous types one unit registered, by name; a class for the same reason as `UnitAnswers`. */
class UnitAnonymousUses {
	public final types:Map<String, Array<AnonymousField>> = [];

	public function new() {}
}

/**
 * What each typed unit produced besides its code, for the program and the next incremental build: the anonymous types it
 * registered, the key path literals it uses, and the lint facts. A unit is a function body or a field initializer
 * (`Class.__init.x`). What a unit read is recorded apart (`DeclarationReads`).
 */
class UnitRecords {
	/**
	 * The anonymous types registered while each unit was typed, and those its signature reaches. A nested body (a lambda) belongs to
	 * the unit it is written in. The unit's module keeps them for the builds that do not type it again
	 * (`compiler.compilation.ModuleStructures`), so a type only unchanged code uses stays.
	 */
	final anonymousUnits:Map<String, UnitAnonymousUses> = [];

	/** The units whose bodies this session typed. */
	public final typedUnits:Map<String, Bool> = [];

	/** The key path literals (`$keypath.literal:...`) each body uses. */
	final keyPathUses:Map<String, UnitAnswers> = [];

	/**
	 * The locals whose type nothing fixed, in the order their bodies settled. A body whose typing fails takes back what it added
	 * (`TypingSession.recover`), so only bodies that typed are here.
	 */
	public final unboundLocals:Array<compiler.types.TypedAst.UnboundLocal> = [];

	/** The `throw`s of a value not statically a haxe.Exception, in typing order; kept, like `unboundLocals`, only for bodies that typed. */
	public final nonExceptionThrows:Array<compiler.types.TypedAst.NonExceptionThrow> = [];

	/** The lambdas whose block ends in an expression, in typing order; kept, like `unboundLocals`, only for bodies that typed. */
	public final lambdaTrailingValues:Array<compiler.types.TypedAst.LambdaTrailingValue> = [];

	public function new() {}

	/** Each record by unit, its answers as a map: the shapes the build publishes. */
	public function keyPathUsesByUnit():Map<String, Map<String, Bool>>
		return answersByUnit(keyPathUses);

	/** The anonymous types each unit registered, by unit, each unit's ordered by name. */
	public function orderedAnonymousUnits():Map<String, Array<compiler.types.TypedAst.TypedAnonymous>> {
		var result:Map<String, Array<compiler.types.TypedAst.TypedAnonymous>> = [];
		for (unit => uses in anonymousUnits) {
			var types = uses.types, names = [for (name in types.keys()) name];
			names.sort(Reflect.compare);
			result.set(unit, [for (name in names) {
				name: name, fields: types.get(name)
			}]);
		}
		return result;
	}

	/** Calls `each` with every anonymous type a unit registered, once per unit that did. */
	public function forEachAnonymousType(each:(name:String, fields:Array<AnonymousField>) -> Void):Void
		for (uses in anonymousUnits)
			for (name => fields in uses.types)
				each(name, fields);

	static function answersByUnit(records:Map<String, UnitAnswers>):Map<String, Map<String, Bool>>
		return [for (unit => record in records) unit => record.answers];

	/** How many lint facts (`unboundLocals`, `nonExceptionThrows`, `lambdaTrailingValues`) are recorded, for `truncateLintFacts`. */
	public function lintFactCounts():LintFactCounts
		return {
			unboundLocals: unboundLocals.length,
			nonExceptionThrows: nonExceptionThrows.length,
			lambdaTrailingValues: lambdaTrailingValues.length
		};

	/** Drops the lint facts recorded after `counts`. */
	public function truncateLintFacts(counts:LintFactCounts):Void {
		if (unboundLocals.length > counts.unboundLocals)
			unboundLocals.splice(counts.unboundLocals, unboundLocals.length - counts.unboundLocals);
		if (nonExceptionThrows.length > counts.nonExceptionThrows)
			nonExceptionThrows.splice(counts.nonExceptionThrows, nonExceptionThrows.length - counts.nonExceptionThrows);
		if (lambdaTrailingValues.length > counts.lambdaTrailingValues)
			lambdaTrailingValues.splice(counts.lambdaTrailingValues,
				lambdaTrailingValues.length - counts.lambdaTrailingValues);
	}

	public function recordAnonymousUse(unit:String, name:String, fields:Array<AnonymousField>):Void {
		var uses = anonymousUnits.get(unit);
		if (uses == null) {
			uses = new UnitAnonymousUses();
			anonymousUnits.set(unit, uses);
		}
		uses.types.set(name, fields);
	}

	public function recordKeyPathUse(user:String, literal:String):Void
		mark(keyPathUses, user, literal);

	/** Adds these records to `target`. */
	public function mergeInto(target:UnitRecords):Void {
		for (unit => uses in anonymousUnits)
			for (name => fields in uses.types)
				target.recordAnonymousUse(unit, name, fields);
		for (unit in typedUnits.keys())
			target.typedUnits.set(unit, true);
		for (local in unboundLocals)
			target.unboundLocals.push(local);
		for (thrown in nonExceptionThrows)
			target.nonExceptionThrows.push(thrown);
		for (lambda in lambdaTrailingValues)
			target.lambdaTrailingValues.push(lambda);
		mergeQueries(keyPathUses, target.keyPathUses);
	}

	static function mergeQueries(records:Map<String, UnitAnswers>, target:Map<String, UnitAnswers>):Void
		for (caller => record in records)
			for (name => answer in record.answers)
				answerQuery(target, caller, name, answer);

	static function mark(target:Map<String, UnitAnswers>, owner:String, name:String):Void
		answerQuery(target, owner, name, true);

	static function answerQuery(target:Map<String, UnitAnswers>, caller:String, name:String, answer:Bool):Void {
		var record = target.get(caller);
		if (record == null) {
			record = new UnitAnswers();
			target.set(caller, record);
		}
		record.answers.set(name, answer);
	}
}

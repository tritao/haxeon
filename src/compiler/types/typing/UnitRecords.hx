package compiler.types.typing;

import compiler.core.Source.SourceFile;
import compiler.types.Type.AnonymousField;

/** How many of each lint fact a `UnitRecords` holds: see `UnitRecords.lintFactCounts`. */
typedef LintFactCounts = {
	final unboundLocals:Int;
	final nonExceptionThrows:Int;
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

/** The source snapshots one unit copied default arguments from, by path; a class for the same reason as `UnitAnswers`. */
class UnitSources {
	public final files:Map<String, SourceFile> = [];

	public function new() {}
}

/**
 * What each typed unit relied on, for the next incremental build. A unit is a function body or a field initializer
 * (`Class.__init.x`); the query records are kept by the body that asked, a lambda's own name included. An unchanged body
 * is typed again when one of its answers changes (the drift check in `SemanticAssembly`).
 */
class UnitRecords {
	/**
	 * The anonymous types registered while each unit was typed. A nested body (a lambda) belongs to the unit it is written in.
	 * A build that types a unit again records it afresh; one that does not keeps the earlier record in the program (see
	 * `ProgramTyper.keepAnonymousUnits`), so a type only unchanged code uses stays.
	 */
	final anonymousUnits:Map<String, UnitAnonymousUses> = [];

	/** The units whose bodies this session typed. */
	public final typedUnits:Map<String, Bool> = [];

	/** Purity answers each body asked about, keyed by that body's name. */
	final purityQueries:Map<String, UnitAnswers> = [];

	final noReturnQueries:Map<String, UnitAnswers> = [];

	/** The key path literals (`$keypath.literal:...`) each body uses. */
	final keyPathUses:Map<String, UnitAnswers> = [];

	/** Constants substituted into each typed body, including its omitted call arguments. */
	final inlineConstantDependencies:Map<String, UnitAnswers> = [];

	/**
	 * The unannotated declarations whose inferred type each unit read (through `DeclarationTypes`), keyed by that unit's name. They
	 * become the unit's `DeclarationType` edges: an edit that may change one of those types retypes the unit.
	 */
	final declarationTypeReads:Map<String, UnitAnswers> = [];

	/** Source snapshots copied into callers when omitted arguments use declaration syntax. */
	final defaultArgumentSources:Map<String, UnitSources> = [];

	/**
	 * The locals whose type nothing fixed, in the order their bodies settled. A body whose typing fails takes back what it added
	 * (`TypingSession.recover`), so only bodies that typed are here.
	 */
	public final unboundLocals:Array<compiler.types.TypedAst.UnboundLocal> = [];

	/** The `throw`s of a value not statically a haxe.Exception, in typing order; kept, like `unboundLocals`, only for bodies that typed. */
	public final nonExceptionThrows:Array<compiler.types.TypedAst.NonExceptionThrow> = [];

	public function new() {}

	/** Each record by unit, its answers as a map: the shapes the build publishes. */
	public function purityQueriesByUnit():Map<String, Map<String, Bool>>
		return answersByUnit(purityQueries);

	public function noReturnQueriesByUnit():Map<String, Map<String, Bool>>
		return answersByUnit(noReturnQueries);

	public function keyPathUsesByUnit():Map<String, Map<String, Bool>>
		return answersByUnit(keyPathUses);

	public function inlineConstantDependenciesByUnit():Map<String, Map<String, Bool>>
		return answersByUnit(inlineConstantDependencies);

	public function declarationTypeReadsByUnit():Map<String, Map<String, Bool>>
		return answersByUnit(declarationTypeReads);

	public function defaultArgumentSourcesByUnit():Map<String, Map<String, SourceFile>>
		return [for (unit => sources in defaultArgumentSources) unit => sources.files];

	/** The anonymous types each unit registered, by name. */
	public function anonymousUnitsByUnit():Map<String, Map<String, Array<AnonymousField>>>
		return [for (unit => uses in anonymousUnits) unit => uses.types];

	public function hasAnonymousUnit(unit:String):Bool
		return anonymousUnits.exists(unit);

	/** Keeps the anonymous types an earlier build recorded for `unit`, which this one does not type again. */
	public function keepAnonymousUnit(unit:String, types:Map<String, Array<AnonymousField>>):Void {
		var uses = new UnitAnonymousUses();
		for (name => fields in types)
			uses.types.set(name, fields);
		anonymousUnits.set(unit, uses);
	}

	static function answersByUnit(records:Map<String, UnitAnswers>):Map<String, Map<String, Bool>>
		return [for (unit => record in records) unit => record.answers];

	/** How many lint facts (`unboundLocals`, `nonExceptionThrows`) are recorded, to take back to with `truncateLintFacts`. */
	public function lintFactCounts():LintFactCounts
		return {unboundLocals: unboundLocals.length, nonExceptionThrows: nonExceptionThrows.length};

	/** Drops the lint facts recorded after `counts`. */
	public function truncateLintFacts(counts:LintFactCounts):Void {
		if (unboundLocals.length > counts.unboundLocals)
			unboundLocals.splice(counts.unboundLocals, unboundLocals.length - counts.unboundLocals);
		if (nonExceptionThrows.length > counts.nonExceptionThrows)
			nonExceptionThrows.splice(counts.nonExceptionThrows, nonExceptionThrows.length - counts.nonExceptionThrows);
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

	/** The reads of the reader recorded last: a body reads many declaration types in a row. */
	var lastReader:Null<String>;

	var lastReads:Null<UnitAnswers>;

	public function recordDeclarationTypeRead(reader:String, declaration:String):Void {
		var reads = lastReader == reader ? lastReads : null;
		if (reads == null) {
			reads = declarationTypeReads.get(reader);
			if (reads == null) {
				reads = new UnitAnswers();
				declarationTypeReads.set(reader, reads);
			}
			lastReader = reader;
			lastReads = reads;
		}
		reads.answers.set(declaration, true);
	}

	public function recordInlineConstantDependency(caller:String, constant:String):Void
		mark(inlineConstantDependencies, caller, constant);

	/** Records that `caller` substituted a default argument, and the declaration source it was copied from, if any. */
	public function recordDefaultArgumentSource(caller:String, file:Null<SourceFile>):Void {
		var sources = defaultArgumentSources.get(caller);
		if (sources == null) {
			sources = new UnitSources();
			defaultArgumentSources.set(caller, sources);
		}
		if (file != null)
			sources.files.set(file.path, file);
	}

	public function recordPurity(caller:String, name:String, answer:Bool):Void
		answerQuery(purityQueries, caller, name, answer);

	public function recordNoReturn(caller:String, name:String, answer:Bool):Void
		answerQuery(noReturnQueries, caller, name, answer);

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
		mergeQueries(purityQueries, target.purityQueries);
		mergeQueries(noReturnQueries, target.noReturnQueries);
		mergeQueries(keyPathUses, target.keyPathUses);
		mergeQueries(inlineConstantDependencies, target.inlineConstantDependencies);
		mergeQueries(declarationTypeReads, target.declarationTypeReads);
		for (caller => sources in defaultArgumentSources) {
			var merged = target.defaultArgumentSources.get(caller);
			if (merged == null) {
				merged = new UnitSources();
				target.defaultArgumentSources.set(caller, merged);
			}
			for (path => file in sources.files)
				merged.files.set(path, file);
		}
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

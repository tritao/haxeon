package compiler.types.typing;

import compiler.core.Source.SourceFile;
import compiler.types.Type.AnonymousField;

/** How many of each lint fact a `UnitRecords` holds: see `UnitRecords.lintFactCounts`. */
typedef LintFactCounts = {
	final unboundLocals:Int;
	final nonExceptionThrows:Int;
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
	public final anonymousUnits:Map<String, Map<String, Array<AnonymousField>>> = [];

	/** The units whose bodies this session typed. */
	public final typedUnits:Map<String, Bool> = [];

	/** Purity answers each body asked about, keyed by that body's name. */
	public final purityQueries:Map<String, Map<String, Bool>> = [];

	public final noReturnQueries:Map<String, Map<String, Bool>> = [];

	/** The key path literals (`$keypath.literal:...`) each body uses. */
	public final keyPathUses:Map<String, Map<String, Bool>> = [];

	/** Constants substituted into each typed body, including its omitted call arguments. */
	public final inlineConstantDependencies:Map<String, Map<String, Bool>> = [];

	/**
	 * The unannotated declarations whose inferred type each unit read (through `DeclarationTypes`), keyed by that unit's name. They
	 * become the unit's `DeclarationType` edges: an edit that may change one of those types retypes the unit.
	 */
	public final declarationTypeReads:Map<String, Map<String, Bool>> = [];

	/** Source snapshots copied into callers when omitted arguments use declaration syntax. */
	public final defaultArgumentSources:Map<String, Map<String, SourceFile>> = [];

	/**
	 * The locals whose type nothing fixed, in the order their bodies settled. A body whose typing fails takes back what it added
	 * (`TypingSession.recover`), so only bodies that typed are here.
	 */
	public final unboundLocals:Array<compiler.types.TypedAst.UnboundLocal> = [];

	/** The `throw`s of a value not statically a haxe.Exception, in typing order; kept, like `unboundLocals`, only for bodies that typed. */
	public final nonExceptionThrows:Array<compiler.types.TypedAst.NonExceptionThrow> = [];

	public function new() {}

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
			uses = [];
			anonymousUnits.set(unit, uses);
		}
		uses.set(name, fields);
	}

	public function recordKeyPathUse(user:String, literal:String):Void
		mark(keyPathUses, user, literal);

	/** The reads of the reader recorded last: a body reads many declaration types in a row. */
	var lastReader:Null<String>;

	var lastReads:Null<Map<String, Bool>>;

	public function recordDeclarationTypeRead(reader:String, declaration:String):Void {
		var reads = lastReader == reader ? lastReads : null;
		if (reads == null) {
			reads = declarationTypeReads.get(reader);
			if (reads == null) {
				reads = [];
				declarationTypeReads.set(reader, reads);
			}
			lastReader = reader;
			lastReads = reads;
		}
		reads.set(declaration, true);
	}

	public function recordInlineConstantDependency(caller:String, constant:String):Void
		mark(inlineConstantDependencies, caller, constant);

	/** Records that `caller` substituted a default argument, and the declaration source it was copied from, if any. */
	public function recordDefaultArgumentSource(caller:String, file:Null<SourceFile>):Void {
		var sources = defaultArgumentSources.get(caller);
		if (sources == null) {
			sources = [];
			defaultArgumentSources.set(caller, sources);
		}
		if (file != null)
			sources.set(file.path, file);
	}

	public function recordPurity(caller:String, name:String, answer:Bool):Void
		answerQuery(purityQueries, caller, name, answer);

	public function recordNoReturn(caller:String, name:String, answer:Bool):Void
		answerQuery(noReturnQueries, caller, name, answer);

	/** Adds these records to `target`. */
	public function mergeInto(target:UnitRecords):Void {
		for (unit => uses in anonymousUnits)
			for (name => fields in uses)
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
				merged = [];
				target.defaultArgumentSources.set(caller, merged);
			}
			for (path => file in sources)
				merged.set(path, file);
		}
	}

	static function mergeQueries(records:Map<String, Map<String, Bool>>, target:Map<String, Map<String, Bool>>):Void
		for (caller => answers in records)
			for (name => answer in answers)
				answerQuery(target, caller, name, answer);

	static function mark(target:Map<String, Map<String, Bool>>, owner:String, name:String):Void
		answerQuery(target, owner, name, true);

	static function answerQuery(target:Map<String, Map<String, Bool>>, caller:String, name:String, answer:Bool):Void {
		var record = target.get(caller);
		if (record == null) {
			record = [];
			target.set(caller, record);
		}
		record.set(name, answer);
	}
}

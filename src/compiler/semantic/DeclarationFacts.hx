package compiler.semantic;

/** What of a declaration, or of the program, a fact is (`DeclarationFacts`). */
enum abstract FactAspect(Int) to Int {
	/** A function's signature: its arguments with their defaults, its result, its type parameters, flags and metadata. */
	var Signature = 0;

	/** A function's canonical body, with its lines (and offsets, for a generic one, whose specializations name them). */
	var Body = 1;

	/**
	 * What a reference to a type means: its kind, type parameters and constraints, base and interfaces and metadata; for an
	 * alias, an abstract or an interface, all of it; for an enum, all but its constructors (`Members`, `Case`).
	 */
	var Shape = 2;

	/**
	 * A class: its shape, its fields, and its methods by name and kind (their signatures are `Signature` facts of their own). An
	 * enum: its constructors and methods.
	 */
	var Members = 3;

	/** A field's initializer, with its position: inlined or copied by the units that read it. */
	var Initializer = 4;

	/** Whether a callee is pure, as purity inference answers it. */
	var Purity = 5;

	/** Whether a callee never returns. */
	var NoReturn = 6;

	/** A source file's text: a unit that copied a default argument names that snapshot. */
	var Snapshot = 7;

	/** A typed unit, read for its result: what it read in turn (`UnitReads`). */
	var Unit = 8;

	/** Every declaration of one kind (`DeclarationFacts.KIND_*`), for code that searches them all. */
	var Kind = 9;

	/** One constructor of an enum (`Enum.Case`): its index and its parameters, which code constructing or matching it holds. */
	var Case = 10;

	/** A declaration's layout and annotations as consumed by a wire codec. */
	var WireShape = 11;

	/** The ordered typedef candidates for an anonymous record's set of field names. */
	var WireAliases = 12;
}

/**
 * What one typed unit read, and the revision it was typed at: a `Unit` fact's result in the session's database
 * (`DeclarationFacts.recordUnit`).
 */
class UnitReads extends compiler.query.RecordedQueryKind.RecordedResult {
	/** The module whose state holds what the unit was typed to (its typed body, for a function). */
	public final module:String;

	/**
	 * Of the reads, the units of the generic specializations the unit asks for, or null for none: what keeps a specialization that
	 * is not typed again, found without reading every fact of every unit.
	 */
	public final specializations:Null<Array<Int>>;

	/**
	 * Whether typing the unit made nothing besides its function and the helpers it asked for (no lambda, generic owner, enum
	 * representation, key path or structure): a generated helper so made can be kept as it is while what it read holds.
	 */
	public final standalone:Bool;

	public function new(revision:Int, reads:Array<Int>, module:String, ?specializations:Array<Int>,
			standalone:Bool = false) {
		super(revision, reads);
		this.module = module;
		this.specializations = specializations;
		this.standalone = standalone;
	}
}

/**
 * The facts typed units read, for a session (`WARM_REBUILD_REUSE.md`, "Typing: recorded reads"), as a kind of the session's query
 * database (`RecordedQueryKind`). A fact is an aspect of a declaration or of the program, by name, interned to a dense id, which is
 * its key and, the kind being the database's first, its read. It keeps the revision its print last changed at and the facts its
 * meaning goes through; a unit is a `Unit` fact whose result is what it read, with the revision it was typed at (`UnitReads`),
 * and is current while none of those facts, or of what they go through, changed after that. A build writes the units it typed in
 * its transaction, which the build that is taken commits (`RecordedQueryKind.write`).
 *
 * Prints only move forward: a build that fails after moving one leaves it moved, so the units typed before are typed again.
 * The copies of the session state share the table, as they share the IR facts.
 */
class DeclarationFacts extends compiler.query.RecordedQueryKind {
	public static inline final KIND_CLASSES = "classes";
	public static inline final KIND_ENUMS = "enums";
	public static inline final KIND_ABSTRACTS = "abstracts";
	public static inline final KIND_ENUM_ABSTRACTS = "enum-abstracts";
	public static inline final KIND_INTERFACES = "interfaces";
	public static inline final KIND_ALIASES = "aliases";

	/**
	 * Which fields have accessors, by name over every class (a `get`, `set` or `dynamic` access), and which functions are named
	 * as setters (`set_`): what purity inference asks of a field it reads or writes (`PurityInference`).
	 */
	public static inline final KIND_ACCESSORS = "accessors";

	/** Which classes override which methods: the override methods of every class (their bases are `KIND_CLASSES`). */
	public static inline final KIND_OVERRIDES = "overrides";

	/** The revision of the build in progress: the database's. */
	public var revision(get, never):Int;

	inline function get_revision():Int
		return database.revision;

	var ids:Array<Map<String, Int>> = [for (_ in 0...(FactAspect.WireAliases + 1))[]];
	var aspects:Array<Int> = [];
	var names:Array<String> = [];
	var printChangedAt:Array<Int> = [];

	/**
	 * By a type's `Shape` fact, the revision at which the name last became or stopped being a declaration of some kind. A
	 * declaration that names the type without expanding it still goes through its kind, which decides how the type is held (an
	 * interface as a virtual, a class as an object).
	 */
	var kindChangedAt:Array<Int> = [];

	var dependencies:Array<Null<Array<Int>>> = [];

	/** Registers the table as `database`'s first kind, so that a fact's id is its read. */
	public function new(database:compiler.query.QueryDatabase) {
		super("fact", database);
		database.register(this);
		if (index != 0)
			throw new compiler.core.InternalError("the declaration facts must be their database's first kind");
	}

	/**
	 * Forgets every fact, for a compile that keeps no session once its typing is done: only a next build's invalidation reads
	 * them. The revision stays, so a fact named again is new.
	 */
	public function clear():Void {
		ids = [for (_ in 0...(FactAspect.WireAliases + 1))[]];
		aspects = [];
		names = [];
		printChangedAt = [];
		kindChangedAt = [];
		dependencies = [];
		expanded = [];
		clearKeys();
		logStart += changeLog.length + 1;
		changeLog = [];
		unitReaders.clear();
		unitGroups = [];
		unitGroupCount = 0;
	}

	/** Starts a build: facts changed from here on change at the new revision. */
	public function beginBuild():Int
		return database.newRevision();

	/** The fact `aspect` of `name`, made the first time it is named. */
	public function id(aspect:FactAspect, name:String):Int {
		var table = ids[aspect], known = table.get(name);
		if (known != null)
			return known;
		var made = names.length;
		table.set(name, made);
		aspects.push(aspect);
		names.push(name);
		printChangedAt.push(0);
		kindChangedAt.push(0);
		dependencies.push(null);
		return made;
	}

	/** The fact `aspect` of `name`, or -1 when nothing named it yet: nothing read it, so nothing needs to see it change. */
	public function existing(aspect:FactAspect, name:String):Int {
		var known = ids[aspect].get(name);
		return known == null ? -1 : known;
	}

	public inline function aspect(id:Int):FactAspect
		return cast aspects[id];

	public inline function name(id:Int):String
		return names[id];

	public inline function changedRevision(id:Int):Int
		return printChangedAt[id];

	/** Records that fact `id`'s print changed in this build. */
	public function changed(id:Int):Void {
		logChange(id);
		printChangedAt[id] = revision;
		lastChange = revision;
	}

	/** Records that the type whose `Shape` fact is `id` may be of another kind from this build on (`kindChangedAt`). */
	public function kindChanged(id:Int):Void {
		logChange(id);
		kindChangedAt[id] = revision;
		lastChange = revision;
	}

	// Each change of a fact's print or kind, in order: what changed after a point (`changeCount`), found without walking every
	// fact. The oldest are dropped; `logStart` counts the changes before the first one kept.
	var changeLog:Array<Int> = [];
	var logStart = 0;

	static inline final LOG_LIMIT = 4096;

	function logChange(id:Int):Void {
		if (changeLog.length >= LOG_LIMIT) {
			var dropped = LOG_LIMIT >> 1;
			for (index in dropped...changeLog.length)
				changeLog[index - dropped] = changeLog[index];
			changeLog.resize(changeLog.length - dropped);
			logStart += dropped;
		}
		changeLog.push(id);
	}

	/** How many changes there were: the point `changesSince` takes, from which later changes are found. */
	public var changeCount(get, never):Int;

	inline function get_changeCount():Int
		return logStart + changeLog.length;

	/**
	 * The facts that changed after point `since` (`changeCount`), each once, with every fact that goes through one of them
	 * (`setDependencies`); null when the changes that far back are no longer known.
	 */
	public function changesSince(since:Int):Null<Array<Int>> {
		if (since < logStart)
			return null;
		var seen:Map<Int, Bool> = [], found:Array<Int> = [], through = false;
		for (index in since - logStart...changeLog.length) {
			var id = changeLog[index];
			if (seen.exists(id))
				continue;
			seen.set(id, true);
			found.push(id);
			var aspect:FactAspect = cast aspects[id];
			if (aspect == Shape || aspect == Signature || aspect == Members)
				through = true;
		}
		if (!through)
			return found;
		// Only shapes, signatures and members are gone through (a type's shape, an implicit constructor's base signature, an
		// accessor's class): their readers are found from every fact's dependencies, which an edit to a declaration needs.
		var readers:Map<Int, Array<Int>> = [];
		for (id in 0...dependencies.length) {
			var targets = dependencies[id];
			if (targets == null || aspects[id] == (FactAspect.Unit:Int))
				continue;
			for (target in targets) {
				var list = readers.get(target);
				if (list == null)
					readers.set(target, list = []);
				list.push(id);
			}
		}
		var index = 0;
		while (index < found.length) {
			var list = readers.get(found[index++]);
			if (list != null)
				for (reader in list)
					if (!seen.exists(reader)) {
						seen.set(reader, true);
						found.push(reader);
					}
		}
		return found;
	}

	var lastChange = 0;

	/** Whether any fact changed in this build. */
	public inline function changedInBuild():Bool
		return lastChange == revision;

	/**
	 * The facts that fact `id`'s meaning goes through (the shapes of the types a signature names); null for none. Of those, only
	 * the shapes of typedefs and abstracts count (`markExpanded`): a type of another kind is named, not expanded, by what names it,
	 * and its readers read what they use of it themselves.
	 */
	public function setDependencies(id:Int, through:Null<Array<Int>>):Void
		dependencies[id] = through;

	/** The facts fact `id` goes through, as `setDependencies` gave them; null for none. */
	public inline function dependenciesOf(id:Int):Null<Array<Int>>
		return dependencies[id];

	/** Records that shape fact `id` is a typedef's or an abstract's, which the types naming it expand. */
	public function markExpanded(id:Int):Void {
		while (expanded.length <= id)
			expanded.push(false);
		expanded[id] = true;
	}

	var expanded:Array<Bool> = [];

	inline function isExpanded(id:Int):Bool
		return id < expanded.length && expanded[id];

	/** Records what unit fact `id` read when this build typed it, in the build's transaction. */
	public function recordUnit(id:Int, reads:UnitReads):Void {
		var before = unitRecord(id);
		unitReaders.add(unitGroup(reads.module), id, reads.reads, before != null && before.module == reads.module);
		write(id, reads);
	}

	/** Which units may have read a fact, by the module whose state holds them (`unitGroups`). */
	final unitReaders = new compiler.query.ReadFilter();

	var unitGroups:Map<String, Int> = [];
	var unitGroupCount = 0;

	function unitGroup(module:String):Int {
		var known = unitGroups.get(module);
		if (known == null) {
			known = unitGroupCount++;
			unitGroups.set(module, known);
		}
		return known;
	}

	/** Builds the filters of what units read again once they took many more reads than they were built for (`ReadFilter.full`). */
	public function refreshReaders():Void
		if (unitReaders.full)
			unitReaders.rebuild(names.length, visit -> forEachResult((key, result) -> {
				var reads:UnitReads = cast result;
				visit(unitGroup(reads.module), key, reads.reads);
			}));

	/**
	 * The units that may have read a fact that changed after point `since` (`changeCount`), themselves or through what they read (a
	 * unit reading another), in fact order: among them is every unit `firstChanged` finds changed, if each was current at `since`
	 * or typed after. Null when the changes that far back are no longer known.
	 */
	public function unitsReading(since:Int):Null<Array<Int>> {
		var changes = changesSince(since);
		if (changes == null)
			return null;
		refreshReaders();
		var changed:Map<Int, Bool> = [for (id in changes) id => true], found:Map<Int, Bool> = [], start = 0;
		// A unit that read a change changed itself, for the units that read it.
		while (start < changes.length) {
			var end = changes.length;
			for (group in 0...unitReaders.groups) {
				var hit = false;
				for (index in start...end)
					if (unitReaders.mayRead(group, changes[index])) {
						hit = true;
						break;
					}
				if (hit)
					for (unit in unitReaders.membersOf(group)) {
						var record = unitRecord(unit);
						if (found.exists(unit) || record == null || !readsAny(record.reads, changed))
							continue;
						found.set(unit, true);
						if (!changed.exists(unit)) {
							changed.set(unit, true);
							changes.push(unit);
						}
					}
			}
			start = end;
		}
		var units = [for (unit in found.keys()) unit];
		units.sort((left, right) -> left - right);
		return units;
	}

	static function readsAny(reads:Array<Int>, keys:Map<Int, Bool>):Bool {
		for (read in reads)
			if (keys.exists(read))
				return true;
		return false;
	}

	/** Drops the record of unit fact `id`, whose unit is gone, in the build's transaction. */
	public inline function removeUnit(id:Int):Void
		write(id, null);

	/** What unit fact `id` read when it was last typed, or null when no unit with a record has that fact. */
	public inline function unitRecord(id:Int):Null<UnitReads>
		return id < 0 ? null : cast result(id);

	override function ownChange(key:Int):Int
		return printChangedAt[key];

	/**
	 * A unit's reads are its record's; a unit without one (a generic body typed for its errors alone) gives its readers nothing: a
	 * reader of a unit always reads the declaration it is typed from too, whose own facts change when it is edited or removed.
	 */
	override function readsOf(key:Int):Null<Array<Int>>
		return aspects[key] != (FactAspect.Unit:Int) ? dependencies[key] : super.readsOf(key);

	/** What a declaration names goes through only the types it expands, and the kinds of the others; what a unit read counts whatever it is. */
	override function partialChange(source:Int, target:Int):Int
		return aspects[source] != (FactAspect.Unit:Int) && aspects[target] == (FactAspect.Shape:Int)
			&& !isExpanded(target) ? kindChangedAt[target] : -1;

	/**
	 * A fact of `record` that changed after it was typed, for the invalidation report: one that changed itself when there is one,
	 * else one that goes through a change; -1 when the unit is current. The facts that go through each other (an inferred
	 * declaration that reads another that reads it) get the latest change of all of them.
	 */
	public function firstChanged(record:UnitReads):Int {
		var through = -1;
		for (fact in record.reads)
			if (printChangedAt[fact] > record.revision)
				return fact;
			else if (through < 0 && latestChange(fact) > record.revision)
				through = fact;
		return through;
	}

	/** Calls `each` with every fact of `aspect` named so far. */
	public function forEach(aspect:FactAspect, each:(id:Int, name:String) -> Void):Void
		for (name => id in ids[aspect])
			each(id, name);

	/** How many facts the table holds. */
	public function size():Int
		return names.length;
}

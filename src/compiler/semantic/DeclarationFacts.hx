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

/** What one typed unit read, and the revision it was typed at (`DeclarationFacts`). */
class UnitReads {
	public final typedAt:Int;
	public final facts:Array<Int>;

	/**
	 * Of `facts`, the units of the generic specializations the unit asks for, or null for none: what keeps a specialization that is
	 * not typed again, found without reading every fact of every unit.
	 */
	public final specializations:Null<Array<Int>>;

	public function new(typedAt:Int, facts:Array<Int>, ?specializations:Array<Int>) {
		this.typedAt = typedAt;
		this.facts = facts;
		this.specializations = specializations;
	}
}

/**
 * The facts typed units read, for a session (`WARM_REBUILD_REUSE.md`, "Typing: recorded reads"), as a kind of the session's query
 * database (`RecordedQueryKind`). A fact is an aspect of a declaration or of the program, by name, interned to a dense id, which is
 * its key and, the kind being the database's first, its read. It keeps the revision its print last changed at and the facts its
 * meaning goes through; a unit is a `Unit` fact whose reads are the facts it read, kept with the revision it was typed at
 * (`UnitReads`), and is current while none of them, or of what they go through, changed after that.
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

	/** The module whose state holds a `Unit` fact's reads, by fact. */
	var unitModules:Map<Int, String> = [];

	/** Where a walk finds the reads of a `Unit` fact (`current`, `latestChange`), while one runs. */
	var units:Null<(unit:Int) -> Null<UnitReads>> = null;

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
		unitModules = [];
		expanded = [];
		clearKeys();
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
		printChangedAt[id] = revision;
		lastChange = revision;
	}

	/** Records that the type whose `Shape` fact is `id` may be of another kind from this build on (`kindChangedAt`). */
	public function kindChanged(id:Int):Void {
		kindChangedAt[id] = revision;
		lastChange = revision;
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

	/** Records that the reads of unit fact `id` are held by `module`'s state (`ModuleState.unitReads`). */
	public function placeUnit(id:Int, module:String):Void
		unitModules.set(id, module);

	public function unitModule(id:Int):Null<String>
		return unitModules.get(id);

	override function ownChange(key:Int):Int
		return printChangedAt[key];

	/**
	 * A unit's reads are what it read, found through `units`; one no module holds reads (a generic body typed for its errors alone)
	 * gives its readers nothing: a reader of a unit always reads the declaration it is typed from too, whose own facts change when
	 * it is edited or removed.
	 */
	override function readsOf(key:Int):Null<Array<Int>> {
		if (aspects[key] != (FactAspect.Unit:Int))
			return dependencies[key];
		var find = units, record = find == null ? null : find(key);
		return record == null ? null : record.facts;
	}

	/** What a declaration names goes through only the types it expands, and the kinds of the others; what a unit read counts whatever it is. */
	override function partialChange(source:Int, target:Int):Int
		return aspects[source] != (FactAspect.Unit:Int) && aspects[target] == (FactAspect.Shape:Int)
			&& !isExpanded(target) ? kindChangedAt[target] : -1;

	/**
	 * The latest revision at which fact `id`, or a fact it goes through, changed. A unit fact goes through the reads `reads` finds
	 * for it. Memoized for the build; the facts that go through each other (an inferred declaration that reads another that reads
	 * it) get the latest change of all of them.
	 */
	public function latestChangeOf(id:Int, reads:(unit:Int) -> Null<UnitReads>):Int {
		// Each entry sets where units are found, so one an exception left behind is never read; a try costs on this path.
		units = reads;
		var change = latestChange(id);
		units = null;
		return change;
	}

	/** Whether a unit typed at `typedAt` that read `facts` is current: nothing it read changed after it was typed. */
	public function current(record:UnitReads, reads:(unit:Int) -> Null<UnitReads>):Bool {
		units = reads;
		var result = currentSince(record.facts, record.typedAt);
		units = null;
		return result;
	}

	/**
	 * A fact of `record` that changed after it was typed, for the invalidation report: one that changed itself when there is one,
	 * else one that goes through a change; -1 when the unit is current.
	 */
	public function firstChanged(record:UnitReads, reads:(unit:Int) -> Null<UnitReads>):Int {
		var through = -1;
		units = reads;
		for (fact in record.facts)
			if (printChangedAt[fact] > record.typedAt) {
				through = fact;
				break;
			} else if (through < 0 && latestChange(fact) > record.typedAt)
				through = fact;
		units = null;
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

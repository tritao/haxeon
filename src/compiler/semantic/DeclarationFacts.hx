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
}

/** What one typed unit read, and the revision it was typed at (`DeclarationFacts`). */
class UnitReads {
	public final typedAt:Int;
	public final facts:Array<Int>;

	public function new(typedAt:Int, facts:Array<Int>) {
		this.typedAt = typedAt;
		this.facts = facts;
	}
}

/**
 * The facts typed units read, for a session (`WARM_REBUILD_REUSE.md`, "Typing: recorded reads"). A fact is an aspect of a
 * declaration or of the program, by name, interned to a dense id. It keeps the revision its print last changed at and the
 * facts its meaning goes through; a unit keeps the facts it read and the revision it was typed at (`UnitReads`), and is current
 * while none of them, or of what they go through, changed after that.
 *
 * Prints only move forward: a build that fails after moving one leaves it moved, so the units typed before are typed again.
 * The copies of the session state share the table, as they share the IR facts.
 */
class DeclarationFacts {
	public static inline final KIND_CLASSES = "classes";
	public static inline final KIND_ENUMS = "enums";
	public static inline final KIND_ABSTRACTS = "abstracts";
	public static inline final KIND_ENUM_ABSTRACTS = "enum-abstracts";
	public static inline final KIND_INTERFACES = "interfaces";
	public static inline final KIND_ALIASES = "aliases";

	/** The revision of the build in progress: 1 for the first. */
	public var revision(default, null) = 0;

	var ids:Array<Map<String, Int>> = [for (_ in 0...11)[]];
	var aspects:Array<Int> = [];
	var names:Array<String> = [];
	var changedAt:Array<Int> = [];
	var dependencies:Array<Null<Array<Int>>> = [];

	/** The module whose state holds a `Unit` fact's reads, by fact. */
	var unitModules:Map<Int, String> = [];

	/** The latest change of each fact and of what it goes through, for the revision in `effectiveIn`. */
	var effective:Array<Int> = [];

	var effectiveIn:Array<Int> = [];

	/** The reader that last recorded each fact (`ReadSink`), so that a sink records a fact once. */
	var recordedBy:Array<Int> = [];

	var lastSink = 0;

	public function new() {}

	/**
	 * Forgets every fact, for a compile that keeps no session once its typing is done: only a next build's invalidation reads
	 * them. The revision stays, so a fact named again is new.
	 */
	public function clear():Void {
		ids = [for (_ in 0...11)[]];
		aspects = [];
		names = [];
		changedAt = [];
		dependencies = [];
		unitModules = [];
		effective = [];
		effectiveIn = [];
		recordedBy = [];
		expanded = [];
		members = [];
		path = [];
		next = [];
		successors = [];
		named = [];
		visitedIn = [];
		order = [];
		lowest = [];
		latest = [];
		onPath = [];
		walkReads = null;
	}

	/** Starts a build: facts changed from here on change at the new revision. */
	public function beginBuild():Int
		return ++revision;

	/** The fact `aspect` of `name`, made the first time it is named. */
	public function id(aspect:FactAspect, name:String):Int {
		var table = ids[aspect], known = table.get(name);
		if (known != null)
			return known;
		var made = names.length;
		table.set(name, made);
		aspects.push(aspect);
		names.push(name);
		changedAt.push(0);
		dependencies.push(null);
		effective.push(0);
		effectiveIn.push(0);
		recordedBy.push(0);
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
		return changedAt[id];

	/** Records that fact `id`'s print changed in this build. */
	public function changed(id:Int):Void {
		changedAt[id] = revision;
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

	/** A new reader for `record`: a sink records each fact once. */
	public function newSink():Int
		return ++lastSink;

	/** Whether sink `sink` has not recorded fact `id` yet, marking it recorded. */
	public inline function firstRecord(id:Int, sink:Int):Bool {
		if (recordedBy[id] == sink)
			return false;
		recordedBy[id] = sink;
		return true;
	}

	/**
	 * The latest revision at which fact `id`, or a fact it goes through, changed. A unit fact goes through the reads `reads` finds
	 * for it. One no module holds reads (a generic body typed for its errors alone) gives its readers nothing: a reader of a unit
	 * always reads the declaration it is typed from too, whose own facts change when it is edited or removed. Memoized for the
	 * build. The facts that go through each other (an
	 * inferred declaration that reads another that reads it) get the latest change of all of them: the walk finds them as a
	 * strongly connected component (Tarjan's algorithm), without recursion, since chains of units can be long.
	 */
	public function latestChange(id:Int, reads:(unit:Int) -> Null<UnitReads>):Int {
		if (effectiveIn[id] == revision)
			return effective[id];
		// A fact that goes through nothing changed when it did.
		if (dependencies[id] == null && aspects[id] != (FactAspect.Unit:Int)) {
			effective[id] = changedAt[id];
			effectiveIn[id] = revision;
			return changedAt[id];
		}
		walkEpoch++;
		counter = 0;
		walkReads = reads;
		enter(id);
		while (path.length > 0) {
			var top = path.length - 1, fact = path[top], through = successors[top], position = next[top];
			if (through != null && position < through.length && latest[fact] < revision) {
				next[top] = position + 1;
				var successor = through[position];
				// What a declaration names goes through only the types it expands; what a unit read counts whatever it is.
				if (named[top] && aspects[successor] == (FactAspect.Shape:Int) && !isExpanded(successor))
					continue;
				if (effectiveIn[successor] == revision) {
					if (effective[successor] > latest[fact])
						latest[fact] = effective[successor];
				} else if (successor >= visitedIn.length || visitedIn[successor] != walkEpoch)
					enter(successor);
				else if (onPath[successor] && order[successor] < lowest[fact])
					lowest[fact] = order[successor];
				continue;
			}
			path.pop();
			next.pop();
			successors.pop();
			named.pop();
			if (lowest[fact] == order[fact]) {
				// `fact` heads a component: every member gets the latest change of all of them.
				var start = members.lastIndexOf(fact), change = 0;
				for (index in start...members.length)
					if (latest[members[index]] > change)
						change = latest[members[index]];
				for (index in start...members.length) {
					var member = members[index];
					onPath[member] = false;
					effective[member] = change;
					effectiveIn[member] = revision;
				}
				members.resize(start);
			}
			if (path.length > 0) {
				var parent = path[path.length - 1];
				if (lowest[fact] < lowest[parent])
					lowest[parent] = lowest[fact];
				var change = effectiveIn[fact] == revision ? effective[fact] : latest[fact];
				if (change > latest[parent])
					latest[parent] = change;
			}
		}
		walkReads = null;
		return effective[id];
	}

	/** Puts `fact` on the walk's path, with what it goes through. */
	function enter(fact:Int):Void {
		growWalk(fact);
		visitedIn[fact] = walkEpoch;
		order[fact] = counter;
		lowest[fact] = counter;
		counter++;
		members.push(fact);
		onPath[fact] = true;
		var through = dependencies[fact], declared = true;
		if (aspects[fact] == (FactAspect.Unit:Int)) {
			var record = walkReads == null ? null : walkReads(fact);
			through = record == null ? null : record.facts;
			declared = false;
		}
		latest[fact] = changedAt[fact];
		path.push(fact);
		next.push(0);
		successors.push(through);
		named.push(declared);
	}

	// The walk's stacks, kept between walks so that a walk allocates nothing once they have grown.
	var members:Array<Int> = [];
	var path:Array<Int> = [];
	var next:Array<Int> = [];
	var successors:Array<Null<Array<Int>>> = [];
	var named:Array<Bool> = [];
	var counter = 0;
	var walkReads:Null<(unit:Int) -> Null<UnitReads>> = null;

	// The walk's state per fact, valid where `visitedIn` holds the walk's number.
	var visitedIn:Array<Int> = [];
	var order:Array<Int> = [];
	var lowest:Array<Int> = [];
	var latest:Array<Int> = [];
	var onPath:Array<Bool> = [];
	var walkEpoch = 0;

	function growWalk(fact:Int):Void
		while (visitedIn.length <= fact) {
			visitedIn.push(0);
			order.push(0);
			lowest.push(0);
			latest.push(0);
			onPath.push(false);
		}

	/** Whether a unit typed at `typedAt` that read `facts` is current: nothing it read changed after it was typed. */
	public function current(record:UnitReads, reads:(unit:Int) -> Null<UnitReads>):Bool {
		for (fact in record.facts)
			if (latestChange(fact, reads) > record.typedAt)
				return false;
		return true;
	}

	/**
	 * A fact of `record` that changed after it was typed, for the invalidation report: one that changed itself when there is one,
	 * else one that goes through a change; -1 when the unit is current.
	 */
	public function firstChanged(record:UnitReads, reads:(unit:Int) -> Null<UnitReads>):Int {
		var through = -1;
		for (fact in record.facts)
			if (changedAt[fact] > record.typedAt)
				return fact;
			else if (through < 0 && latestChange(fact, reads) > record.typedAt)
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

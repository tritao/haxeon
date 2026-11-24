package compiler.semantic;

import compiler.semantic.DeclarationFacts.FactAspect;

/** The facts one unit is reading, while it is typed (`DeclarationReads`). */
private class ReadSink {
	public final unit:String;
	public final id:Int;
	public final facts:Array<Int> = [];

	public function new(unit:String, id:Int) {
		this.unit = unit;
		this.id = id;
	}
}

/**
 * Records the facts the unit being typed reads (`DeclarationFacts`): the typer's lookups call `read` or `record`, and reads made
 * outside any unit (the program's set-up) record nothing. A unit typed inside another (a shared unit, a declaration typed on
 * demand) records its own reads, and the unit that needed it reads it as a `Unit` fact.
 */
class DeclarationReads {
	public final facts:DeclarationFacts;

	/** What each unit typed in this session read, by unit. */
	public final units:Map<String, Array<Int>> = [];

	final sinks:Array<ReadSink> = [];
	var sink:Null<ReadSink> = null;

	public function new(facts:DeclarationFacts)
		this.facts = facts;

	/** Whether a unit is being typed, so that a read is recorded. */
	public var recording(get, never):Bool;

	inline function get_recording():Bool
		return sink != null;

	/** Records that the unit being typed read fact `id`. */
	public inline function record(id:Int):Void {
		var current = sink;
		if (current != null && facts.firstRecord(id, current.id))
			current.facts.push(id);
	}

	/** Records that the unit being typed read `aspect` of `name`; a unit's own result is no read of it. */
	public function read(aspect:FactAspect, name:String):Void {
		var current = sink;
		if (current != null && (aspect != FactAspect.Unit || name != current.unit))
			record(facts.id(aspect, name));
	}

	/** Starts recording the reads of `unit`, typed from here until the matching `end`. */
	public function begin(unit:String):Void {
		if (sink != null)
			sinks.push(sink);
		sink = new ReadSink(unit, facts.newSink());
	}

	/** Ends the unit `begin` started last, keeping what it read with what the same unit read before in this session. */
	public function end():Void {
		var done = sink;
		if (done == null)
			throw new compiler.core.InternalError("No unit is recording its reads");
		sink = sinks.length == 0 ? null : sinks.pop();
		var known = units.get(done.unit);
		if (known == null)
			units.set(done.unit, done.facts);
		else {
			var marker = facts.newSink();
			for (fact in known)
				facts.firstRecord(fact, marker);
			for (fact in done.facts)
				if (facts.firstRecord(fact, marker))
					known.push(fact);
		}
		// The unit it was typed inside stays a reader: its stamps are taken again on its next reads.
		var outer = sink;
		if (outer != null)
			for (fact in outer.facts)
				facts.firstRecord(fact, outer.id);
	}

	/** How many units are recording: the one being typed and those it is typed inside. */
	public var depth(get, never):Int;

	function get_depth():Int
		return sink == null ? 0 : sinks.length + 1;

	/** Ends the units recording beyond the first `depth`, as typing returns to where it stood then. */
	public function endTo(depth:Int):Void
		while (this.depth > depth)
			end();

	/** The unit being typed, or null outside every unit. */
	public var unit(get, never):Null<String>;

	function get_unit():Null<String>
		return sink == null ? null : sink.unit;
}

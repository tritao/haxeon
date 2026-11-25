package compiler.semantic;

import compiler.semantic.DeclarationFacts.FactAspect;

/**
 * Records the facts the unit being typed reads (`DeclarationFacts`), each in a recording frame of the facts' query database: the
 * typer's lookups call `read` or `record`, and reads made outside any unit (the program's set-up) record nothing. A unit typed
 * inside another (a shared unit, a declaration typed on demand) records its own reads in a frame of its own, and the unit that
 * needed it reads it as a `Unit` fact.
 */
class DeclarationReads {
	public final facts:DeclarationFacts;

	/** What each unit typed in this session read, by unit. */
	public final units:Map<String, Array<Int>> = [];

	/** The units recording, outermost first; their frames are the database's top ones. */
	final recordingUnits:Array<String> = [];

	final database:compiler.query.QueryDatabase;

	public function new(facts:DeclarationFacts) {
		this.facts = facts;
		database = facts.database;
	}

	/** Whether a unit is being typed, so that a read is recorded. */
	public var recording(get, never):Bool;

	inline function get_recording():Bool
		return recordingUnits.length > 0;

	/** Records that the unit being typed read fact `id`. */
	public inline function record(id:Int):Void
		if (recordingUnits.length > 0)
			database.record(facts, id);

	/** Records that the unit being typed read `aspect` of `name`; a unit's own result is no read of it. */
	public function read(aspect:FactAspect, name:String):Void {
		var depth = recordingUnits.length;
		if (depth > 0 && (aspect != FactAspect.Unit || name != recordingUnits[depth - 1]))
			record(facts.id(aspect, name));
	}

	/** Starts recording the reads of `unit`, typed from here until the matching `end`. */
	public function begin(unit:String):Void {
		recordingUnits.push(unit);
		database.beginRecording();
	}

	/** Ends the unit `begin` started last, keeping what it read with what the same unit read before in this session. */
	public function end():Void {
		var unit = recordingUnits.pop();
		if (unit == null)
			throw new compiler.core.InternalError("No unit is recording its reads");
		var read = database.endRecording(), known = units.get(unit);
		if (known == null)
			units.set(unit, read);
		else {
			// A frame of its own merges the two in order, each fact once, and leaves the outer frame's marks as they were.
			database.beginRecording();
			for (fact in known)
				database.record(facts, fact);
			for (fact in read)
				database.record(facts, fact);
			units.set(unit, database.endRecording());
		}
	}

	/** How many units are recording: the one being typed and those it is typed inside. */
	public var depth(get, never):Int;

	inline function get_depth():Int
		return recordingUnits.length;

	/** Ends the units recording beyond the first `depth`, as typing returns to where it stood then. */
	public function endTo(depth:Int):Void
		while (this.depth > depth)
			end();

	/** The unit being typed, or null outside every unit. */
	public var unit(get, never):Null<String>;

	function get_unit():Null<String>
		return recordingUnits.length == 0 ? null : recordingUnits[recordingUnits.length - 1];
}

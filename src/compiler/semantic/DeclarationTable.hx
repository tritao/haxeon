package compiler.semantic;

import compiler.semantic.DeclarationFacts.FactAspect;

/**
 * Declarations of one kind by canonical name, whose lookups are reads of the unit being typed (`DeclarationReads`): `get`
 * reads the declaration (aspect `aspect`), `exists` reads whether it is there (aspect `presence`: a class's shape, what a
 * reference to it means, or a function's signature), and walking the table
 * reads every declaration of the kind (aspect `Kind`); `readAll` walks them with their names. `entry` and `has` read nothing, for the code that records a narrower
 * read itself (name resolution reads a shape) or that runs outside every unit.
 */
class DeclarationTable<T> {
	final entries:Map<String, T>;
	final aspect:FactAspect;
	final presence:FactAspect;
	final kind:String;

	/** Where reads are recorded; null where nothing records (a program no session types). */
	public var reads:Null<DeclarationReads> = null;

	public function new(aspect:FactAspect, presence:FactAspect, kind:String, ?over:Map<String, T>) {
		entries = over == null ? [] : over;
		this.aspect = aspect;
		this.presence = presence;
		this.kind = kind;
	}

	/** The declaration named `name`, or null: typed as a map's lookup is, which the code that reads it checks. */
	public function get(name:String):T {
		var recorder = reads;
		if (recorder != null && recorder.recording)
			recorder.read(aspect, name);
		return cast entries.get(name);
	}

	public function exists(name:String):Bool {
		var recorder = reads;
		if (recorder != null && recorder.recording)
			recorder.read(presence, name);
		return entries.exists(name);
	}

	/**
	 * The declaration named `name`, for code that reads only what `exists` reads of it (a class's kind and metadata, not its
	 * members): a read of that.
	 */
	public function header(name:String):T {
		var recorder = reads;
		if (recorder != null && recorder.recording)
			recorder.read(presence, name);
		return cast entries.get(name);
	}

	/** The declaration named `name`, which must exist: a read, as `get`. */
	public function required(name:String):T {
		var found = get(name);
		if (found == null)
			throw new compiler.core.InternalError('Missing declaration "$name"');
		return found;
	}

	/** The declaration named `name`, reading nothing. */
	public inline function entry(name:String):T
		return cast entries.get(name);

	/** Whether a declaration is named `name`, reading nothing. */
	public inline function has(name:String):Bool
		return entries.exists(name);

	/**
	 * The declarations as a map, whose lookups read nothing: for an analysis whose answers are facts of their own (purity, never
	 * returns), and for the program's set-up.
	 */
	public inline function withoutReads():Map<String, T>
		return entries;

	public inline function set(name:String, value:T):Void
		entries.set(name, value);

	public inline function remove(name:String):Bool
		return entries.remove(name);

	/** The declarations as a map, read as a whole: what code that searches them all reads. */
	public function readAll():Map<String, T> {
		var recorder = reads;
		if (recorder != null && recorder.recording)
			recorder.read(FactAspect.Kind, kind);
		return entries;
	}

	/** A table with the same declarations, which can be changed without changing this one. */
	public function copy():DeclarationTable<T> {
		var made = new DeclarationTable<T>(aspect, presence, kind);
		for (name => value in entries)
			made.entries.set(name, value);
		made.reads = reads;
		return made;
	}
}

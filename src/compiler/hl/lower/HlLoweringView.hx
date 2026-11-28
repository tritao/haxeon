package compiler.hl.lower;

import compiler.ir.model.Ir.IrObject;

/**
 * The answers lowering's facts were last worked out from, by fact (`IrStageFacts`), typed: an object, or a key's text. The session
 * keeps them with its lowered functions (`HlFunctionQueries`): a fact keeps its value while its answer is the same, and takes another
 * when it is not.
 */
@:nullSafety(Strict)
class HlLoweringAnswers {
	public final objects:Array<Null<IrObject>> = [];
	public final texts:Array<Null<String>> = [];

	public function new() {}
}

/**
 * The only way lowering a function sees an entity other than that function: an object type (its fields, base, methods and value
 * layout), the typed-interface key of a dispatch function, the non-null fields of a class, and the settings it lowers with.
 * Lowering holds neither the program nor the object table, so it reads nothing about them that is not one of these.
 *
 * In a session each read made while a function is lowered is a fact of lowering's space of the session's `IrStageFacts`, read
 * through the database into the memo of what lowering made of the function (`HlFunctionQueries.lowered`), so that memo holds while
 * every fact it read has the value it read. A fact's value is a number that keeps while its answer is the same part by part as the
 * one it was last worked out from (`IrDeclarationEquality.sameObject`, or a text), and changes otherwise.
 */
@:nullSafety(Strict)
class HlLoweringView extends compiler.ir.pipeline.IrFunctionPass.IrFactSource {
	/** The kinds of fact: an object type, the typed-interface key of a dispatch function, the non-null fields of a class, the settings. */
	static inline final OBJECT = 0;

	static inline final TYPED = 1;
	static inline final NON_NULL = 2;
	static inline final SETTINGS = 3;

	static inline final SPACE = "hl-lowering";

	final objects:Map<String, IrObject>;
	final typedKeys:Map<String, String>;

	/** The session's kinds, or null for a lowering that records nothing. */
	final queries:Null<compiler.hl.incremental.HlFunctionQueries>;

	/** What a lowered function depends on besides the program: the build's settings, as one text. */
	final settings:String;

	/** Compare the texts of two objects `sameObject` finds the same, and fail if they differ (`--check-reuse`). */
	final checkObjects:Bool;

	/** The fields of the program never null once constructed, by class (`IrNonNullFields`); null when lowering has none. */
	var nonNullFields:Null<compiler.ir.analysis.IrNonNullFields> = null;

	/** Whether a function is being lowered, whose reads are recorded. */
	var recording = false;

	/** The ids of the facts by kind and key, as `IrStageFacts.id` gave them, so a key is interned once per lowering. */
	final known:Array<Map<String, Int>> = [[], [], [], []];

	/**
	 * A view over `objects` as they are filled in (lowering) or as they stand (a pass asking what lowering would see); with
	 * `queries`, a run of lowering's facts in the session's database, which the functions lowered from here on read.
	 */
	public function new(typedKeys:Map<String, String>, ?objects:Map<String, IrObject>,
			?queries:compiler.hl.incremental.HlFunctionQueries, settings = "", checkObjects = false) {
		this.typedKeys = typedKeys;
		this.objects = objects == null ? [] : objects;
		this.queries = queries;
		this.settings = settings;
		this.checkObjects = checkObjects;
		if (queries != null)
			queries.facts.run(queries.database, SPACE, this);
	}

	/** Makes `object` known: metadata lowering does this while it orders object types, before any fact is read. */
	public function define(object:IrObject):Void
		objects.set(object.name, object);

	/** Starts recording what the function being lowered reads, in the database's frame of its memo. */
	public function beginFunction():Void {
		recording = queries != null;
		read(SETTINGS, "");
	}

	public function endFunction():Void
		recording = false;

	inline function read(kind:Int, name:String):Void
		if (recording)
			record(kind, name);

	function record(kind:Int, name:String):Void {
		var kept = queries;
		if (kept == null)
			return;
		var table = known[kind], id = table.get(name);
		if (id == null) {
			id = kept.facts.id(space, kind, name);
			table.set(name, id);
		}
		kept.facts.read(kept.database, id);
	}

	public function object(name:String):Null<IrObject> {
		read(OBJECT, name);
		return objects.get(name);
	}

	public function hasObject(name:String):Bool
		return object(name) != null;

	/** Gives lowering the program's non-null fields (`nonNullFields`). */
	public function useNonNullFields(fields:compiler.ir.analysis.IrNonNullFields):Void
		nonNullFields = fields;

	/** The fields of class `name` never null once constructed (`IrNonNullFields.fieldsOf`). */
	public function nonNull(name:String):Map<String, Bool> {
		read(NON_NULL, name);
		var fields = nonNullFields;
		return fields == null ? NO_FIELDS : fields.fieldsOf(name);
	}

	@:processWide("an empty set of fields, only ever read")
	static final NO_FIELDS:Map<String, Bool> = [];

	/** The key under which dispatch function `name` registers its method table, or null for any other function. */
	public function typedInterfaceKey(name:String):Null<String> {
		read(TYPED, name);
		return typedKeys.get(name);
	}

	override public function factOf(id:Int, kind:Int, key:String, known:Bool, last:Int):Int {
		var kept = queries;
		if (kept == null)
			return 0;
		var answers = kept.loweringAnswers, objectAnswers = answers.objects, textAnswers = answers.texts;
		while (objectAnswers.length <= id) {
			objectAnswers.push(null);
			textAnswers.push(null);
		}
		if (kind == OBJECT) {
			var before = objectAnswers[id], after = objects.get(key);
			objectAnswers[id] = after;
			if (!known || before == null || after == null)
				return known && before == after ? last : last + 1;
			var same = compiler.ir.model.IrDeclarationEquality.sameObject(before, after);
			if (same && checkObjects && before != after && Std.string(before) != Std.string(after))
				throw new compiler.core
					.InternalError('--check-reuse: object ${after.name} compares the same as the one lowering read, but is not');
			return same ? last : last + 1;
		}
		var fields = nonNullFields,
			text = switch kind {
				case NON_NULL: fields == null ? "" : fields.describe(key);
				case TYPED: typedKeys.get(key);
				case _: settings;
			},
				after = text == null ? "-" : text,
				before = textAnswers[id];
		textAnswers[id] = after;
		return known && before == after ? last : last + 1;
	}
}

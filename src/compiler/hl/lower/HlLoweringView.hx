package compiler.hl.lower;

import compiler.ir.model.Ir.IrObject;
import compiler.ir.reuse.IrFacts;

/**
 * The facts lowering reads (`HlLoweringView`), with the answers their prints were made for, typed: an object, or a key's text. The
 * session keeps them with the lowered functions (`HlLoweredCache`), which the copies of that cache share: a rolled-back build can
 * only make a print newer, never reuse one.
 */
@:nullSafety(Strict)
class HlLoweringFacts {
	public final table = IrFacts.unshared();
	public final objects:Array<Null<IrObject>> = [];
	public final texts:Array<Null<String>> = [];

	public function new() {}
}

/**
 * The only way lowering a function sees an entity other than that function: an object type (its fields, base, methods and value
 * layout) or the typed-interface key of a dispatch function. Every read is recorded as a fact with its print (`IrFacts`, answer
 * facts: an object compares part by part, `IrDeclarationEquality.sameObject`), so a lowered function carries the exact list of
 * outside facts it depends on, and a later build can ask whether they still hold before it keeps the function. Lowering holds
 * neither the program nor the object table, so a fact cannot be read without being recorded. A fact is worked out at most once
 * per lowering.
 */
@:nullSafety(Strict)
class HlLoweringView extends compiler.ir.reuse.IrFacts.IrAnswerSource {
	/** The kinds of fact: an object type, the typed-interface key of a dispatch function, the non-null fields of a class. */
	static inline final OBJECT = 0;

	static inline final TYPED = 1;
	static inline final NON_NULL = 2;

	static inline final SPACE = "hl-lowering";

	final objects:Map<String, IrObject>;
	final typedKeys:Map<String, String>;
	final facts:IrFacts;
	final answers:HlLoweringFacts;

	/** The table's space of each kind. */
	final spaces:Array<Int>;

	/** Compare the texts of two objects `sameObject` finds the same, and fail if they differ (`--check-reuse`). */
	final checkObjects:Bool;

	/** The fields of the program never null once constructed, by class (`IrNonNullFields`); null when lowering has none. */
	var nonNullFields:Null<compiler.ir.analysis.IrNonNullFields> = null;
	var reads:Null<Array<Int>>;
	var readMarks:Map<Int, Bool> = [];

	/**
	 * A view over `objects` as they are filled in (lowering) or as they stand (a pass asking what lowering would see), numbering its
	 * facts in `facts` (the session's, or its own).
	 */
	public function new(typedKeys:Map<String, String>, ?objects:Map<String, IrObject>, ?facts:HlLoweringFacts,
			checkObjects = false) {
		super();
		this.typedKeys = typedKeys;
		this.objects = objects == null ? [] : objects;
		var kept = facts == null ? new HlLoweringFacts() : facts, table = kept.table;
		answers = kept;
		this.facts = table;
		this.checkObjects = checkObjects;
		spaces = [for (kind in 0...3) table.space(SPACE, kind)];
		table.begin();
	}

	/** Makes `object` known: metadata lowering does this while it orders object types, before any fact is read. */
	public function define(object:IrObject):Void
		objects.set(object.name, object);

	public function beginFunction():Void {
		reads = [];
		readMarks = [];
	}

	/** The facts read since `beginFunction`, as pairs of a fact and its print. */
	public function endFunction():Array<Int> {
		var facts = reads == null ? [] : reads;
		reads = null;
		return facts;
	}

	function read(kind:Int, name:String):Void {
		var list = reads;
		if (list != null) {
			var id = facts.id(spaces[kind], kind, name);
			if (!readMarks.exists(id)) {
				readMarks.set(id, true);
				list.push(id);
				list.push(facts.printAnswer(id, this));
			}
		}
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

	override public function settle(id:Int, kind:Int, name:String, known:Bool):Bool {
		var objectAnswers = answers.objects, textAnswers = answers.texts;
		while (objectAnswers.length <= id) {
			objectAnswers.push(null);
			textAnswers.push(null);
		}
		if (kind == OBJECT) {
			var before = objectAnswers[id], after = objects.get(name);
			objectAnswers[id] = after;
			if (!known || before == null || after == null)
				return known && before == after;
			var same = compiler.ir.model.IrDeclarationEquality.sameObject(before, after);
			if (same && checkObjects && before != after && Std.string(before) != Std.string(after))
				throw new compiler.core
					.InternalError('--check-reuse: object ${after.name} compares the same as the one lowering read, but is not');
			return same;
		}
		var fields = nonNullFields,
			key = kind == NON_NULL ? (fields == null ? "" : fields.describe(name)) : typedKeys.get(name),
			after = key == null ? "-" : key,
			before = textAnswers[id];
		textAnswers[id] = after;
		return known && before == after;
	}

	/** Null when every fact of `facts` (pairs of a fact and a print) still has its print, else the first that does not. */
	public function holds(read:Array<Int>):Null<String> {
		var index = 0;
		while (index < read.length) {
			if (facts.printAnswer(read[index], this) != read[index + 1])
				return facts.describe(read[index]);
			index += 2;
		}
		return null;
	}
}

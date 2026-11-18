package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.semantic.SemanticSignature;
import compiler.types.Monomorphs;
import compiler.types.Type.AnonymousField;
import compiler.types.Type.CompilerType;
import compiler.types.Type.MonomorphCell;
import compiler.types.TypeRelations;
import compiler.types.analysis.ClosureConversion.ClosureConversionMark;

/**
 * The structure of an object literal typed without an expected structure, while its unit is typed: open, as Haxe's `Const`
 * structures are, it gains the optional fields of the structures it meets (`MonomorphFrames.gain`), in place, for every alias of
 * it. Its type is `TAnonymous(name, fields)` with a provisional `name` and this very `fields` array. It is closed when its frame is
 * settled: it gets its name from its final fields and is registered then (docs/design/STRUCTURE_VALUES.md, "Open literal
 * structures").
 */
class OpenStructure {
	/** The provisional name (`Monomorphs.OPEN_STRUCTURE_PREFIX`), never emitted. */
	public final name:String;

	/** The fields, sorted by name; shared by every alias of the structure. */
	public final fields:Array<AnonymousField>;

	public final span:SourceSpan;

	/** The frame of the body that wrote the literal, which owns it. */
	public final frame:MonomorphFrame;

	/** The closed type, once closed: the same `fields`, named after them. */
	public var closed:Null<CompilerType> = null;

	/**
	 * Whether the structure has been converted to another structure type: the value is then a record of that type's fields, so it gains
	 * no more fields (a wider record standing for a narrower structure waits for structure views, STRUCTURE_VALUES.md slice 4).
	 */
	public var pinned = false;

	/**
	 * The fields read or written through the structure so far: their typed uses have the field's type, so it no longer turns
	 * optional when a structure declaring it optional is met (`MonomorphFrames.gain`).
	 */
	public final usedFields:Map<String, Bool> = [];

	public function new(name:String, fields:Array<AnonymousField>, span:SourceSpan, frame:MonomorphFrame) {
		this.name = name;
		this.fields = fields;
		this.span = span;
		this.frame = frame;
	}
}

/** The type variables one function body made, and what it added that may mention them. */
class MonomorphFrame {
	public final cells:Array<MonomorphCell> = [];

	/** The object literals the body wrote without an expected structure, open until the frame is settled. */
	public final literals:Array<OpenStructure> = [];

	/**
	 * The unannotated declaration whose type the body gives (`"Main.make"`), and whether it is a field: a literal of the frame that
	 * reaches that type is closed with the unit, so a use elsewhere that would add a field to it asks for an annotation instead.
	 */
	public var declaration:Null<String> = null;

	public var declarationIsField = false;

	/** Where the closure conversion stood when the body began: what comes after is the body's lambdas and cells. */
	public final conversionMark:ClosureConversionMark;

	/** The lambda cache entries the body made, which hold its lambdas' types. */
	public final lambdaKeys:Array<String> = [];

	/** Checks that need a type variable's type, run when the body is typed and they are filled. */
	public final deferred:Array<Void->Void> = [];

	public function new(conversionMark:ClosureConversionMark)
		this.conversionMark = conversionMark;
}

/**
 * The type variables (`Monomorphs`) of the function bodies being typed, innermost last. A body begins a frame; the type
 * variables made while it is typed, its lambdas' included, belong to it, and are settled when it ends.
 */
class MonomorphFrames {
	final frames:Array<MonomorphFrame> = [];

	/** The open structures by provisional name, kept once closed so that a late read of a provisional name finds its closed type. */
	final structures:Map<String, OpenStructure> = [];

	/** How many structures are open in the frames being typed: none means no type can mention one. */
	var openCount = 0;

	var structureCount = 0;

	/** The declaration whose unit closed each literal structure that reached an unannotated declaration's type, by its fields. */
	final literalOrigins = new haxe.ds.ObjectMap<Dynamic, {declaration:String, isField:Bool}>();

	/** Registers a structure once it is closed (`AnonymousTypeRegistry.register`), in the unit being typed. */
	final register:CompilerType->Void;

	public function new(register:CompilerType->Void)
		this.register = register;

	public function begin(conversionMark:ClosureConversionMark):MonomorphFrame {
		var frame = new MonomorphFrame(conversionMark);
		frames.push(frame);
		return frame;
	}

	/** Ends `frame`, and any frame left open inside it by a body whose typing failed. */
	public function end(frame:MonomorphFrame):Void {
		var index = frames.indexOf(frame);
		if (index >= 0)
			frames.splice(index, frames.length - index);
	}

	/** How many frames are open: a mark to `discardFrom`. */
	public function depth():Int
		return frames.length;

	/**
	 * Ends the frames from `depth` on, of bodies whose typing failed, and makes each of their type variables that nothing filled
	 * Dynamic, so that none is left open in whatever the failed typing wrote before it stopped.
	 */
	public function discardFrom(depth:Int):Void {
		if (depth >= frames.length)
			return;
		for (index in depth...frames.length) {
			for (cell in frames[index].cells)
				if (compiler.types.Monomorphs.isUnbound(TMonomorph(cell)))
					compiler.types.Monomorphs.unify(TMonomorph(cell), TDynamic);
			// What the failed typing wrote is dropped: its structures are closed, and not registered.
			for (structure in frames[index].literals)
				closeStructure(structure, [], false);
		}
		frames.splice(depth, frames.length - depth);
	}

	/** Discards `frame` and any frame left open inside it (see `discardFrom`). */
	public function discard(frame:MonomorphFrame):Void {
		var index = frames.indexOf(frame);
		if (index >= 0)
			discardFrom(index);
	}

	/**
	 * A new type variable standing for `origin` (`the type of local "x"`), or null where no body is being typed (a field
	 * initializer, a generated helper), which has no frame to settle one. One that `mustBeFixed` is an error when nothing
	 * fills it; any other becomes Dynamic.
	 */
	public function create(origin:String, span:SourceSpan, mustBeFixed:Bool = false):Null<CompilerType> {
		var frame = frames.length == 0 ? null : frames[frames.length - 1];
		if (frame == null)
			return null;
		var cell = new MonomorphCell(origin, span, mustBeFixed);
		frame.cells.push(cell);
		return TMonomorph(cell);
	}

	/**
	 * Whether nothing but the value written at `span` can carry the empty type variable `cell`: it was made in that expression (an
	 * empty literal's element type), no local's type holds it, and no other type variable is filled with a type that mentions it.
	 * Nothing after that value is used can then fill it, so it is Dynamic already, as settling its frame would make it.
	 */
	public function carriedOnlyBy(cell:MonomorphCell, span:SourceSpan):Bool {
		if (cell.mustBeFixed || cell.localName != null || cell.span.file != span.file || cell.span.start < span.start
			|| cell.span.end > span.end)
			return false;
		for (frame in frames)
			for (other in frame.cells)
				if (other != cell && other.bound != null && compiler.types.Monomorphs.mentions(cell, other.bound))
					return false;
		return true;
	}

	/** Whether a body is being typed, which can settle the type variables made in it. */
	public function canCreate():Bool
		return frames.length > 0;

	/**
	 * Whether a body being typed has made a type variable: only then can a type met mention one. A lambda's body can meet one of
	 * the body around it (a callback's result, `CallResolver.openResult`).
	 */
	public function active():Bool {
		for (frame in frames)
			if (frame.cells.length > 0)
				return true;
		return false;
	}

	/**
	 * Runs `check` once the types it needs are known: now when `type` mentions no empty type variable, otherwise when the
	 * innermost body has been typed (and the variable filled, or reported).
	 */
	public function whenKnown(type:CompilerType, check:Void->Void):Void {
		if (frames.length == 0 || !compiler.types.Monomorphs.containsUnbound(type) && !mentionsOpen(type))
			check();
		else
			frames[frames.length - 1].deferred.push(check);
	}

	/**
	 * The type of an object literal with `fields` (sorted by name) written at `span` without an expected structure: an open
	 * structure of the innermost body, or null where no body is being typed (a generated helper), whose literal is closed at once.
	 */
	public function openStructure(fields:Array<AnonymousField>, span:SourceSpan):Null<CompilerType> {
		var frame = frames.length == 0 ? null : frames[frames.length - 1];
		if (frame == null)
			return null;
		var structure = new OpenStructure(Monomorphs.OPEN_STRUCTURE_PREFIX + structureCount++, fields, span, frame);
		structures.set(structure.name, structure);
		frame.literals.push(structure);
		openCount++;
		return TAnonymous(structure.name, fields);
	}

	/**
	 * Adds to each open structure of the innermost body in `actual` the optional fields of the structure it meets at the same place in
	 * `expected` that it lacks, as Haxe's unification adds them to a `Const` structure: at the top, inside a nullable, an `Array`
	 * or another type's parameters, a structure's fields, and a function type's arguments (the other way) and result. A field it
	 * lacks that is required is not added: the conversion reports it. Returns whether a field was added.
	 */
	public function gain(actual:CompilerType, expected:CompilerType):Bool {
		if (openCount == 0)
			return false;
		var gained = gainWithin(actual, expected, []);
		pinWithin(actual, expected, []);
		return gained;
	}

	function gainWithin(actual:CompilerType, expected:CompilerType, visiting:Array<Array<AnonymousField>>):Bool {
		var left = Monomorphs.follow(actual), right = Monomorphs.follow(expected);
		return switch [left, right] {
			case [TAnonymous(name, _), TAnonymous(_, expectedFields)] if (Monomorphs.isOpenStructureName(name)):
				var structure = structures.get(name);
				if (structure == null || structure.closed != null || structure.fields == expectedFields
					|| !ownedByInnermost(structure) || visiting.indexOf(structure.fields) >= 0)
					return false;
				visiting.push(structure.fields);
				var gained = false;
				for (field in expectedFields) {
					var own = fieldNamed(structure.fields, field.name);
					if (own != null) {
						// A field both have meets the other's type: its own literal structures gain too, and its type variables fill.
						Monomorphs.unify(own.type, field.type);
						if (gainWithin(own.type, field.type, visiting))
							gained = true;
						if (becomesOptional(structure, own, field)) {
							replaceField(structure.fields, own, field.type);
							gained = true;
						}
					} else if (field.optional && !structure.pinned) {
						insertField(structure.fields, field);
						gained = true;
					}
				}
				gained;
			case [TNullable(a), TNullable(b)], [TArray(a), TArray(b)], [TIterator(a), TIterator(b)]: gainWithin(a, b,
				visiting);
			case [_, TNullable(b)]: gainWithin(left, b, visiting);
			case [TMap(k1, v1), TMap(k2, v2)]:
				var key = gainWithin(k1, k2, visiting);
				gainWithin(v1, v2, visiting) || key;
			case [TInstance(_, n1, a1), TInstance(_, n2, a2)] if ((n1:String) == (n2:String) && a1.length == a2.length):
				var gained = false;
				for (index in 0...a1.length)
					if (gainWithin(a1[index], a2[index], visiting))
						gained = true;
				gained;
			case [TFunction(a1, r1, _), TFunction(a2, r2, _)] if (a1.length == a2.length):
				var gained = gainWithin(r1, r2, visiting);
				for (index in 0...a1.length)
					if (gainWithin(a2[index], a1[index], visiting))
						gained = true;
				gained;
			default: false;
		};
	}

	/** Pins each open structure of `actual` that meets another structure in `expected`, and an open one it meets (`OpenStructure.pinned`). */
	function pinWithin(actual:CompilerType, expected:CompilerType, visiting:Array<Array<AnonymousField>>):Void {
		var left = Monomorphs.follow(actual), right = Monomorphs.follow(expected);
		switch [left, right] {
			case [TAnonymous(leftName, leftFields), TAnonymous(rightName, rightFields)]:
				if (leftFields == rightFields || visiting.indexOf(leftFields) >= 0)
					return;
				visiting.push(leftFields);
				for (name in [leftName, rightName])
					if (Monomorphs.isOpenStructureName(name)) {
						var structure = structures.get(name);
						if (structure != null)
							structure.pinned = true;
					}
				for (field in rightFields) {
					var own = fieldNamed(leftFields, field.name);
					if (own != null)
						pinWithin(own.type, field.type, visiting);
				}
			case [TNullable(a), TNullable(b)], [TArray(a), TArray(b)],
				[TIterator(a), TIterator(b)]: pinWithin(a, b, visiting);
			case [_, TNullable(b)]: pinWithin(left, b, visiting);
			case [TMap(k1, v1), TMap(k2, v2)]:
				pinWithin(k1, k2, visiting);
				pinWithin(v1, v2, visiting);
			case [TInstance(_, n1, a1), TInstance(_, n2, a2)] if ((n1:String) == (n2:String) && a1.length == a2.length):
				for (index in 0...a1.length)
					pinWithin(a1[index], a2[index], visiting);
			case [TFunction(a1, r1, _), TFunction(a2, r2, _)] if (a1.length == a2.length):
				pinWithin(r1, r2, visiting);
				for (index in 0...a1.length)
					pinWithin(a2[index], a1[index], visiting);
			default:
		}
	}

	/**
	 * Whether the field `own` the open `structure` has turns optional where it meets the optional field `expected` of the same type
	 * (or its nullable): Haxe converts a required field to an optional one, and the literal's record must be the other structure's
	 * (`{name: n, optional: flag}` passed as `Array<AstArgument>`). The literal's own values are wrapped when it closes
	 * (`TypedTypeMap`); a field already read or written through the structure keeps its type.
	 */
	static function becomesOptional(structure:OpenStructure, own:AnonymousField, expected:AnonymousField):Bool
		return expected.optional && !own.optional && !structure.pinned && !structure.usedFields.exists(own.name)
			&& (TypeRelations.equals(own.type, expected.type)
			|| TypeRelations.equals(TNullable(own.type), expected.type));

	static function replaceField(fields:Array<AnonymousField>, own:AnonymousField, type:CompilerType):Void
		fields[fields.indexOf(own)] = {
			name: own.name,
			type: type,
			optional: true,
			isFinal: own.isFinal
		};

	/** Notes that the field `field` of the structure named `name` is read or written, if it is an open structure. */
	public function noteFieldUse(name:String, field:String):Void
		if (Monomorphs.isOpenStructureName(name)) {
			var structure = structures.get(name);
			if (structure != null && structure.closed == null)
				structure.usedFields.set(field, true);
		}

	function ownedByInnermost(structure:OpenStructure):Bool
		return frames.length > 0 && frames[frames.length - 1] == structure.frame;

	static function fieldNamed(fields:Array<AnonymousField>, name:String):Null<AnonymousField> {
		for (field in fields)
			if (field.name == name)
				return field;
		return null;
	}

	/** Inserts `field` into `fields`, which stay sorted by name. */
	static function insertField(fields:Array<AnonymousField>, field:AnonymousField):Void {
		var index = 0;
		while (index < fields.length && Reflect.compare(fields[index].name, field.name) < 0)
			index++;
		fields.insert(index, {
			name: field.name,
			type: field.type,
			optional: true,
			isFinal: field.isFinal
		});
	}

	/** Whether `type` mentions an open structure (or one closed since, by its provisional name). */
	public function mentionsOpen(type:CompilerType):Bool
		return structureCount > 0 && mentionsOpenWithin(type);

	static function mentionsOpenWithin(type:CompilerType):Bool
		return switch type {
			case TAnonymous(name, _): Monomorphs.isOpenStructureName(name);
			case TMonomorph(cell): cell.bound != null && mentionsOpenWithin(cell.bound);
			case TNullable(element), TArray(element), TIterator(element): mentionsOpenWithin(element);
			case TMap(key, value), TKeyPath(key, value, _): mentionsOpenWithin(key) || mentionsOpenWithin(value);
			case TFunction(arguments, result, _):
				if (mentionsOpenWithin(result))
					return true;
				for (argument in arguments)
					if (mentionsOpenWithin(argument))
						return true;
				false;
			case TInstance(_, _, arguments):
				for (argument in arguments)
					if (mentionsOpenWithin(argument))
						return true;
				false;
			case TAbstract(_, arguments, representation):
				if (mentionsOpenWithin(representation))
					return true;
				for (argument in arguments)
					if (mentionsOpenWithin(argument))
						return true;
				false;
			default: false;
		};

	/**
	 * `type` with its type variables resolved and each structure closed since replaced by its closed type: what a type made in a
	 * settled frame is from then on. A structure still open is kept, as its own object (`OpenStructure.fields`).
	 */
	public function settled(type:CompilerType):CompilerType {
		var resolved = Monomorphs.resolve(type);
		return mentionsOpen(resolved) ? replaceStructures(resolved, false, []) : resolved;
	}

	/**
	 * Closes now each open structure `type` reaches, and returns `type` with them replaced by their closed types: for a type that
	 * leaves the unit before its end (a generic specialization's type arguments), which must not change after.
	 */
	public function closeReached(type:CompilerType):CompilerType {
		var resolved = Monomorphs.resolve(type);
		return mentionsOpen(resolved) ? replaceStructures(resolved, true, []) : resolved;
	}

	function replaceStructures(type:CompilerType, close:Bool, closing:Array<OpenStructure>):CompilerType {
		function each(types:Array<CompilerType>):Array<CompilerType>
			return [for (part in types) replaceStructures(part, close, closing)];
		return switch type {
			case TAnonymous(name, _) if (Monomorphs.isOpenStructureName(name)):
				var structure = structures.get(name);
				if (structure == null)
					throw new compiler.core.InternalError('Unknown open structure "$name"');
				if (structure.closed != null)
					structure.closed;
				else if (close)
					closeStructure(structure, closing, true);
				else
					TAnonymous(name, structure.fields);
			case TMonomorph(cell): cell.bound == null ? type : replaceStructures(cell.bound, close, closing);
			case TNullable(element): TNullable(replaceStructures(element, close, closing));
			case TArray(element): TArray(replaceStructures(element, close, closing));
			case TIterator(element): TIterator(replaceStructures(element, close, closing));
			case TMap(key, value): TMap(replaceStructures(key, close, closing),
				replaceStructures(value, close, closing));
			case TKeyPath(root, value, writable): TKeyPath(replaceStructures(root, close, closing),
				replaceStructures(value, close, closing), writable);
			case TFunction(arguments, result, optional): TFunction(each(arguments), replaceStructures(result, close,
				closing), optional);
			case TInstance(kind, name, arguments): TInstance(kind, name, each(arguments));
			case TAbstract(name, arguments, representation): TAbstract(name, each(arguments),
				replaceStructures(representation, close, closing));
			default: type;
		};
	}

	/**
	 * Closes `structure`: its field types are resolved and the structures they reach closed first, in place, then it is named after
	 * its final fields (`SemanticSignature.anonymousTypeName`) and, when `registered`, registered in the unit being typed.
	 */
	function closeStructure(structure:OpenStructure, closing:Array<OpenStructure>, registered:Bool):CompilerType {
		var closed = structure.closed;
		if (closed != null)
			return closed;
		// A type variable is never filled with a type that reaches it (`Monomorphs.occurs`), so no structure reaches itself.
		if (closing.indexOf(structure) >= 0)
			throw new compiler.core.InternalError('Open structure "${structure.name}" contains itself');
		closing.push(structure);
		var fields = structure.fields;
		for (index in 0...fields.length) {
			var field = fields[index];
			if (!Monomorphs.contains(field.type) && !mentionsOpenWithin(field.type))
				continue;
			var type = replaceStructures(Monomorphs.resolve(field.type), true, closing);
			fields[index] = {
				name: field.name,
				type: type,
				optional: field.optional,
				isFinal: field.isFinal
			};
		}
		closing.remove(structure);
		closed = TAnonymous(SemanticSignature.anonymousTypeName(fields), fields);
		structure.closed = closed;
		openCount--;
		if (registered)
			register(closed);
		return closed;
	}

	/**
	 * Closes the literal structures of `frame`, which is being settled, in the order they were written. Those that reach the type the
	 * frame gives its declaration remember it, for the diagnostic of a use elsewhere that would add a field (`literalOrigin`).
	 */
	public function closeFrame(frame:MonomorphFrame):Void {
		for (structure in frame.literals)
			closeStructure(structure, [], true);
	}

	/** Records that the literal structures `type` reaches were closed with the unit of `frame`'s unannotated declaration. */
	public function recordDeclarationType(frame:MonomorphFrame, type:CompilerType):Void {
		var declaration = frame.declaration;
		if (declaration == null || frame.literals.length == 0)
			return;
		var origin = {declaration: declaration, isField: frame.declarationIsField};
		for (structure in frame.literals)
			if (structure.closed != null && reaches(type, structure.fields, []))
				literalOrigins.set(structure.fields, origin);
	}

	static function reaches(type:CompilerType, fields:Array<AnonymousField>, visiting:Array<Array<AnonymousField>>):Bool
		return switch type {
			case TAnonymous(_, own):
				if (own == fields)
					return true;
				if (visiting.indexOf(own) >= 0)
					return false;
				visiting.push(own);
				for (field in own)
					if (reaches(field.type, fields, visiting))
						return true;
				false;
			case TNullable(element), TArray(element), TIterator(element): reaches(element, fields, visiting);
			case TMap(key, value),
				TKeyPath(key, value, _): reaches(key, fields, visiting) || reaches(value, fields, visiting);
			case TFunction(arguments, result, _):
				if (reaches(result, fields, visiting))
					return true;
				for (argument in arguments)
					if (reaches(argument, fields, visiting))
						return true;
				false;
			case TInstance(_, _, arguments), TAbstract(_, arguments, _):
				for (argument in arguments)
					if (reaches(argument, fields, visiting))
						return true;
				false;
			default: false;
		};

	/** The declaration whose unit closed the literal structure with `fields`, if one did (`recordDeclarationType`). */
	public function literalOrigin(fields:Array<AnonymousField>):Null<{declaration:String, isField:Bool}>
		return literalOrigins.get(fields);

	/** Notes a lambda cache entry the innermost body made, so its types are settled with the body's. */
	public function recordLambda(key:String):Void
		if (frames.length > 0)
			frames[frames.length - 1].lambdaKeys.push(key);
}

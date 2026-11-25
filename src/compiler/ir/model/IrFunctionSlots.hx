package compiler.ir.model;

/** What a slot a function remembers is valid for (`IrFunctionSlots`): one numbering, until it frees a slot. */
class IrSlotEpoch {
	public function new() {}
}

/**
 * A dense number per function name, for the tables a session keeps per function (`IrLineage`, `IrStageMemo`): a function
 * remembers its slot, so a function object the session keeps from build to build is never looked up by name again. A slot is
 * freed only when its name is gone (`free`); a freed slot is given to the next new name, and every function remembering a slot
 * looks its name up again, since the numbering moves to a new epoch.
 */
@:nullSafety(Strict)
@:allow(compiler.ir.model.IrFunction)
class IrFunctionSlots {
	final byName:Map<String, Int> = [];

	/** By slot, its name; null for a free slot. */
	final names:Array<Null<String>> = [];

	final freed:Array<Int> = [];
	var epoch = new IrSlotEpoch();

	public function new() {}

	/** How many slots there are, free ones included: every slot is below it. */
	public var count(get, never):Int;

	inline function get_count():Int
		return names.length;

	/** The slot of `fn`'s name, given now when the name has none. Inline: the stages ask it for every function they read. */
	public inline function of(fn:IrFunction):Int
		return fn.slotEpoch == epoch ? fn.slot : lookUp(fn);

	function lookUp(fn:IrFunction):Int {
		var slot = named(fn.name);
		fn.slot = slot;
		fn.slotEpoch = epoch;
		return slot;
	}

	/** The slot of `fn`'s name, or -1 when the name has none. */
	public function known(fn:IrFunction):Int {
		if (fn.slotEpoch == epoch)
			return fn.slot;
		var slot = byName.get(fn.name);
		if (slot == null)
			return -1;
		fn.slot = slot;
		fn.slotEpoch = epoch;
		return slot;
	}

	/** The slot of `name`, given now when it has none. */
	public function named(name:String):Int {
		var known = byName.get(name);
		if (known != null)
			return known;
		var slot = freed.pop();
		if (slot == null) {
			slot = names.length;
			names.push(name);
		} else
			names[slot] = name;
		byName.set(name, slot);
		return slot;
	}

	/** The slot of `name`, or -1 when it has none. */
	public function knownNamed(name:String):Int {
		var known = byName.get(name);
		return known == null ? -1 : known;
	}

	/** Whether `slot` is given to a name. */
	public inline function used(slot:Int):Bool
		return names[slot] != null;

	/** Frees `slots`, whose names are gone: the functions that remember a slot look their names up again. */
	public function free(slots:Array<Int>):Void {
		if (slots.length == 0)
			return;
		for (slot in slots) {
			var name = names[slot];
			if (name == null)
				continue;
			byName.remove(name);
			names[slot] = null;
			freed.push(slot);
		}
		epoch = new IrSlotEpoch();
	}
}

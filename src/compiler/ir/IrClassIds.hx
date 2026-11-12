package compiler.ir;

/**
 * Dense class ids for the interface dispatch tables (docs/INTERFACE_VALUES.md). The ids are persistent state of a live session:
 *
 * - a class that had an id keeps it, as long as the session lives;
 * - a class without one takes the next free id, in the order of the stable class identity (its name), never in declaration order or the order
 *   a map happens to iterate;
 * - the id of a removed class leaves a hole and is never reused within the session (`next` only grows).
 *
 * A cold build starts from nothing: every class takes its id by name order. A live session's ids can differ from a fresh cold build's exactly
 * because the state carries them; the check that a warm build equals a cold one therefore starts the cold build from the same state
 * (`IrClassIds.assign` with the warm build's state), and a separate check compares a state-free cold build with another for determinism.
 */
class IrClassIds {
	/** The ids of `classes` given the `previous` assignment (null for a cold build) and the next free id it had reached. */
	public static function assign(previous:Null<IrClassIdState>, classes:Array<String>):IrClassIdState {
		var ids:Map<String, Int> = [], next = 0;
		if (previous != null) {
			next = previous.next;
			for (name => id in previous.ids)
				ids.set(name, id);
		}
		var fresh = [for (name in classes) if (!ids.exists(name)) name];
		fresh.sort(function(left, right) return left < right ? -1 : left > right ? 1 : 0);
		for (name in fresh) {
			ids.set(name, next);
			next++;
		}
		return {ids: ids, next: next};
	}

	/** The ids of the classes that exist, as a map for `IrProgram.classIds` (removed classes are not listed, their ids stay burnt in `next`). */
	public static function liveIds(state:IrClassIdState, classes:Array<String>):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (name in classes) {
			var id = state.ids.get(name);
			if (id == null)
				throw 'Class "$name" has no id';
			result.set(name, id);
		}
		return result;
	}
}

/** The persistent class ids: every id handed out in the session (also those of removed classes) and the next free one. */
typedef IrClassIdState = {
	final ids:Map<String, Int>;
	final next:Int;
}

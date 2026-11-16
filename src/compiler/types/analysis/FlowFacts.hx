package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;

/** The facts one branch records. */
private class FactTables {
	public final assignmentTypes:Map<String, Null<CompilerType>> = [];
	public final refinedTypes:Map<String, CompilerType> = [];
	public final stableRefinedTypes:Map<String, CompilerType> = [];
	public final invalidated:Map<String, Bool> = [];
	public final invalidatedPrefixes:Array<String> = [];
	public final invalidatedNamespaces:Array<String> = [];
	public final erasedNamespaces:Array<String> = [];
	public final erasedMentions:Array<String> = [];
	public final invalidatedFields:Array<String> = [];

	public function new() {}
}

/** Branch-local facts keyed by resolved binding identity. */
class FlowFacts {
	final parent:Null<FlowFacts>;
	var invalidationSink:Null<FlowFacts>;

	/** Most branches record no fact, so a branch's tables are made with its first one (`own`); until then it has none. */
	var tables:Null<FactTables> = null;

	/** The namespace of facts about expression paths. */
	static inline final EXPRESSION_PREFIX = "$expression:";

	/** Whether `bindingId` is `prefix` or a path below it (`prefix.`...), without making `prefix + "."`. */
	static function isUnder(bindingId:String, prefix:String):Bool
		return bindingId == prefix
			|| (bindingId.length > prefix.length
			&& bindingId.charCodeAt(prefix.length) == 46
			&& StringTools.startsWith(bindingId, prefix));

	public function new(?parent:FlowFacts) {
		this.parent = parent;
		invalidationSink = parent == null ? null : parent.invalidationSink;
	}

	/** This branch's tables, made on the first fact it records. */
	function own():FactTables {
		var current = tables;
		if (current == null) {
			current = new FactTables();
			tables = current;
		}
		return current;
	}

	/** Keep all invalidations, including those later hidden by a new refinement, for exceptional exits. */
	public function trackInvalidations():FlowFacts {
		var summary = new FlowFacts();
		summary.invalidationSink = invalidationSink;
		invalidationSink = summary;
		return summary;
	}

	/** Retain the type guaranteed by every assignment; null denotes an unknown write. */
	function captureWrite(bindingId:String, type:Null<CompilerType>):Void {
		var facts = own();
		facts.invalidated.set(bindingId, true);
		if (!facts.assignmentTypes.exists(bindingId))
			facts.assignmentTypes.set(bindingId, type);
		else {
			var previous = facts.assignmentTypes.get(bindingId);
			if (previous == null || type == null || !TypeRelations.equals(previous, type))
				facts.assignmentTypes.set(bindingId, null);
		}
		if (invalidationSink != null)
			invalidationSink.captureWrite(bindingId, type);
	}

	public function recordAssignment(bindingId:String, type:CompilerType):Void {
		if (invalidationSink != null)
			invalidationSink.captureWrite(bindingId, type);
	}

	public function applyInvalidations(summary:FlowFacts):Void {
		var recorded = summary.tables;
		if (recorded == null)
			return;
		var preserved:Map<String, CompilerType> = [];
		for (key in recorded.assignmentTypes.keys()) {
			var assigned = recorded.assignmentTypes.get(key),
				entry = resolve(key);
			// Replacing a non-null local with another non-null value keeps its type, but not its field facts.
			if (!StringTools.startsWith(key, "$expression:")
				&& assigned != null
				&& entry != null
				&& TypeRelations.equals(entry, assigned))
				preserved.set(key, entry);
		}
		// These effects were already recorded in enclosing tries; replaying them is not a new unknown write.
		var outerSink = invalidationSink;
		invalidationSink = null;
		for (key in recorded.invalidated.keys())
			invalidate(key);
		for (prefix in recorded.invalidatedPrefixes)
			invalidatePrefix(prefix);
		for (prefix in recorded.invalidatedNamespaces)
			invalidateNamespace(prefix);
		for (prefix in recorded.erasedNamespaces)
			invalidateNamespaceCompletely(prefix);
		for (fragment in recorded.erasedMentions)
			invalidateMentioning(fragment);
		for (field in recorded.invalidatedFields)
			invalidateField(field);
		for (key => type in preserved)
			refine(key, type);
		invalidationSink = outerSink;
	}

	public function refine(bindingId:String, type:CompilerType, stable:Bool = false):Void {
		var facts = own();
		facts.invalidated.remove(bindingId);
		if (stable) {
			facts.refinedTypes.remove(bindingId);
			facts.stableRefinedTypes.set(bindingId, type);
		} else {
			facts.stableRefinedTypes.remove(bindingId);
			facts.refinedTypes.set(bindingId, type);
		}
	}

	public function invalidate(bindingId:String):Void {
		if (invalidationSink != null)
			invalidationSink.captureWrite(bindingId, null);
		var facts = own();
		facts.refinedTypes.remove(bindingId);
		facts.stableRefinedTypes.remove(bindingId);
		facts.invalidated.set(bindingId, true);
	}

	public function resolve(bindingId:String):Null<CompilerType> {
		var facts = tables;
		if (facts != null) {
			if (facts.refinedTypes.exists(bindingId))
				return facts.refinedTypes.get(bindingId);
			if (facts.stableRefinedTypes.exists(bindingId))
				return facts.stableRefinedTypes.get(bindingId);
			for (prefix in facts.invalidatedPrefixes)
				if (isUnder(bindingId, prefix))
					return null;
			if (facts.invalidated.exists(bindingId))
				return null;
			for (prefix in facts.erasedNamespaces)
				if (StringTools.startsWith(bindingId, prefix))
					return null;
			if (mentionsErased(facts, bindingId))
				return null;
			for (prefix in facts.invalidatedNamespaces)
				if (StringTools.startsWith(bindingId, prefix))
					return parent == null ? null : parent.resolveStable(bindingId);
			if (mentionsInvalidatedField(facts, bindingId))
				return parent == null ? null : parent.resolveStable(bindingId);
		}
		var outer = parent;
		return outer == null ? null : outer.resolve(bindingId);
	}

	/**
	 * Adds to `into` each key this branch's own tables name (refined, or forgotten one by one), and returns whether it also
	 * forgot facts wholesale, by path prefix, namespace, field or mention: those name no key, and can hide any expression
	 * fact it inherits. A branch that recorded nothing adds nothing.
	 */
	public function collectOwnKeys(into:Map<String, Bool>):Bool {
		var facts = tables;
		if (facts == null)
			return false;
		for (key in facts.refinedTypes.keys())
			into.set(key, true);
		for (key in facts.stableRefinedTypes.keys())
			into.set(key, true);
		for (key in facts.invalidated.keys())
			into.set(key, true);
		return facts.invalidatedPrefixes.length > 0
			|| facts.invalidatedNamespaces.length > 0
			|| facts.erasedNamespaces.length > 0
			|| facts.erasedMentions.length > 0
			|| facts.invalidatedFields.length > 0;
	}

	/** Whether this branch recorded no fact of its own. */
	public function recordsNothing():Bool
		return tables == null;

	/** All fact keys visible from this branch, including facts inherited from its parent. */
	public function keys():Array<String> {
		var result:Array<String> = [], seen:Map<String, Bool> = [];
		collectKeys(result, seen);
		return result;
	}

	function collectKeys(result:Array<String>, seen:Map<String, Bool>):Void {
		if (parent != null)
			parent.collectKeys(result, seen);
		var facts = tables;
		if (facts == null)
			return;
		for (key in facts.refinedTypes.keys())
			if (!seen.exists(key)) {
				seen.set(key, true);
				result.push(key);
			}
		for (key in facts.stableRefinedTypes.keys())
			if (!seen.exists(key)) {
				seen.set(key, true);
				result.push(key);
			}
		for (key in facts.invalidated.keys())
			if (!seen.exists(key)) {
				seen.set(key, true);
				result.push(key);
			}
	}

	function resolveStable(bindingId:String):Null<CompilerType> {
		var facts = tables;
		if (facts != null) {
			for (prefix in facts.invalidatedPrefixes)
				if (isUnder(bindingId, prefix))
					return null;
			if (facts.invalidated.exists(bindingId))
				return null;
			for (prefix in facts.erasedNamespaces)
				if (StringTools.startsWith(bindingId, prefix))
					return null;
			if (mentionsErased(facts, bindingId))
				return null;
			if (facts.stableRefinedTypes.exists(bindingId))
				return facts.stableRefinedTypes.get(bindingId);
		}
		return parent == null ? null : parent.resolveStable(bindingId);
	}

	/** Whether the visible fact survives calls, including facts inherited through a branch. */
	public function isStable(bindingId:String):Bool {
		if (resolve(bindingId) == null)
			return false;
		var facts = tables;
		if (facts != null) {
			if (facts.refinedTypes.exists(bindingId))
				return false;
			if (facts.stableRefinedTypes.exists(bindingId))
				return true;
			for (prefix in facts.invalidatedNamespaces)
				if (StringTools.startsWith(bindingId, prefix))
					return parent != null && parent.resolveStable(bindingId) != null;
			if (mentionsInvalidatedField(facts, bindingId))
				return parent != null && parent.resolveStable(bindingId) != null;
		}
		return parent != null && parent.isStable(bindingId);
	}

	public function invalidatePrefix(prefix:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidatePrefix(prefix);
		var facts = own();
		for (bindingId in facts.refinedTypes.keys())
			if (isUnder(bindingId, prefix))
				facts.refinedTypes.remove(bindingId);
		for (bindingId in facts.stableRefinedTypes.keys())
			if (isUnder(bindingId, prefix))
				facts.stableRefinedTypes.remove(bindingId);
		facts.invalidatedPrefixes.push(prefix);
	}

	public function invalidateNamespace(prefix:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidateNamespace(prefix);
		var facts = own();
		for (bindingId in facts.refinedTypes.keys())
			if (StringTools.startsWith(bindingId, prefix))
				facts.refinedTypes.remove(bindingId);
		facts.invalidatedNamespaces.push(prefix);
	}

	/** Forgets every fact under `prefix`, including stable ones, in this branch and the branches it extends. */
	public function invalidateNamespaceCompletely(prefix:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidateNamespaceCompletely(prefix);
		var facts = own();
		for (bindingId in facts.refinedTypes.keys())
			if (StringTools.startsWith(bindingId, prefix))
				facts.refinedTypes.remove(bindingId);
		for (bindingId in facts.stableRefinedTypes.keys())
			if (StringTools.startsWith(bindingId, prefix))
				facts.stableRefinedTypes.remove(bindingId);
		facts.erasedNamespaces.push(prefix);
	}

	/** Forgets every expression fact whose path mentions `fragment`, such as a map entry keyed by a reassigned local. */
	public function invalidateMentioning(fragment:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidateMentioning(fragment);
		var facts = own(), expressionPrefix = EXPRESSION_PREFIX;
		for (bindingId in facts.refinedTypes.keys())
			if (StringTools.startsWith(bindingId, expressionPrefix) && bindingId.indexOf(fragment) >= 0)
				facts.refinedTypes.remove(bindingId);
		for (bindingId in facts.stableRefinedTypes.keys())
			if (StringTools.startsWith(bindingId, expressionPrefix) && bindingId.indexOf(fragment) >= 0)
				facts.stableRefinedTypes.remove(bindingId);
		facts.erasedMentions.push(fragment);
	}

	static function mentionsErased(facts:FactTables, bindingId:String):Bool {
		if (facts.erasedMentions.length == 0 || !StringTools.startsWith(bindingId, EXPRESSION_PREFIX))
			return false;
		for (fragment in facts.erasedMentions)
			if (bindingId.indexOf(fragment) >= 0)
				return true;
		return false;
	}

	public function invalidateAllExpressions():Void
		invalidateNamespace("$expression:");

	/**
	 * Forgets the expression facts a store to any object's field `field` could falsify: every path with a `field`
	 * segment, whatever the receiver, since another name may alias it. Like `invalidateAllExpressions`, facts calls
	 * cannot change survive.
	 */
	public function invalidateField(field:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidateField(field);
		var facts = own();
		for (bindingId in facts.refinedTypes.keys())
			if (mentionsField(bindingId, field))
				facts.refinedTypes.remove(bindingId);
		facts.invalidatedFields.push(field);
	}

	/** Whether an expression fact's path has a `.field` segment, ending the path or followed by `.` or a map-entry `:`. */
	static function mentionsField(bindingId:String, field:String):Bool {
		if (field.length == 0 || !StringTools.startsWith(bindingId, EXPRESSION_PREFIX))
			return false;
		// ".field" followed by the end, "." or ":"; found as `field` with a "." before it, so no "." + field string is made per call.
		var from = 0;
		while (true) {
			var at = bindingId.indexOf(field, from);
			if (at < 0)
				return false;
			if (at > 0 && bindingId.charCodeAt(at - 1) == 46) {
				var end = at + field.length;
				if (end == bindingId.length)
					return true;
				var next = bindingId.charCodeAt(end);
				if (next == 46 || next == 58)
					return true;
			}
			from = at + 1;
		}
	}

	static function mentionsInvalidatedField(facts:FactTables, bindingId:String):Bool {
		for (field in facts.invalidatedFields)
			if (mentionsField(bindingId, field))
				return true;
		return false;
	}
}

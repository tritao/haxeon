package compiler.types.analysis;

import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;

/** Branch-local facts keyed by resolved binding identity. */
class FlowFacts {
	final parent:Null<FlowFacts>;
	var invalidationSink:Null<FlowFacts>;
	final assignmentTypes:Map<String, Null<CompilerType>> = [];
	final refinedTypes:Map<String, CompilerType> = [];
	final stableRefinedTypes:Map<String, CompilerType> = [];
	final invalidated:Map<String, Bool> = [];
	final invalidatedPrefixes:Array<String> = [];
	final invalidatedNamespaces:Array<String> = [];
	final erasedNamespaces:Array<String> = [];
	final erasedMentions:Array<String> = [];
	final invalidatedFields:Array<String> = [];

	public function new(?parent:FlowFacts) {
		this.parent = parent;
		invalidationSink = parent == null ? null : parent.invalidationSink;
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
		invalidated.set(bindingId, true);
		if (!assignmentTypes.exists(bindingId))
			assignmentTypes.set(bindingId, type);
		else {
			var previous = assignmentTypes.get(bindingId);
			if (previous == null || type == null || !TypeRelations.equals(previous, type))
				assignmentTypes.set(bindingId, null);
		}
		if (invalidationSink != null)
			invalidationSink.captureWrite(bindingId, type);
	}

	public function recordAssignment(bindingId:String, type:CompilerType):Void {
		if (invalidationSink != null)
			invalidationSink.captureWrite(bindingId, type);
	}

	public function applyInvalidations(summary:FlowFacts):Void {
		var preserved:Map<String, CompilerType> = [];
		for (key in summary.assignmentTypes.keys()) {
			var assigned = summary.assignmentTypes.get(key),
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
		for (key in summary.invalidated.keys())
			invalidate(key);
		for (prefix in summary.invalidatedPrefixes)
			invalidatePrefix(prefix);
		for (prefix in summary.invalidatedNamespaces)
			invalidateNamespace(prefix);
		for (prefix in summary.erasedNamespaces)
			invalidateNamespaceCompletely(prefix);
		for (fragment in summary.erasedMentions)
			invalidateMentioning(fragment);
		for (field in summary.invalidatedFields)
			invalidateField(field);
		for (key => type in preserved)
			refine(key, type);
		invalidationSink = outerSink;
	}

	public function refine(bindingId:String, type:CompilerType, stable:Bool = false):Void {
		invalidated.remove(bindingId);
		if (stable) {
			refinedTypes.remove(bindingId);
			stableRefinedTypes.set(bindingId, type);
		} else {
			stableRefinedTypes.remove(bindingId);
			refinedTypes.set(bindingId, type);
		}
	}

	public function invalidate(bindingId:String):Void {
		if (invalidationSink != null)
			invalidationSink.captureWrite(bindingId, null);
		refinedTypes.remove(bindingId);
		stableRefinedTypes.remove(bindingId);
		invalidated.set(bindingId, true);
	}

	public function resolve(bindingId:String):Null<CompilerType> {
		if (refinedTypes.exists(bindingId))
			return refinedTypes.get(bindingId);
		if (stableRefinedTypes.exists(bindingId))
			return stableRefinedTypes.get(bindingId);
		for (prefix in invalidatedPrefixes)
			if (bindingId == prefix || StringTools.startsWith(bindingId, prefix + "."))
				return null;
		if (invalidated.exists(bindingId))
			return null;
		for (prefix in erasedNamespaces)
			if (StringTools.startsWith(bindingId, prefix))
				return null;
		if (mentionsErased(bindingId))
			return null;
		for (prefix in invalidatedNamespaces)
			if (StringTools.startsWith(bindingId, prefix))
				return parent == null ? null : parent.resolveStable(bindingId);
		if (mentionsInvalidatedField(bindingId))
			return parent == null ? null : parent.resolveStable(bindingId);
		var outer = parent;
		return outer == null ? null : outer.resolve(bindingId);
	}

	/** All fact keys visible from this branch, including facts inherited from its parent. */
	public function keys():Array<String> {
		var result:Array<String> = [], seen:Map<String, Bool> = [];
		collectKeys(result, seen);
		return result;
	}

	function collectKeys(result:Array<String>, seen:Map<String, Bool>):Void {
		if (parent != null)
			parent.collectKeys(result, seen);
		for (key in refinedTypes.keys())
			if (!seen.exists(key)) {
				seen.set(key, true);
				result.push(key);
			}
		for (key in stableRefinedTypes.keys())
			if (!seen.exists(key)) {
				seen.set(key, true);
				result.push(key);
			}
		for (key in invalidated.keys())
			if (!seen.exists(key)) {
				seen.set(key, true);
				result.push(key);
			}
	}

	function resolveStable(bindingId:String):Null<CompilerType> {
		for (prefix in invalidatedPrefixes)
			if (bindingId == prefix || StringTools.startsWith(bindingId, prefix + "."))
				return null;
		if (invalidated.exists(bindingId))
			return null;
		for (prefix in erasedNamespaces)
			if (StringTools.startsWith(bindingId, prefix))
				return null;
		if (mentionsErased(bindingId))
			return null;
		if (stableRefinedTypes.exists(bindingId))
			return stableRefinedTypes.get(bindingId);
		return parent == null ? null : parent.resolveStable(bindingId);
	}

	/** Whether the visible fact survives calls, including facts inherited through a branch. */
	public function isStable(bindingId:String):Bool {
		if (resolve(bindingId) == null || refinedTypes.exists(bindingId))
			return false;
		if (stableRefinedTypes.exists(bindingId))
			return true;
		for (prefix in invalidatedNamespaces)
			if (StringTools.startsWith(bindingId, prefix))
				return parent != null && parent.resolveStable(bindingId) != null;
		if (mentionsInvalidatedField(bindingId))
			return parent != null && parent.resolveStable(bindingId) != null;
		return parent != null && parent.isStable(bindingId);
	}

	public function invalidatePrefix(prefix:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidatePrefix(prefix);
		for (bindingId in refinedTypes.keys())
			if (bindingId == prefix || StringTools.startsWith(bindingId, prefix + "."))
				refinedTypes.remove(bindingId);
		for (bindingId in stableRefinedTypes.keys())
			if (bindingId == prefix || StringTools.startsWith(bindingId, prefix + "."))
				stableRefinedTypes.remove(bindingId);
		invalidatedPrefixes.push(prefix);
	}

	public function invalidateNamespace(prefix:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidateNamespace(prefix);
		for (bindingId in refinedTypes.keys())
			if (StringTools.startsWith(bindingId, prefix))
				refinedTypes.remove(bindingId);
		invalidatedNamespaces.push(prefix);
	}

	/** Forgets every fact under `prefix`, including stable ones, in this branch and the branches it extends. */
	public function invalidateNamespaceCompletely(prefix:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidateNamespaceCompletely(prefix);
		for (bindingId in refinedTypes.keys())
			if (StringTools.startsWith(bindingId, prefix))
				refinedTypes.remove(bindingId);
		for (bindingId in stableRefinedTypes.keys())
			if (StringTools.startsWith(bindingId, prefix))
				stableRefinedTypes.remove(bindingId);
		erasedNamespaces.push(prefix);
	}

	/** Forgets every expression fact whose path mentions `fragment`, such as a map entry keyed by a reassigned local. */
	public function invalidateMentioning(fragment:String):Void {
		if (invalidationSink != null)
			invalidationSink.invalidateMentioning(fragment);
		var expressionPrefix = '$' + 'expression:';
		for (bindingId in refinedTypes.keys())
			if (StringTools.startsWith(bindingId, expressionPrefix) && bindingId.indexOf(fragment) >= 0)
				refinedTypes.remove(bindingId);
		for (bindingId in stableRefinedTypes.keys())
			if (StringTools.startsWith(bindingId, expressionPrefix) && bindingId.indexOf(fragment) >= 0)
				stableRefinedTypes.remove(bindingId);
		erasedMentions.push(fragment);
	}

	function mentionsErased(bindingId:String):Bool {
		if (!StringTools.startsWith(bindingId, '$' + 'expression:'))
			return false;
		for (fragment in erasedMentions)
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
		for (bindingId in refinedTypes.keys())
			if (mentionsField(bindingId, field))
				refinedTypes.remove(bindingId);
		invalidatedFields.push(field);
	}

	/** Whether an expression fact's path has a `.field` segment, ending the path or followed by `.` or a map-entry `:`. */
	static function mentionsField(bindingId:String, field:String):Bool {
		if (!StringTools.startsWith(bindingId, '$' + 'expression:'))
			return false;
		var segment = "." + field, from = 0;
		while (true) {
			var at = bindingId.indexOf(segment, from);
			if (at < 0)
				return false;
			var end = at + segment.length;
			if (end == bindingId.length)
				return true;
			var next = bindingId.charAt(end);
			if (next == "." || next == ":")
				return true;
			from = at + 1;
		}
	}

	function mentionsInvalidatedField(bindingId:String):Bool {
		for (field in invalidatedFields)
			if (mentionsField(bindingId, field))
				return true;
		return false;
	}
}

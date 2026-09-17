package compiler.types.analysis;

import compiler.types.Type.CompilerType;

typedef FlowFactsCheckpoint = {
	final refinedTypes:Map<String, CompilerType>;
	final invalidated:Map<String, Bool>;
	final invalidatedPrefixes:Array<String>;
	final invalidatedNamespaces:Array<String>;
}

/** Branch-local facts keyed by resolved binding identity. */
class FlowFacts {
	final parent:Null<FlowFacts>;
	final refinedTypes:Map<String, CompilerType> = [];
	final stableRefinedTypes:Map<String, CompilerType> = [];
	final invalidated:Map<String, Bool> = [];
	final invalidatedPrefixes:Array<String> = [];
	final invalidatedNamespaces:Array<String> = [];

	public function new(?parent:FlowFacts)
		this.parent = parent;

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
		for (prefix in invalidatedNamespaces)
			if (StringTools.startsWith(bindingId, prefix))
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
		if (stableRefinedTypes.exists(bindingId))
			return stableRefinedTypes.get(bindingId);
		return parent == null ? null : parent.resolveStable(bindingId);
	}

	public function invalidatePrefix(prefix:String):Void {
		for (bindingId in refinedTypes.keys())
			if (bindingId == prefix || StringTools.startsWith(bindingId, prefix + "."))
				refinedTypes.remove(bindingId);
		for (bindingId in stableRefinedTypes.keys())
			if (bindingId == prefix || StringTools.startsWith(bindingId, prefix + "."))
				stableRefinedTypes.remove(bindingId);
		invalidatedPrefixes.push(prefix);
	}

	public function invalidateNamespace(prefix:String):Void {
		for (bindingId in refinedTypes.keys())
			if (StringTools.startsWith(bindingId, prefix))
				refinedTypes.remove(bindingId);
		invalidatedNamespaces.push(prefix);
	}

	public function invalidateAllExpressions():Void
		invalidateNamespace("$expression:");

	/** Capture branch-local facts before a tolerant statement is attempted. */
	public function checkpoint():FlowFactsCheckpoint
		return {
			refinedTypes: copyTypes(refinedTypes),
			invalidated: copyFlags(invalidated),
			invalidatedPrefixes: invalidatedPrefixes.copy(),
			invalidatedNamespaces: invalidatedNamespaces.copy()
		};

	/** Restore only this scope's facts; parent facts are checkpointed by Scope. */
	public function rollback(checkpoint:FlowFactsCheckpoint):Void {
		refinedTypes.clear();
		for (name => type in checkpoint.refinedTypes)
			refinedTypes.set(name, type);
		invalidated.clear();
		for (name => value in checkpoint.invalidated)
			invalidated.set(name, value);
		invalidatedPrefixes.resize(0);
		for (prefix in checkpoint.invalidatedPrefixes)
			invalidatedPrefixes.push(prefix);
		invalidatedNamespaces.resize(0);
		for (prefix in checkpoint.invalidatedNamespaces)
			invalidatedNamespaces.push(prefix);
	}

	static function copyTypes(source:Map<String, CompilerType>):Map<String, CompilerType> {
		var result:Map<String, CompilerType> = [];
		for (name => type in source)
			result.set(name, type);
		return result;
	}

	static function copyFlags(source:Map<String, Bool>):Map<String, Bool> {
		var result:Map<String, Bool> = [];
		for (name => value in source)
			result.set(name, value);
		return result;
	}
}

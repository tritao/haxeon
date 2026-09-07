package compiler.types.analysis;

import compiler.types.Type.CompilerType;

/** Branch-local facts keyed by resolved binding identity. */
class FlowFacts {
	final parent:Null<FlowFacts>;
	final refinedTypes:Map<String, CompilerType> = [];
	final invalidated:Map<String, Bool> = [];
	final invalidatedPrefixes:Array<String> = [];
	final invalidatedNamespaces:Array<String> = [];

	public function new(?parent:FlowFacts)
		this.parent = parent;

	public function refine(bindingId:String, type:CompilerType):Void {
		invalidated.remove(bindingId);
		refinedTypes.set(bindingId, type);
	}

	public function invalidate(bindingId:String):Void {
		refinedTypes.remove(bindingId);
		invalidated.set(bindingId, true);
	}

	public function resolve(bindingId:String):Null<CompilerType> {
		if (refinedTypes.exists(bindingId))
			return refinedTypes.get(bindingId);
		for (prefix in invalidatedNamespaces)
			if (StringTools.startsWith(bindingId, prefix))
				return null;
		for (prefix in invalidatedPrefixes)
			if (bindingId == prefix || StringTools.startsWith(bindingId, prefix + "."))
				return null;
		if (invalidated.exists(bindingId))
			return null;
		var outer = parent;
		return outer == null ? null : outer.resolve(bindingId);
	}

	public function invalidatePrefix(prefix:String):Void {
		for (bindingId in refinedTypes.keys())
			if (bindingId == prefix || StringTools.startsWith(bindingId, prefix + "."))
				refinedTypes.remove(bindingId);
		invalidatedPrefixes.push(prefix);
	}

	public function invalidateNamespace(prefix:String):Void {
		for (bindingId in refinedTypes.keys())
			if (StringTools.startsWith(bindingId, prefix))
				refinedTypes.remove(bindingId);
		invalidatedNamespaces.push(prefix);
	}
}

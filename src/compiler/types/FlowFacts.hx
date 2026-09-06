package compiler.types;

import compiler.types.Type.CompilerType;

/** Branch-local facts keyed by resolved binding identity. */
class FlowFacts {
	final parent:Null<FlowFacts>;
	final refinedTypes:Map<String, CompilerType> = [];
	final invalidated:Map<String, Bool> = [];

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
		if (invalidated.exists(bindingId))
			return null;
		var outer = parent;
		return outer == null ? null : outer.resolve(bindingId);
	}
}

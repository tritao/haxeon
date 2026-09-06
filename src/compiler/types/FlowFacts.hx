package compiler.types;

import compiler.types.Type.CompilerType;

/** Branch-local facts keyed by resolved binding identity. */
class FlowFacts {
	final parent:Null<FlowFacts>;
	final refinedTypes:Map<String, CompilerType> = [];

	public function new(?parent:FlowFacts)
		this.parent = parent;

	public function refine(bindingId:String, type:CompilerType):Void
		refinedTypes.set(bindingId, type);

	public function resolve(bindingId:String):Null<CompilerType> {
		if (refinedTypes.exists(bindingId))
			return refinedTypes.get(bindingId);
		var outer = parent;
		return outer == null ? null : outer.resolve(bindingId);
	}
}

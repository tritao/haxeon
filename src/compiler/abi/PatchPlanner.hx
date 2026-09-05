package compiler.abi;

import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;

enum AbiChange {
	FunctionAdded(name:String);
	FunctionRemoved(name:String);
	FunctionSignatureChanged(name:String);
	ObjectAdded(name:String);
	ObjectRemoved(name:String);
	ObjectLayoutChanged(name:String);
	ClosureLayoutChanged(name:String);
	InterfaceChanged(name:String);
	EnumChanged(name:String);
	GlobalLayoutChanged(name:String);
}

enum PatchDecision {
	Patch;
	ReloadDomain(reasons:Array<AbiChange>);
	Reject(diagnostics:Array<String>);
}

/** Compares the exact ABI descriptors consumed by HL lowering. */
class PatchPlanner {
	public static function plan(previous:Null<RuntimeAbiDescriptor>, next:RuntimeAbiDescriptor):PatchDecision {
		if (previous == null)
			return Patch;
		var reasons:Array<AbiChange> = [];
		compare(previous.functions, next.functions, function(name, oldValue, newValue) {
			if (oldValue == null)
				return FunctionAdded(name);
			if (newValue == null)
				return FunctionRemoved(name);
			return FunctionSignatureChanged(name);
		}, reasons);
		compare(previous.objects, next.objects, function(name, oldValue, newValue) {
			if (oldValue == null)
				return ObjectAdded(name);
			if (newValue == null)
				return ObjectRemoved(name);
			return StringTools.startsWith(name, "$lambda-env:") ? ClosureLayoutChanged(name) : ObjectLayoutChanged(name);
		}, reasons);
		compare(previous.interfaces, next.interfaces, function(name, _, _) return InterfaceChanged(name), reasons);
		compare(previous.enums, next.enums, function(name, _, _) return EnumChanged(name), reasons);
		compare(previous.globals, next.globals, function(name, _, _) return GlobalLayoutChanged(name), reasons);
		reasons.sort(function(a, b) return Reflect.compare(Std.string(a), Std.string(b)));
		return reasons.length == 0 ? Patch : ReloadDomain(reasons);
	}

	/** Whether producing the replacement module requires discarding backend tombstones and layout caches. */
	public static function requiresFreshLayout(decision:PatchDecision):Bool
		return switch decision {
			case Patch, Reject(_): false;
			case ReloadDomain(reasons): [
					for (reason in reasons)
						switch reason {
							case FunctionAdded(_), FunctionSignatureChanged(_):
								false;
							case FunctionRemoved(name):
								StringTools.endsWith(name, ".new");
							default:
								true;
						}
				].indexOf(true) >= 0;
		};

	static function compare(previous:Map<String, String>, next:Map<String, String>, change:(String, Null<String>, Null<String>) -> AbiChange,
			reasons:Array<AbiChange>):Void {
		var names:Map<String, Bool> = [];
		for (name in previous.keys())
			names.set(name, true);
		for (name in next.keys())
			names.set(name, true);
		for (name in names.keys()) {
			var oldValue = previous.get(name), newValue = next.get(name);
			if (oldValue != newValue)
				reasons.push(change(name, oldValue, newValue));
		}
	}
}

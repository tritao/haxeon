package compiler.semantic;

/**
	Which source module declares each type name. The first module to declare a name owns it. A reverse index lists the
	names each module owns, so releasing one module costs its own declarations and not every declaration in the program.
**/
class DeclarationOwners {
	final owners:Map<String, String> = [];
	final namesByModule:Map<String, Array<String>> = [];

	public function new() {}

	public inline function get(name:String):Null<String>
		return owners.get(name);

	public inline function exists(name:String):Bool
		return owners.exists(name);

	/** Record `module` as the owner of `name` unless another module already owns it. */
	public function claim(name:String, module:String):Void {
		if (owners.exists(name))
			return;
		owners.set(name, module);
		var names = namesByModule.get(module);
		if (names == null) {
			names = [];
			namesByModule.set(module, names);
		}
		names.push(name);
	}

	/** Forget every name `module` owns, as when it is parsed again or removed. */
	public function release(module:String):Void {
		var names = namesByModule.get(module);
		if (names == null)
			return;
		namesByModule.remove(module);
		for (name in names)
			if (owners.get(name) == module)
				owners.remove(name);
	}

	public function copy():DeclarationOwners {
		var result = new DeclarationOwners();
		for (name => module in owners)
			result.owners.set(name, module);
		for (module => names in namesByModule)
			result.namesByModule.set(module, names.copy());
		return result;
	}
}

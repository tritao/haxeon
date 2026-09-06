package runtime;

/** Known resource and borrower categories for one loaded module. */
enum abstract ModuleRetirementFlag(Int) from Int to Int {
	var LiveManagedAllocations = 1;
	var OwnedNativeRoots = 2;
	var RegistryReaders = 4;
}

/**
 * A quiesced snapshot of the ownership information known to HashLink.
 * Owned roots are resources removed by teardown; managed values and registry
 * readers can borrow module metadata or executable code.
 */
class ModuleRetirementStatus {
	public final liveManagedAllocations:Int;
	public final ownedNativeRoots:Int;
	public final registryReaders:Int;
	public final flags:Int;

	public function new(liveManagedAllocations:Int, ownedNativeRoots:Int, registryReaders:Int, flags:Int) {
		this.liveManagedAllocations = liveManagedAllocations;
		this.ownedNativeRoots = ownedNativeRoots;
		this.registryReaders = registryReaders;
		this.flags = flags;
	}

	public inline function has(flag:ModuleRetirementFlag):Bool
		return flags & (flag : Int) != 0;

	public inline function hasKnownBorrowers():Bool
		return has(LiveManagedAllocations) || has(RegistryReaders);
}

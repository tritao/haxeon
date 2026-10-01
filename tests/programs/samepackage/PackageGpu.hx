package samepackage;

// `PackageTypes.Image` names a type in a module of this package, as generated FFI modules write it.
class PackageGpu {
	public static function make():PackageTypes.Image
		return new PackageTypes.Image(42);
}

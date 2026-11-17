package project;

import compiler.core.InternalError;

/** Stable package identity, independent of where its source was acquired. */
class PackageId {
	public final name:String;

	public function new(name:String) {
		if (name == null || name.length == 0)
			throw new InternalError("Package names must not be empty");
		this.name = name;
	}

	public function key():String
		return name;

	public function equals(other:PackageId):Bool
		return other != null && name == other.name;

	public function toString():String
		return name;
}

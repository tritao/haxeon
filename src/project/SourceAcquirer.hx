package project;

/** Acquires an immutable package root for a declared source. */
interface SourceAcquirer {
	function acquire(source:PackageSource, ownerRoot:String, packageId:PackageId):String;
}

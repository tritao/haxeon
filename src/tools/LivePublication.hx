package tools;

typedef LiveFunction = {final name:String; final id:Int;}

typedef LiveDescription = {
	final revision:Int;
	final baseRevision:Int;
	final moduleIdentity:String;
	final requiresReload:Bool;
	final patchAvailable:Bool;
	final changedFunctions:Array<Int>;
	final identities:Array<LiveFunction>;
}

/** Publication compatibility is checked before the live host invokes the runtime patcher. */
class LivePublication {
	public static function canPatch(current:LiveDescription, candidate:LiveDescription):Bool
		return candidate.moduleIdentity == current.moduleIdentity
			&& candidate.patchAvailable
			&& candidate.baseRevision == current.revision
			&& !candidate.requiresReload;
}

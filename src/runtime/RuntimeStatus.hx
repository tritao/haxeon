package runtime;

/** Stable status codes shared with the native realtime runtime ABI. */
enum abstract RuntimeStatus(Int) from Int to Int {
	var Ok = 0;
	var BadArgument = 1;
	var BadFormat = 2;
	var StalePatch = 3;
	var Incompatible = 4;
	var JitFailed = 5;
	var BadFunction = 6;
	var Exception = 7;
	var RetirementBlocked = 8;

	/** The patch applied, but initializers of the fields it added threw: the module runs the new revision with zero values in them. */
	var MigrationFailed = 9;
}

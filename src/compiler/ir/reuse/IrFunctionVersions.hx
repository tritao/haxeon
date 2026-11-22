package compiler.ir.reuse;

/**
 * The versions of the generator's functions (`ModuleState.irVersions`): each IR a function is given takes the next number, so
 * a version names one IR. A number is never given twice in a session, not even after a build that is rolled back, since the
 * copies of the session state a build works on share this counter; a memo keyed on a version (`IrStageMemo`) can trust it.
 */
class IrFunctionVersions {
	var last = 0;

	public function new() {}

	/** A version no function of the session had before. */
	public function next():Int
		return ++last;
}

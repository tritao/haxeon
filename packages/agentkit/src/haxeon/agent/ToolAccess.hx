package haxeon.agent;

/** ReadOnly tools never change host state; policies commonly let them run unattended. */
enum ToolAccess {
	/** Never changes host state. */
	ReadOnly;

	/** May change host state. */
	Mutating;
}

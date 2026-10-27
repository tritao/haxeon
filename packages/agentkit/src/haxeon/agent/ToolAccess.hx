package haxeon.agent;

/** ReadOnly tools never change host state; policies commonly let them run unattended. */
enum ToolAccess {
	ReadOnly;
	Mutating;
}

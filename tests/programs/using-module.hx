// `using` of other modules, in Haxe's order: the last `using` first; within a module of several types the last type first and the
// module's functions last.
using usingtools.Tools;
using usingtools.Later;

function main():Int {
	if (0.tag() != 2)
		return 1;
	if (0.moduleOnly() != 4)
		return 2;
	if (0.onlyFirst() != 20)
		return 3;
	return 42;
}

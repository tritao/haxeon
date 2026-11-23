package compiler.core;

/** The declaration sought by an unresolved reference. */
enum abstract UnresolvedNameKind(String) {
	var WantedType = "type";
	var WantedVariable = "variable";
	var WantedFunction = "function";
	var WantedClass = "class";
	var WantedBaseClass = "base class";
	var WantedInterface = "interface";
	var WantedModule = "module";
}

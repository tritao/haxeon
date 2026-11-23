// A bare name is an enum abstract's value only where Haxe makes it visible: in the abstract's own module, where it is imported
// (`import pack.Abstract` or `import pack.Abstract.*`) or where a value of it is expected. An abstract of the same package is not
// otherwise in scope, so its value `Type` does not hide Haxe's `Type`.
import valuescope.Tag;

function main():Int {
	var failures:Array<String> = [];
	valuescope.Scope.run(failures);
	// Imported here, the abstract's values are in scope.
	var imported:Int = Plain;
	if (imported != 1)
		failures.push("imported value");
	return failures.length == 0 ? 42 : failures.length;
}

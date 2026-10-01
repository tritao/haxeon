import compiler.Compiler;

/**
	A package-scoped root that is also a plain root (as `haxeon build` passes a dependency's sources) serves its files
	only as the modules their package declarations name: `lib/Runner.hx` declaring `package app` is app.Runner, so
	`Runner.Scene` must not load it a second time as a root-package `Runner`.
**/
class PackageRootModuleMain {
	static function main():Void {
		var compiler = new Compiler();
		compiler.addSourceRoot("tests/compiler/packageroot/lib");
		compiler.addPackageSourceRoot("app", "tests/compiler/packageroot/lib");
		compiler.addSourceRoot("tests/compiler/packageroot/tests");
		compiler.update("app/Main.hx", sys.io.File.getContent("tests/compiler/packageroot/tests/app/Main.hx"));
		compiler.analyze("app.Main");
		Sys.println("PASS: a module-qualified type from a package root loads its module once");
	}
}

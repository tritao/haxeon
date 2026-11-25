package compiler.types;

import compiler.SourcePackages;
import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;

/**
 * `internal` (docs/reference/LANGUAGE_SUPPORT.md): a declaration the code of its own package may use and no other package's.
 * Each place source names a declaration asks here: a type name (`DeclarationIndex`), a member (`MemberAccess`) and a
 * module-level function (`CallResolver`, `BodyTyper`).
 */
class InternalAccess {
	/** Requires that the code at `use` may name `name`, internal where `declared` is: both in one package (`E1031`). */
	public static function require(packages:SourcePackages, name:String, declared:SourceSpan, use:SourceSpan):Void {
		if (allows(packages, declared, use))
			return;
		var owner = packages.packageOf(declared.file.physicalPath);
		throw new CompileError(new Diagnostic(DiagnosticCode.INTERNAL_ACCESS,
			'$name is internal to ' + (owner == null ? "the sources outside any package" : 'package $owner'), use));
	}

	/** Whether the code at `use` is in the package of the internal declaration at `declared`. */
	public static function allows(packages:SourcePackages, declared:SourceSpan, use:SourceSpan):Bool
		return packages.packageOf(declared.file.physicalPath) == packages.packageOf(use.file.physicalPath);
}

package compiler.types.analysis;

import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstEnum;
import compiler.syntax.Ast.AstEnumAbstract;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstInterface;
import compiler.syntax.Ast.AstMetadata;

/**
 * `@:pure` annotation and type-name lookups shared between the typing session (which resolves
 * them against its own live declaration maps) and the pre-typing purity-drift check (which
 * resolves them against a plain canonical program, before any type is connected).
 */
class PurityAnnotations {
	public static function isTypeName(name:String, classDecls:Map<String, AstClass>, interfaceDecls:Map<String, AstInterface>, enumDecls:Map<String, AstEnum>,
			enumAbstractDecls:Map<String, AstEnumAbstract>, abstractDecls:Map<String, AstAbstract>):Bool
		return classDecls.exists(name) || interfaceDecls.exists(name) || enumDecls.exists(name) || enumAbstractDecls.exists(name) || abstractDecls.exists(name);

	/** Annotated functions and read-only compiler intrinsics; purity inference seeds from these. */
	public static function isDeclaredPure(name:String, signatures:Map<String, AstFunction>, classDecls:Map<String, AstClass>):Bool
		return compiler.runtime.CompilerIntrinsics.isPure(name) || hasPureAnnotation(name, signatures, classDecls);

	/** `@:pure` on a function, or on the class of a static method. */
	public static function hasPureAnnotation(name:String, signatures:Map<String, AstFunction>, classDecls:Map<String, AstClass>):Bool {
		var fn = signatures.get(name);
		if (fn == null)
			return false;
		if (hasPureMetadata(fn.metadata))
			return true;
		var dot = name.lastIndexOf(".");
		if (dot < 0 || !fn.isStatic)
			return false;
		var owner = classDecls.get(name.substr(0, dot));
		return owner != null && hasPureMetadata(owner.metadata);
	}

	public static function hasPureMetadata(metadata:Null<Array<AstMetadata>>):Bool {
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "pure")
					return true;
		return false;
	}
}

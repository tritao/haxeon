package compiler.syntax;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstMetadata;
import compiler.syntax.Ast.AstStatement;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Ast.AstTypeConstraint;

/**
 * Copies of a parsed function with some parts replaced. `copy` is the one place that lists every field of `AstFunction`, so a pass that
 * rewrites a signature or a body cannot drop a modifier (`inline`, `extern`, visibility, `override`) or the metadata typing acts on
 * (`@:keep`, `@:expose`, `@:pure`); a field added to `AstFunction` is added here. The parts are plain arguments, not a record of
 * overrides, so a copy allocates only the new function.
 */
class AstFunctions {
	/** `fn` with the given name, staticness, metadata, signature, body and span; its modifiers are `fn`'s. */
	public static function copy(fn:AstFunction, name:String, isStatic:Bool, metadata:Null<Array<AstMetadata>>,
			typeParameters:Null<Array<String>>,
			typeConstraints:Null<Array<AstTypeConstraint>>, arguments:Array<AstArgument>, result:AstType,
			statements:Array<AstStatement>,
			span:SourceSpan):AstFunction
		return {
			isOverride: fn.isOverride,
			name: name,
			isStatic: isStatic,
			isPublic: fn.isPublic,
			isExtern: fn.isExtern,
			isInline: fn.isInline,
			metadata: metadata,
			typeParameters: typeParameters,
			typeConstraints: typeConstraints,
			arguments: arguments,
			result: result,
			statements: statements,
			span: span
		};

	/** `fn` with a different signature and body under `name`, as canonicalization produces it. */
	public static inline function withSignature(fn:AstFunction, name:String,
			typeConstraints:Null<Array<AstTypeConstraint>>, arguments:Array<AstArgument>,
			result:AstType, statements:Array<AstStatement>):AstFunction
		return copy(fn, name, fn.isStatic, fn.metadata, fn.typeParameters, typeConstraints, arguments, result,
			statements, fn.span);

	public static inline function withName(fn:AstFunction, name:String):AstFunction
		return copy(fn, name, fn.isStatic, fn.metadata, fn.typeParameters, fn.typeConstraints, fn.arguments, fn.result,
			fn.statements, fn.span);

	public static inline function withTypeParameters(fn:AstFunction, typeParameters:Null<Array<String>>):AstFunction
		return copy(fn, fn.name, fn.isStatic, fn.metadata, typeParameters, fn.typeConstraints, fn.arguments, fn.result,
			fn.statements, fn.span);

	public static inline function withArguments(fn:AstFunction, arguments:Array<AstArgument>):AstFunction
		return copy(fn, fn.name, fn.isStatic, fn.metadata, fn.typeParameters, fn.typeConstraints, arguments, fn.result,
			fn.statements, fn.span);

	public static inline function withResult(fn:AstFunction, result:AstType):AstFunction
		return copy(fn, fn.name, fn.isStatic, fn.metadata, fn.typeParameters, fn.typeConstraints, fn.arguments, result,
			fn.statements, fn.span);
}

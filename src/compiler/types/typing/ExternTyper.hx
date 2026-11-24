package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.DiagnosticCode;
import compiler.core.Source.SourceSpan;
import compiler.ffi.NativeLayout;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.NativeConvention;
import compiler.types.TypedAst.TypedNative;

typedef ArgumentTypesResolver = AstFunction->Array<CompilerType>;
typedef TypeResolver = (type:AstType, span:SourceSpan) -> CompilerType;

/** Projects extern and native declarations into the typed native boundary. */
class ExternTyper {
	final argumentTypes:ArgumentTypesResolver;
	final lowerType:TypeResolver;

	public function new(argumentTypes:ArgumentTypesResolver, lowerType:TypeResolver) {
		this.argumentTypes = argumentTypes;
		this.lowerType = lowerType;
	}

	public function typeExtern(fn:AstFunction, ?externalName:String, ?receiverType:CompilerType, ?defaultLibrary:String,
			?resultOverride:CompilerType,
			allowStubBody:Bool = false):TypedNative {
		// A function `@:hlNative` binds keeps its body, which is only checked (`AstFunctions.bindingNative`).
		if (fn.statements.length != 0 && !allowStubBody && !compiler.syntax.AstFunctions.hasMetadata(fn, "hlNative"))
			fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN, 'Extern function "${fn.name}" cannot have a body', fn.span);
		var binding:Null<compiler.syntax.Ast.AstMetadata> = null,
			cBinding:Null<compiler.syntax.Ast.AstMetadata> = null;
		var metadata = fn.metadata;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "hlNative") {
					if (binding != null)
						fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN,
							'Extern function "${fn.name}" has duplicate @:hlNative metadata', entry.span);
					binding = entry;
				} else if (entry.name == "cNative") {
					if (cBinding != null)
						fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN,
							'Extern function "${fn.name}" has duplicate @:cNative metadata', entry.span);
					cBinding = entry;
				}
		if (binding != null && cBinding != null)
			fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN,
				'Extern function "${fn.name}" cannot combine @:hlNative and @:cNative', fn.span);
		if (binding == null && cBinding == null && defaultLibrary == null)
			fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN,
				'Extern function "${fn.name}" requires @:hlNative(library, symbol)', fn.span);
		var library = defaultLibrary, symbol = fn.name;
		var convention = NativeConvention.HashLinkNative;
		if (binding != null) {
			if (binding.arguments.length != 2)
				fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN, "@:hlNative requires a library and symbol string",
					binding.span);
			var values = metadataStrings(binding, "@:hlNative arguments must be string literals");
			library = values[0];
			symbol = values[1];
		}
		if (cBinding != null) {
			if (cBinding.arguments.length != 3)
				fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN,
					"@:cNative requires library, symbol, and ABI signature strings", cBinding.span);
			var values = metadataStrings(cBinding, "@:cNative arguments must be string literals");
			library = values[0];
			symbol = values[1];
			convention = NativeConvention.CNative(values[2]);
		}
		var arguments = argumentTypes(fn);
		if (receiverType != null)
			arguments.unshift(receiverType);
		for (argument in arguments)
			if (NativeLayout.containsNativeLayoutType(argument))
				fail(DiagnosticCode.NATIVE_OR_CATCH,
					'Native layout types cannot cross a foreign function boundary by value yet', fn.span);
		// An extern function has no body, so its result is always written: it does not need DeclarationIndex.resultType.
		var result = resultOverride == null ? lowerType(fn.result, fn.span) : resultOverride;
		if (NativeLayout.containsNativeLayoutType(result))
			fail(DiagnosticCode.NATIVE_OR_CATCH,
				'Native layout types cannot cross a foreign function boundary by value yet', fn.span);
		return {
			name: externalName == null ? fn.name : externalName,
			library: library,
			symbol: symbol,
			arguments: arguments,
			result: result,
			convention: convention
		};
	}

	public function nativeLibrary(owner:String, metadata:Null<Array<compiler.syntax.Ast.AstMetadata>>):Null<String> {
		var binding:Null<compiler.syntax.Ast.AstMetadata> = null;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "hlNative") {
					if (binding != null)
						fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN,
							'Extern declaration "$owner" has duplicate @:hlNative metadata', entry.span);
					binding = entry;
				}
		if (binding == null)
			return null;
		if (binding.arguments.length != 1)
			fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN, "Declaration @:hlNative requires one library string",
				binding.span);
		return metadataStrings(binding, "Declaration @:hlNative library must be a string literal")[0];
	}

	function metadataStrings(metadata:compiler.syntax.Ast.AstMetadata, message:String):Array<String> {
		var values = [];
		for (argument in metadata.arguments)
			switch argument {
				case StringLiteral(value, _):
					values.push(value);
				default:
					fail(DiagnosticCode.COVERAGE_THROW_OR_EXTERN, message, metadata.span);
			}
		return values;
	}

	@:noReturn
	static function fail(code:DiagnosticCode, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}

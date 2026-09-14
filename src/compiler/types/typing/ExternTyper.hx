package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstArgument;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.NativeConvention;
import compiler.types.TypedAst.TypedNative;

typedef ArgumentTypeResolver = AstArgument->CompilerType;
typedef TypeResolver = AstType->CompilerType;

/** Projects extern and native declarations into the typed native boundary. */
class ExternTyper {
	final argumentType:ArgumentTypeResolver;
	final lowerType:TypeResolver;

	public function new(argumentType:ArgumentTypeResolver, lowerType:TypeResolver) {
		this.argumentType = argumentType;
		this.lowerType = lowerType;
	}

	public function typeExtern(fn:AstFunction, ?externalName:String, ?receiverType:CompilerType, ?defaultLibrary:String, ?resultOverride:CompilerType,
			allowStubBody:Bool = false):TypedNative {
		if (fn.statements.length != 0 && !allowStubBody)
			fail("E1021", 'Extern function "${fn.name}" cannot have a body', fn.span);
		var binding:Null<compiler.syntax.Ast.AstMetadata> = null,
			cBinding:Null<compiler.syntax.Ast.AstMetadata> = null;
		var metadata = fn.metadata;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "hlNative") {
					if (binding != null)
						fail("E1021", 'Extern function "${fn.name}" has duplicate @:hlNative metadata', entry.span);
					binding = entry;
				} else if (entry.name == "cNative") {
					if (cBinding != null)
						fail("E1021", 'Extern function "${fn.name}" has duplicate @:cNative metadata', entry.span);
					cBinding = entry;
				}
		if (binding != null && cBinding != null)
			fail("E1021", 'Extern function "${fn.name}" cannot combine @:hlNative and @:cNative', fn.span);
		if (binding == null && cBinding == null && defaultLibrary == null)
			fail("E1021", 'Extern function "${fn.name}" requires @:hlNative(library, symbol)', fn.span);
		var library = defaultLibrary, symbol = fn.name;
		var convention = NativeConvention.HashLinkNative;
		if (binding != null) {
			if (binding.arguments.length != 2)
				fail("E1021", "@:hlNative requires a library and symbol string", binding.span);
			var values = metadataStrings(binding, "@:hlNative arguments must be string literals");
			library = values[0];
			symbol = values[1];
		}
		if (cBinding != null) {
			if (cBinding.arguments.length != 3)
				fail("E1021", "@:cNative requires library, symbol, and ABI signature strings", cBinding.span);
			var values = metadataStrings(cBinding, "@:cNative arguments must be string literals");
			library = values[0];
			symbol = values[1];
			convention = NativeConvention.CNative(values[2]);
		}
		var arguments = [for (argument in fn.arguments) argumentType(argument)];
		if (receiverType != null)
			arguments.unshift(receiverType);
		return {
			name: externalName == null ? fn.name : externalName,
			library: library,
			symbol: symbol,
			arguments: arguments,
			result: resultOverride == null ? lowerType(fn.result) : resultOverride,
			convention: convention
		};
	}

	public function nativeLibrary(owner:String, metadata:Null<Array<compiler.syntax.Ast.AstMetadata>>):Null<String> {
		var binding:Null<compiler.syntax.Ast.AstMetadata> = null;
		if (metadata != null)
			for (entry in metadata)
				if (entry.name == "hlNative") {
					if (binding != null)
						fail("E1021", 'Extern declaration "$owner" has duplicate @:hlNative metadata', entry.span);
					binding = entry;
				}
		if (binding == null)
			return null;
		if (binding.arguments.length != 1)
			fail("E1021", "Declaration @:hlNative requires one library string", binding.span);
		return metadataStrings(binding, "Declaration @:hlNative library must be a string literal")[0];
	}

	function metadataStrings(metadata:compiler.syntax.Ast.AstMetadata, message:String):Array<String> {
		var values = [];
		for (argument in metadata.arguments)
			switch argument {
				case StringLiteral(value, _):
					values.push(value);
				default:
					fail("E1021", message, metadata.span);
			}
		return values;
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}

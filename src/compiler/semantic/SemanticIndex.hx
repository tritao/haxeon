package compiler.semantic;

import compiler.Source.SourceSpan;
import compiler.modules.ModulePath;
import compiler.syntax.Token;
import compiler.syntax.Token.TokenKind;
import compiler.types.DeclarationIndex;
import compiler.types.DeclarationIndex.DeclarationKind;

/** Stable, module-qualified identity shared by compiler and editor consumers. */
abstract SemanticSymbolId(String) from String to String {
	public inline function new(module:String, declaration:String)
		this = module + ":" + declaration;
}

/** One compiler-owned declaration record. */
typedef IndexedSemanticSymbol = {
	final id:SemanticSymbolId;
	final name:String;
	final kind:DeclarationKind;
	final declaration:SourceSpan;
}

private typedef PositionBinding = {
	final span:SourceSpan;
	final symbol:SemanticSymbolId;
}

/** Revision-local declaration and source-position facts emitted during parsing. */
class SemanticIndex {
	public final symbols:Map<String, IndexedSemanticSymbol> = [];

	final bindings:Array<PositionBinding> = [];

	public function new(path:String, declarations:DeclarationIndex, tokens:Array<Token>) {
		var module = ModulePath.fromFile(path),
			keys = [for (key in declarations.symbols.keys()) key];
		keys.sort(Reflect.compare);
		for (key in keys) {
			var declaration = declarations.symbols.get(key),
				id = new SemanticSymbolId(module, declaration.id);
			symbols.set(id, {
				id: id,
				name: declaration.name,
				kind: declaration.kind,
				declaration: declaration.span
			});
			var sourceName = sourceName(declaration.name),
				binding = declarationToken(tokens, declaration.span, sourceName);
			if (binding != null)
				bindings.push({span: binding.span, symbol: id});
		}
		bindings.sort(function(left, right) return Reflect.compare(left.span.start, right.span.start));
	}

	public function symbolAt(position:Int):Null<IndexedSemanticSymbol> {
		for (binding in bindings)
			if (position >= binding.span.start && position <= binding.span.end)
				return symbols.get(binding.symbol);
		return null;
	}

	public function symbol(id:SemanticSymbolId):Null<IndexedSemanticSymbol>
		return symbols.get(id);

	static function declarationToken(tokens:Array<Token>, declaration:SourceSpan, name:String):Null<Token> {
		for (token in tokens)
			if (token.span.start >= declaration.start
				&& token.span.end <= declaration.end
				&& token.kind == TokenKind.Identifier
				&& token.text == name)
				return token;
		return null;
	}

	static function sourceName(name:String):String {
		var separator = name.lastIndexOf(".");
		return separator < 0 ? name : name.substr(separator + 1);
	}
}

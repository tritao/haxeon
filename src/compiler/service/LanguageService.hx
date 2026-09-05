package compiler.service;

import compiler.Ast.AstType;
import compiler.Diagnostic;
import compiler.Source.SourceSpan;
import compiler.modules.Compiler;
import compiler.modules.ModulePath;
import compiler.modules.ModuleState;
import compiler.modules.Compiler.CompileResult;

typedef DocumentSymbol = {
	final name:String;
	final kind:String;
	final detail:String;
	final span:SourceSpan;
}

typedef CompletionItem = {
	final label:String;
	final kind:String;
	final detail:String;
}

/** Read-only editor queries backed by the persistent compiler state. */
class LanguageService {
	public final compiler:Compiler;

	public function new(?identityState:haxe.io.Bytes)
		compiler = new Compiler(identityState);

	public function update(path:String, source:String):ModuleState
		return compiler.update(path, source);

	public function compile(entryModule:String):CompileResult
		return compiler.compile(entryModule);

	public function diagnostics(path:String):Array<Diagnostic> {
		var state = stateFor(path);
		return state == null ? [] : state.diagnostics.copy();
	}

	public function documentSymbols(path:String):Array<DocumentSymbol> {
		var state = stateFor(path), result:Array<DocumentSymbol> = [];
		if (state == null || state.ast == null)
			return result;
		for (fn in state.ast.functions)
			result.push({
				name: fn.name,
				kind: "function",
				detail: '${fn.name}():${typeName(fn.result)}',
				span: fn.span
			});
		for (classDecl in state.ast.classes) {
			result.push({
				name: classDecl.name,
				kind: "class",
				detail: 'class ${classDecl.name}',
				span: classDecl.span
			});
			for (field in classDecl.fields)
				result.push({
					name: field.name,
					kind: "field",
					detail: '${field.name}:${typeName(field.type)}',
					span: field.span
				});
			for (method in classDecl.methods)
				result.push({
					name: method.name,
					kind: "method",
					detail: '${method.name}():${typeName(method.result)}',
					span: method.span
				});
		}
		result.sort(function(a, b) return Reflect.compare(a.name, b.name));
		return result;
	}

	public function complete(path:String, position:Int):Array<CompletionItem> {
		var state = stateFor(path), result:Array<CompletionItem> = [];
		if (state == null || state.ast == null)
			return result;
		var prefix = identifierPrefix(state.source.text, position);
		for (symbol in documentSymbols(path))
			if (prefix.length == 0 || StringTools.startsWith(symbol.name, prefix))
				result.push({label: symbol.name, kind: symbol.kind, detail: symbol.detail});
		return result;
	}

	public function hover(path:String, position:Int):Null<String> {
		var state = stateFor(path);
		if (state == null || state.ast == null)
			return null;
		var name = identifierPrefix(state.source.text, position);
		if (name.length == 0)
			return null;
		for (symbol in documentSymbols(path))
			if (symbol.name == name)
				return symbol.detail;
		return null;
	}

	function stateFor(path:String):Null<ModuleState>
		return compiler.modules.get(ModulePath.fromFile(path));

	static function identifierPrefix(source:String, position:Int):String {
		var end = position < 0 ? 0 : position > source.length ? source.length : position, start = end;
		while (start > 0 && isIdentifierPart(source.charCodeAt(start - 1)))
			start--;
		return source.substring(start, end);
	}

	static inline function isIdentifierPart(code:Int):Bool
		return (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || (code >= 48 && code <= 57) || code == 95;

	static function typeName(type:AstType):String
		return switch type {
			case IntType: "Int";
			case BoolType: "Bool";
			case FloatType: "Float";
			case StringType: "String";
			case VoidType: "Void";
			case NamedType(name): name;
			case ArrayType(element): 'Array<${typeName(element)}>';
			case FunctionType(arguments, result): '(${[for (argument in arguments) typeName(argument)].join(",")})->${typeName(result)}';
		};
}

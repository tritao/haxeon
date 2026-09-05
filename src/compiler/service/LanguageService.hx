package compiler.service;

import compiler.Ast.AstType;
import compiler.Diagnostic;
import compiler.Source.SourceSpan;
import compiler.Token.TokenKind;
import compiler.modules.Compiler;
import compiler.modules.ModulePath;
import compiler.modules.ModuleState;
import compiler.modules.Compiler.CompileResult;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedStatement;

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

typedef SymbolLocation = {
	final path:String;
	final span:SourceSpan;
}

typedef TextEdit = {
	final path:String;
	final span:SourceSpan;
	final replacement:String;
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
		var state = stateFor(path),
			result:Array<DocumentSymbol> = [],
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return result;
		for (fn in ast.functions)
			result.push({
				name: fn.name,
				kind: "function",
				detail: '${fn.name}():${typeName(fn.result)}',
				span: fn.span
			});
		for (alias in ast.aliases)
			result.push({
				name: alias.name,
				kind: "type",
				detail: 'typedef ${alias.name}=${typeName(alias.type)}',
				span: alias.span
			});
		for (interfaceDecl in ast.interfaces) {
			result.push({
				name: interfaceDecl.name,
				kind: "interface",
				detail: 'interface ${interfaceDecl.name}',
				span: interfaceDecl.span
			});
			for (method in interfaceDecl.methods)
				result.push({
					name: method.name,
					kind: "method",
					detail: '${method.name}():${typeName(method.result)}',
					span: method.span
				});
		}
		for (enumDecl in ast.enums) {
			result.push({
				name: enumDecl.name,
				kind: "enum",
				detail: 'enum ${enumDecl.name}',
				span: enumDecl.span
			});
			for (caseDecl in enumDecl.cases)
				result.push({
					name: caseDecl.name,
					kind: "enumCase",
					detail: '${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) typeName(param)].join(",")})',
					span: caseDecl.span
				});
		}
		for (classDecl in ast.classes) {
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
		var state = stateFor(path),
			result:Array<CompletionItem> = [],
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return result;
		var prefix = identifierPrefix(state.source.text, position);
		var qualifier = memberQualifier(state.source.text, position);
		if (qualifier != null) {
			for (enumDecl in ast.enums)
				if (enumDecl.name == qualifier)
					for (caseDecl in enumDecl.cases)
						if (prefix.length == 0 || StringTools.startsWith(caseDecl.name, prefix))
							result.push({
								label: caseDecl.name,
								kind: "enumCase",
								detail: '${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) typeName(param)].join(",")})'
							});
			for (classDecl in ast.classes)
				if (classDecl.name == qualifier) {
					for (field in classDecl.fields)
						if (field.isStatic && (prefix.length == 0 || StringTools.startsWith(field.name, prefix)))
							result.push({label: field.name, kind: "field", detail: '${field.name}:${typeName(field.type)}'});
					for (method in classDecl.methods)
						if (method.isStatic && (prefix.length == 0 || StringTools.startsWith(method.name, prefix)))
							result.push({
								label: method.name,
								kind: "method",
								detail: '${method.name}(${[for (argument in method.arguments) typeName(argument.type)].join(",")}):${typeName(method.result)}'
							});
				}
			var receiverType = qualifierType(path, qualifier, position);
			if (receiverType != null)
				addInstanceMembers(receiverType, prefix, result);
			if (result.length > 0) {
				result.sort(function(a, b) return Reflect.compare(a.label, b.label));
				return result;
			}
		}
		for (symbol in documentSymbols(path))
			if (prefix.length == 0 || StringTools.startsWith(symbol.name, prefix))
				result.push({label: symbol.name, kind: symbol.kind, detail: symbol.detail});
		return result;
	}

	public function hover(path:String, position:Int):Null<String> {
		var state = stateFor(path),
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return null;
		var name = identifierPrefix(state.source.text, position);
		if (name.length == 0)
			return null;
		var qualifier = memberQualifier(state.source.text, position);
		if (qualifier != null) {
			for (enumDecl in ast.enums)
				if (enumDecl.name == qualifier)
					for (caseDecl in enumDecl.cases)
						if (caseDecl.name == name)
							return '${enumDecl.name}.${caseDecl.name}(${[for (param in caseDecl.params) typeName(param)].join(",")})';
			for (classDecl in ast.classes)
				if (classDecl.name == qualifier)
					for (field in classDecl.fields)
						if (field.name == name && field.isStatic)
							return '${field.name}:${typeName(field.type)}';
			var receiverType = qualifierType(path, qualifier, position),
				members:Array<CompletionItem> = [];
			if (receiverType != null) {
				addInstanceMembers(receiverType, name, members);
				if (members.length > 0)
					return members[0].detail;
			}
		}
		for (symbol in documentSymbols(path))
			if (symbol.name == name)
				return symbol.detail;
		return null;
	}

	public function definition(path:String, position:Int):Null<SymbolLocation> {
		var name = symbolAt(path, position);
		if (name == null)
			return null;
		for (state in compiler.modules) {
			var ast = effectiveAst(state);
			if (ast != null) {
				for (alias in ast.aliases)
					if (alias.name == name)
						return {path: state.source.path, span: alias.span};
				for (enumDecl in ast.enums) {
					if (enumDecl.name == name)
						return {path: state.source.path, span: enumDecl.span};
					for (caseDecl in enumDecl.cases)
						if (caseDecl.name == name)
							return {path: state.source.path, span: caseDecl.span};
				}
				for (fn in ast.functions)
					if (fn.name == name)
						return {path: state.source.path, span: fn.span};
				for (interfaceDecl in ast.interfaces) {
					if (interfaceDecl.name == name)
						return {path: state.source.path, span: interfaceDecl.span};
					for (method in interfaceDecl.methods)
						if (method.name == name)
							return {path: state.source.path, span: method.span};
				}
				for (classDecl in ast.classes) {
					if (classDecl.name == name)
						return {path: state.source.path, span: classDecl.span};
					for (field in classDecl.fields)
						if (field.name == name)
							return {path: state.source.path, span: field.span};
					for (method in classDecl.methods)
						if (method.name == name)
							return {path: state.source.path, span: method.span};
				}
			}
		}
		return null;
	}

	public function references(path:String, position:Int):Array<SymbolLocation> {
		var name = symbolAt(path, position), result:Array<SymbolLocation> = [];
		if (name == null)
			return result;
		for (state in compiler.modules) {
			var tokens = effectiveTokens(state);
			if (tokens != null)
				for (token in tokens)
					if (token.kind == Identifier && token.text == name)
						result.push({path: state.source.path, span: token.span});
		}
		result.sort(function(a, b) {
			var pathOrder = Reflect.compare(a.path, b.path);
			return pathOrder == 0 ? Reflect.compare(a.span.start, b.span.start) : pathOrder;
		});
		return result;
	}

	public function rename(path:String, position:Int, replacement:String):Array<TextEdit> {
		var name = symbolAt(path, position), result:Array<TextEdit> = [];
		if (name == null || replacement.length == 0)
			return result;
		for (reference in references(path, position))
			result.push({path: reference.path, span: reference.span, replacement: replacement});
		return result;
	}

	function symbolAt(path:String, position:Int):Null<String> {
		var state = stateFor(path);
		var tokens = state == null ? null : effectiveTokens(state);
		if (state == null || tokens == null)
			return null;
		for (token in tokens)
			if (token.kind == Identifier && position >= token.span.start && position <= token.span.end)
				return token.text;
		return null;
	}

	function qualifierType(path:String, qualifier:String, position:Int):Null<CompilerType> {
		var state = stateFor(path);
		if (state == null)
			return null;
		for (fn in state.typedFunctions)
			if (position >= fn.span.start && position <= fn.span.end) {
				if (qualifier == "this" && fn.owner != null)
					return TClass(fn.owner);
				for (argument in fn.arguments)
					if (argument.name == qualifier)
						return argument.type;
				var local = localType(fn.statements, qualifier);
				if (local != null)
					return local;
			}
		return null;
	}

	static function localType(statements:Array<TypedStatement>, name:String):Null<CompilerType> {
		for (statement in statements)
			switch statement {
				case TVar(local, initializer, _):
					if (local == name)
						return initializer.type;
				case TForIn(local, iterable, body, _):
					if (local == name)
						return switch iterable.type {
							case TArray(element): element;
							default: null;
						};
					var loopType = localType(body, name);
					if (loopType != null)
						return loopType;
				case TIf(_, yes, no, _):
					var branchType = localType(yes, name);
					if (branchType == null)
						branchType = localType(no, name);
					if (branchType != null)
						return branchType;
				case TWhile(_, body, _):
					var loopType = localType(body, name);
					if (loopType != null)
						return loopType;
				case TSwitch(_, cases, defaultBranch, _, _):
					for (switchCase in cases) {
						var caseType = localType(switchCase.statements, name);
						if (caseType != null)
							return caseType;
					}
					var defaultType = localType(defaultBranch, name);
					if (defaultType != null)
						return defaultType;
				default:
			}
		return null;
	}

	function addInstanceMembers(type:CompilerType, prefix:String, result:Array<CompletionItem>):Void {
		switch type {
			case TNullable(element):
				addInstanceMembers(element, prefix, result);
			case TClass(name):
				for (state in compiler.modules) {
					var ast = effectiveAst(state);
					if (ast != null)
						for (classDecl in ast.classes)
							if (classDecl.name == name) {
								for (field in classDecl.fields)
									if (!field.isStatic)
										addMember(field.name, "field", '${field.name}:${typeName(field.type)}', prefix, result);
								for (method in classDecl.methods)
									if (!method.isStatic)
										addMember(method.name, "method",
											'${method.name}(${[for (argument in method.arguments) typeName(argument.type)].join(",")}):${typeName(method.result)}',
											prefix, result);
								if (classDecl.base != null)
									addInstanceMembers(TClass(classDecl.base), prefix, result);
							}
				}
			case TInterface(name):
				for (state in compiler.modules) {
					var ast = effectiveAst(state);
					if (ast != null)
						for (interfaceDecl in ast.interfaces)
							if (interfaceDecl.name == name)
								for (method in interfaceDecl.methods)
									addMember(method.name, "method",
										'${method.name}(${[for (argument in method.arguments) typeName(argument.type)].join(",")}):${typeName(method.result)}',
										prefix, result);
				}
			case TArray(_):
				addMember("length", "field", "length:Int", prefix, result);
			case TMap(_, _):
				addMember("set", "method", "set(key,value):Void", prefix, result);
				addMember("exists", "method", "exists(key):Bool", prefix, result);
				addMember("keys", "method", "keys():Array", prefix, result);
				addMember("remove", "method", "remove(key):Bool", prefix, result);
				addMember("clear", "method", "clear():Void", prefix, result);
			case TString:
				addMember("length", "field", "length:Int", prefix, result);
				addMember("indexOf", "method", "indexOf(needle):Int", prefix, result);
				addMember("substring", "method", "substring(start,end):String", prefix, result);
			default:
		}
	}

	static function addMember(label:String, kind:String, detail:String, prefix:String, result:Array<CompletionItem>):Void {
		if ((prefix.length == 0 || StringTools.startsWith(label, prefix)) && [for (item in result) item.label].indexOf(label) < 0)
			result.push({label: label, kind: kind, detail: detail});
	}

	function stateFor(path:String):Null<ModuleState>
		return compiler.modules.get(ModulePath.fromFile(path));

	static function effectiveAst(state:ModuleState):Null<compiler.Ast.AstProgram>
		return state.ast == null ? state.lastGoodAst : state.ast;

	static function effectiveTokens(state:ModuleState):Null<Array<compiler.Token>>
		return state.tokens == null ? state.lastGoodTokens : state.tokens;

	static function identifierPrefix(source:String, position:Int):String {
		var end = position < 0 ? 0 : position > source.length ? source.length : position, start = end;
		while (start > 0 && isIdentifierPart(source.charCodeAt(start - 1)))
			start--;
		return source.substring(start, end);
	}

	static function memberQualifier(source:String, position:Int):Null<String> {
		var end = position < 0 ? 0 : position > source.length ? source.length : position, start = end;
		while (start > 0 && isIdentifierPart(source.charCodeAt(start - 1)))
			start--;
		if (start == 0 || source.charAt(start - 1) != ".")
			return null;
		var qualifierEnd = start - 1, qualifierStart = qualifierEnd;
		while (qualifierStart > 0 && isIdentifierPart(source.charCodeAt(qualifierStart - 1)))
			qualifierStart--;
		return source.substring(qualifierStart, qualifierEnd);
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
			case MapType(key, value): 'Map<${typeName(key)},${typeName(value)}>';
			case NullableType(element): 'Null<${typeName(element)}>';
			case FunctionType(arguments, result): '(${[for (argument in arguments) typeName(argument)].join(",")})->${typeName(result)}';
		};
}

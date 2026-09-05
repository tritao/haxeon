package compiler.service;

import compiler.Ast.AstType;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.Token.TokenKind;
import compiler.modules.Compiler;
import compiler.modules.ModulePath;
import compiler.modules.ModuleState;
import compiler.modules.Compiler.CompileResult;
import compiler.Ast.AstFunction;
import compiler.Ast.AstStatement;
import compiler.types.Type.CompilerType;
import compiler.types.DeclarationIndex;
import compiler.types.DeclarationIndex.DeclarationKind;
import compiler.types.TypedAst.TypedStatement;

typedef DocumentSymbol = {
	final ?revision:Int;
	final ?stale:Bool;
	final name:String;
	final kind:String;
	final detail:String;
	final span:SourceSpan;
}

typedef CompletionItem = {
	final ?revision:Int;
	final ?stale:Bool;
	final label:String;
	final kind:String;
	final detail:String;
}

typedef SymbolLocation = {
	final ?revision:Int;
	final ?stale:Bool;
	final path:String;
	final span:SourceSpan;
}

typedef TextEdit = {
	final ?revision:Int;
	final ?stale:Bool;
	final path:String;
	final span:SourceSpan;
	final replacement:String;
}

typedef SemanticSymbol = {
	final key:String;
	final location:SymbolLocation;
	final functionSpan:Null<SourceSpan>;
}

/** Read-only editor queries backed by the persistent compiler state. */
class LanguageService {
	public final compiler:Compiler;

	public function new(?identityState:haxe.io.Bytes)
		compiler = new Compiler(identityState);

	public function update(path:String, source:String):ModuleState
		return compiler.update(path, source);

	public function compile(entryModule:String, ?token:CancellationToken):CompileResult
		return compiler.compile(entryModule, token);

	public function validate(path:String, source:String, entryModule:String, ?token:CancellationToken):compiler.modules.Compiler.ValidationResult
		return compiler.validate(path, source, entryModule, token);

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
		tagResults(result, state);
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
				tagResults(result, state);
				return result;
			}
		}
		for (symbol in documentSymbols(path))
			if (prefix.length == 0 || StringTools.startsWith(symbol.name, prefix))
				result.push({label: symbol.name, kind: symbol.kind, detail: symbol.detail});
		tagResults(result, state);
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
		var symbol = resolveSymbol(path, position);
		return symbol == null ? null : symbol.location;
	}

	public function references(path:String, position:Int):Array<SymbolLocation> {
		var target = resolveSymbol(path, position),
			result:Array<SymbolLocation> = [];
		if (target == null)
			return result;
		for (state in compiler.modules) {
			var tokens = effectiveTokens(state);
			if (tokens != null)
				for (token in tokens)
					if (token.kind == Identifier) {
						var candidate = resolveSymbol(state.source.path, token.span.start + 1);
						if (candidate != null && candidate.key == target.key)
							result.push({
								path: state.source.path,
								span: token.span,
								revision: snapshotRevision(state),
								stale: snapshotRevision(state) != state.revision
							});
					}
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
			result.push({
				path: reference.path,
				span: reference.span,
				replacement: replacement,
				revision: reference.revision,
				stale: reference.stale
			});
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

	function resolveSymbol(path:String, position:Int):Null<SemanticSymbol> {
		var state = stateFor(path),
			tokens = state == null ? null : effectiveTokens(state),
			ast = state == null ? null : effectiveAst(state);
		if (state == null || tokens == null || ast == null)
			return null;
		var tokenIndex = -1;
		for (i in 0...tokens.length)
			if (tokens[i].kind == Identifier && position >= tokens[i].span.start && position <= tokens[i].span.end) {
				tokenIndex = i;
				break;
			}
		if (tokenIndex < 0)
			return null;
		var token = tokens[tokenIndex],
			local = localSymbol(path, position, token.text);
		if (local != null)
			return {
				key: 'local:${state.name}:${local.functionSpan.start}:${local.declaration.start}',
				location: {path: path, span: local.declaration},
				functionSpan: local.functionSpan
			};
		var declaration = declarationSymbol(state, tokens, tokenIndex, token.text);
		if (declaration != null)
			return declaration;
		var qualifier = tokenIndex >= 2
			&& tokens[tokenIndex - 1].kind == Dot
			&& tokens[tokenIndex - 2].kind == Identifier ? tokens[tokenIndex - 2].text : null;
		if (qualifier != null) {
			var receiverType = qualifierType(path, qualifier, position);
			if (receiverType != null) {
				var member = memberSymbol(receiverType, token.text);
				if (member != null)
					return member;
			}
			var imported = importedModule(state, qualifier);
			if (imported != null) {
				var importedSymbol = globalSymbol(imported, token.text);
				if (importedSymbol != null)
					return importedSymbol;
			}
		}
		return globalSymbol(state, token.text);
	}

	function declarationSymbol(state:ModuleState, tokens:Array<compiler.Token>, tokenIndex:Int, name:String):Null<SemanticSymbol> {
		var previous = tokenIndex > 0 ? tokens[tokenIndex - 1].kind : null,
			ast = effectiveAst(state);
		if (ast == null)
			return null;
		if (previous == TokenKind.Class)
			for (classDecl in ast.classes)
				if (classDecl.name == name)
					return symbol(state, 'class:$name', classDecl.span, null);
		if (previous == TokenKind.Interface)
			for (interfaceDecl in ast.interfaces)
				if (interfaceDecl.name == name)
					return symbol(state, 'interface:$name', interfaceDecl.span, null);
		if (previous == TokenKind.Enum)
			for (enumDecl in ast.enums)
				if (enumDecl.name == name)
					return symbol(state, 'enum:$name', enumDecl.span, null);
		if (previous == TokenKind.Function) {
			for (fn in ast.functions)
				if (fn.name == name)
					return symbol(state, 'function:$name', fn.span, null);
			for (classDecl in ast.classes)
				for (method in classDecl.methods)
					if (method.name == name && tokenIndexInside(tokens[tokenIndex].span.start, method.span))
						return symbol(state, 'class:${classDecl.name}:method:$name', method.span, null);
		}
		if (previous == TokenKind.Var)
			for (classDecl in ast.classes)
				for (field in classDecl.fields)
					if (field.name == name)
						return symbol(state, 'class:${classDecl.name}:field:$name', field.span, null);
		return null;
	}

	static function tokenIndexInside(position:Int, span:SourceSpan):Bool
		return position >= span.start && position <= span.end;

	function symbol(state:ModuleState, key:String, span:SourceSpan, ?functionSpan:SourceSpan):SemanticSymbol
		return {
			key: '${state.name}:$key',
			location: {
				path: state.source.path,
				span: span,
				revision: snapshotRevision(state),
				stale: snapshotRevision(state) != state.revision
			},
			functionSpan: functionSpan
		};

	function globalSymbol(state:ModuleState, name:String):Null<SemanticSymbol> {
		var visible = [state];
		for (dependency in state.dependencies) {
			var imported = compiler.modules.get(dependency);
			if (imported != null)
				visible.push(imported);
		}
		for (candidate in visible) {
			var ast = effectiveAst(candidate);
			if (ast == null)
				continue;
			try {
				var declarations = new DeclarationIndex(ast);
				for (kind in [Alias, Function, Class, Interface, Enum]) {
					var declaration = declarations.symbol(kind, name);
					if (declaration != null)
						return symbol(candidate, declaration.id, declaration.span, null);
				}
			} catch (_:CompileError) {
				// Keep syntax-based editor recovery available for incomplete modules.
			}
			for (alias in ast.aliases)
				if (alias.name == name)
					return symbol(candidate, 'alias:$name', alias.span, null);
			for (fn in ast.functions)
				if (fn.name == name)
					return symbol(candidate, 'function:$name', fn.span, null);
			for (classDecl in ast.classes)
				if (classDecl.name == name)
					return symbol(candidate, 'class:$name', classDecl.span, null);
			for (interfaceDecl in ast.interfaces)
				if (interfaceDecl.name == name)
					return symbol(candidate, 'interface:$name', interfaceDecl.span, null);
			for (enumDecl in ast.enums)
				if (enumDecl.name == name)
					return symbol(candidate, 'enum:$name', enumDecl.span, null);
		}
		return null;
	}

	function importedModule(state:ModuleState, name:String):Null<ModuleState> {
		var ast = effectiveAst(state);
		if (ast == null)
			return null;
		for (path in ast.imports) {
			var parts = path.split(".");
			if (parts[parts.length - 1] == name) {
				var imported = compiler.modules.get(path);
				if (imported != null)
					return imported;
			}
		}
		return null;
	}

	function memberSymbol(type:CompilerType, name:String):Null<SemanticSymbol> {
		switch type {
			case TNullable(element):
				return memberSymbol(element, name);
			case TClass(className):
				for (state in compiler.modules) {
					var ast = effectiveAst(state);
					if (ast == null)
						continue;
					for (classDecl in ast.classes)
						if (classDecl.name == className) {
							for (field in classDecl.fields)
								if (field.name == name)
									return symbol(state, 'class:$className:field:$name', field.span, null);
							for (method in classDecl.methods)
								if (method.name == name)
									return symbol(state, 'class:$className:method:$name', method.span, null);
							if (classDecl.base != null) {
								var inherited = memberSymbol(TClass(classDecl.base), name);
								if (inherited != null)
									return inherited;
							}
						}
				}
			case TInterface(interfaceName):
				for (state in compiler.modules) {
					var ast = effectiveAst(state);
					if (ast == null)
						continue;
					for (interfaceDecl in ast.interfaces)
						if (interfaceDecl.name == interfaceName)
							for (method in interfaceDecl.methods)
								if (method.name == name)
									return symbol(state, 'interface:$interfaceName:method:$name', method.span, null);
				}
			default:
		}
		return null;
	}

	function localSymbol(path:String, position:Int, name:String):Null<{functionSpan:SourceSpan, declaration:SourceSpan}> {
		var state = stateFor(path),
			ast = state == null ? null : effectiveAst(state);
		if (state == null || ast == null)
			return null;
		for (fn in ast.functions)
			if (position >= fn.span.start && position <= fn.span.end) {
				var argumentSpan = null;
				for (argument in fn.arguments)
					if (argument.name == name)
						argumentSpan = argument.span;
				var declaration = localDeclarationAt(fn.statements, name, position, argumentSpan);
				if (declaration != null)
					return {functionSpan: fn.span, declaration: declaration};
			}
		for (classDecl in ast.classes)
			for (method in classDecl.methods)
				if (position >= method.span.start && position <= method.span.end) {
					var argumentSpan = null;
					for (argument in method.arguments)
						if (argument.name == name)
							argumentSpan = argument.span;
					var declaration = localDeclarationAt(method.statements, name, position, argumentSpan);
					if (declaration != null)
						return {functionSpan: method.span, declaration: declaration};
				}
		return null;
	}

	static function localDeclarationAt(statements:Array<AstStatement>, name:String, position:Int, inherited:Null<SourceSpan>):Null<SourceSpan> {
		var visible = inherited;
		for (statement in statements) {
			var span = statementSpan(statement);
			if (span.start > position)
				break;
			switch statement {
				case VarDeclaration(local, _, _, declaration):
					if (local == name)
						visible = declaration;
				case If(_, yes, no, _):
					var branch = containsPosition(yes, position) ? yes : (containsPosition(no, position) ? no : null);
					if (branch != null)
						return localDeclarationAt(branch, name, position, visible);
				case While(_, body, _):
					if (containsPosition(body, position))
						return localDeclarationAt(body, name, position, visible);
				case ForIn(local, _, body, declaration):
					if (containsPosition(body, position))
						return localDeclarationAt(body, name, position, local == name ? declaration : visible);
				case Try(tryBranch, catches, _):
					if (containsPosition(tryBranch, position))
						return localDeclarationAt(tryBranch, name, position, visible);
					for (catchClause in catches)
						if (position >= catchClause.span.start && position <= catchClause.span.end)
							return localDeclarationAt(catchClause.statements, name, position, catchClause.name == name ? catchClause.span : visible);
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases)
						if (containsPosition(switchCase.statements, position))
							return localDeclarationAt(switchCase.statements, name, position, visible);
					if (containsPosition(defaultBranch, position))
						return localDeclarationAt(defaultBranch, name, position, visible);
				default:
			}
		}
		return visible;
	}

	static function containsPosition(statements:Array<AstStatement>, position:Int):Bool
		return statements.length > 0
			&& position >= statementSpan(statements[0]).start
			&& position <= statementSpan(statements[statements.length - 1]).end;

	static function statementSpan(statement:AstStatement):SourceSpan
		return switch statement {
			case VarDeclaration(_, _, _, span), Assignment(_, _, span), IndexAssignment(_, _, _, span), Return(_, span), ReturnVoid(span), Throw(_, span),
				Try(_, _, span), If(_, _, _, span), While(_, _, span), ForIn(_, _, _, span), Break(span), Continue(span), Switch(_, _, _, _, span),
				Increment(_, _, span), Expression(_, span): span;
		};

	static function localDeclaration(statements:Array<AstStatement>, name:String):Null<SourceSpan> {
		for (statement in statements)
			switch statement {
				case VarDeclaration(local, _, _, span):
					if (local == name)
						return span;
				case If(_, yes, no, _):
					var declaration = localDeclaration(yes, name);
					if (declaration == null)
						declaration = localDeclaration(no, name);
					if (declaration != null)
						return declaration;
				case While(_, body, _), ForIn(_, _, body, _):
					var declaration = localDeclaration(body, name);
					if (declaration != null)
						return declaration;
				case Switch(_, cases, defaultBranch, _, _):
					for (switchCase in cases) {
						var declaration = localDeclaration(switchCase.statements, name);
						if (declaration != null)
							return declaration;
					}
					var declaration = localDeclaration(defaultBranch, name);
					if (declaration != null)
						return declaration;
				default:
			}
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
					if (sourceLocalName(argument.name) == qualifier)
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
					if (sourceLocalName(local) == name)
						return initializer.type;
				case TForIn(local, iterable, body, _):
					if (sourceLocalName(local) == name)
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

	static function sourceLocalName(identity:String):String {
		var separator = identity.indexOf(":");
		return StringTools.startsWith(identity, "$l") && separator >= 0 ? identity.substr(separator + 1) : identity;
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
				addMember("copy", "method", "copy():Array", prefix, result);
				addMember("concat", "method", "concat(other):Array", prefix, result);
				addMember("slice", "method", "slice(start,end):Array", prefix, result);
				addMember("indexOf", "method", "indexOf(value):Int", prefix, result);
				addMember("push", "method", "push(value):Int", prefix, result);
				addMember("pop", "method", "pop():Element", prefix, result);
			case TMap(_, _):
				addMember("set", "method", "set(key,value):Void", prefix, result);
				addMember("exists", "method", "exists(key):Bool", prefix, result);
				addMember("keys", "method", "keys():Array", prefix, result);
				addMember("values", "method", "values():Array", prefix, result);
				addMember("remove", "method", "remove(key):Bool", prefix, result);
				addMember("clear", "method", "clear():Void", prefix, result);
				addMember("size", "method", "size():Int", prefix, result);
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

	static function tagResults<T>(results:Array<T>, state:ModuleState):Void {
		var revision = snapshotRevision(state),
			stale = revision != state.revision;
		for (result in results) {
			Reflect.setField(result, "revision", revision);
			Reflect.setField(result, "stale", stale);
		}
	}

	static function snapshotRevision(state:ModuleState):Int
		return state.ast == null ? state.lastGoodRevision : state.revision;

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

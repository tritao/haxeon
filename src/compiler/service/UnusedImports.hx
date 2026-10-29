package compiler.service;

import compiler.syntax.Ast.AstProgram;
import compiler.syntax.Ast.AstType;
import compiler.syntax.Token;
import compiler.syntax.Token.TokenKind;

/** An import statement whose names the file never mentions. */
typedef UnusedImport = {
	final path:String;

	/** Source offsets of the whole statement, from `import` to its semicolon. */
	final start:Int;

	final end:Int;
}

/** The module an import path names, and the type inside it when the path goes one level deeper. */
typedef ImportTarget = {final program:AstProgram; final member:Null<String>;}

/**
 * Finds imports that bring no name into use.
 *
 * A file uses an import when it mentions one of the names the import makes visible: the imported types, and for an enum the
 * constructors that haxeon resolves unqualified through the import. An import the analysis cannot judge counts as used, so a
 * result never asks for the removal of an import that is still needed: wildcards, modules that did not resolve, and abstracts
 * that declare implicit conversions.
 */
class UnusedImports {
	public static function find(tokens:Array<Token>, resolve:String->Null<ImportTarget>):Array<UnusedImport> {
		var statements:Array<{path:String, alias:Null<String>, wildcard:Bool, first:Int, last:Int}> = [];
		var index = 0;
		while (index < tokens.length) {
			var kind = tokens[index].kind;
			if (kind != TokenKind.Import && kind != TokenKind.Package) {
				index++;
				continue;
			}
			var first = index, parts:Array<String> = [], alias:Null<String> = null, wildcard = false;
			index++;
			while (index < tokens.length && tokens[index].kind != TokenKind.Semicolon && tokens[index].kind != TokenKind.Eof) {
				var token = tokens[index];
				if (token.kind == TokenKind.Star)
					wildcard = true;
				else if (token.kind == TokenKind.Identifier && token.text == "as" && parts.length > 0)
					alias = index + 1 < tokens.length ? tokens[index + 1].text : null;
				else if (token.kind == TokenKind.Identifier && alias == null)
					parts.push(token.text);
				index++;
			}
			if (kind == TokenKind.Import)
				statements.push({path: parts.join("."), alias: alias, wildcard: wildcard, first: first, last: index});
		}

		// Tokens inside an import or package statement name a path, not a use.
		var skipped:Map<Int, Bool> = [];
		for (statement in statements)
			for (position in statement.first...statement.last + 1)
				skipped.set(position, true);
		var mentioned:Map<String, Bool> = [];
		var word = ~/[A-Za-z_][A-Za-z0-9_]*/;
		for (position in 0...tokens.length) {
			var token = tokens[position];
			if (token.kind == TokenKind.Identifier && !skipped.exists(position))
				mentioned.set(token.text, true);
			else if (token.kind == TokenKind.StringLiteral && token.text.indexOf("$") >= 0) {
				// Interpolation (`$name`, `${expression}`) uses names the lexer keeps inside the string.
				var rest = token.text;
				while (word.match(rest)) {
					mentioned.set(word.matched(0), true);
					rest = word.matchedRight();
				}
			}
		}

		var unused = [];
		for (statement in statements) {
			if (statement.wildcard || statement.last >= tokens.length || used(statement.path, statement.alias, mentioned, resolve))
				continue;
			unused.push({path: statement.path, start: tokens[statement.first].span.start, end: tokens[statement.last].span.end});
		}
		return unused;
	}

	static function used(path:String, alias:Null<String>, mentioned:Map<String, Bool>, resolve:String->Null<ImportTarget>):Bool {
		if (alias != null)
			return mentioned.exists(alias);
		var target = resolve(path);
		if (target == null)
			return true;
		var names = visibleNames(target.program, target.member);
		if (names == null)
			return true;
		for (name in names)
			if (mentioned.exists(name))
				return true;
		return false;
	}

	/** The names an import of `member` (or of the whole module) makes usable, or null when implicit conversions make that open-ended. */
	static function visibleNames(program:AstProgram, member:Null<String>):Null<Array<String>> {
		var names:Array<String> = [];
		function wants(name:String):Bool
			return member == null || member == name;
		for (alias in program.aliases)
			if (wants(alias.name)) {
				// An alias of another named type can stand for an enum whose constructors it brings into scope.
				switch alias.type {
					case NamedType(_), AppliedType(_, _):
						return null;
					default:
				}
				names.push(alias.name);
			}
		for (declaration in program.enums)
			if (wants(declaration.name)) {
				names.push(declaration.name);
				for (item in declaration.cases)
					names.push(item.name);
			}
		for (declaration in program.enumAbstracts)
			if (wants(declaration.name)) {
				if (declaration.fromTypes.length > 0 || declaration.toTypes.length > 0)
					return null;
				names.push(declaration.name);
				for (value in declaration.values)
					names.push(value.name);
			}
		for (declaration in program.abstracts)
			if (wants(declaration.name)) {
				if (declaration.fromTypes.length > 0 || declaration.toTypes.length > 0)
					return null;
				names.push(declaration.name);
			}
		for (declaration in program.interfaces)
			if (wants(declaration.name))
				names.push(declaration.name);
		for (declaration in program.classes)
			if (wants(declaration.name))
				names.push(declaration.name);
		if (member == null)
			for (declaration in program.functions)
				names.push(declaration.name);
		return names.length == 0 ? null : names;
	}
}

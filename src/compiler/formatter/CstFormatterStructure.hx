package compiler.formatter;

import compiler.syntax.Token.TokenKind;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxNode;
import compiler.syntax.SyntaxTree.SyntaxTree;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.FormatToken.FormatTokenTools;

enum FormatNodeKind {
	Block;
	Parenthesized;
	ParameterList;
	ArgumentList;
	Call;
	ArrayLiteral;
	ObjectLiteral;
	TypeArgumentList;
	BinaryExpression;
	ConditionalExpression;
	Assignment;
	MemberChain;
	Condition;
}

typedef SyntaxInfo = {
	final nodeKinds:Map<String, FormatNodeKind>;
	final matchingByOffset:Map<Int, Int>;
	final blockOpens:Map<Int, Bool>;
	final blockCloses:Map<Int, Bool>;
}

/** Converts authoritative CST structure into layout-engine constraints. */
class CstFormatterStructure {
	/**
		Builds layout structure from parser-reported CST nodes. Expression and
		delimiter ownership comes from the CST; only inactive conditional source,
		which the compiler parser intentionally does not visit, gets a narrow
		brace-preservation pass.
	*/
	public static function annotate(tokens:Array<FormatToken>, tree:SyntaxTree, ?conditionalText:String):SyntaxInfo
		return annotateCst(tokens, tree, conditionalText);

	static function annotateCst(tokens:Array<FormatToken>, tree:SyntaxTree, conditionalText:Null<String>):SyntaxInfo {
		var result:SyntaxInfo = {
			nodeKinds: [],
			matchingByOffset: [],
			blockOpens: [],
			blockCloses: []
		};
		var tokenAtStart:Map<Int, Int> = [], tokenAtEnd:Map<Int, Int> = [];
		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index])) {
				tokenAtStart.set(tokens[index].start, index);
				tokenAtEnd.set(tokens[index].end, index);
			}
		applyGrammarNodes(tokens, result, tree, tokenAtStart, tokenAtEnd);
		mergeInactiveBlockDelimiters(tokens, result, conditionalText);
		return result;
	}

	/**
		Conditional compilation intentionally hides inactive source from the
		compiler parser. Preserve the formatter's view of those regions without
		overriding any delimiter or block ownership the active CST established.
	*/
	static function mergeInactiveBlockDelimiters(tokens:Array<FormatToken>, syntax:SyntaxInfo, conditionalText:Null<String>):Void {
		if (conditionalText == null)
			return;
		var masked = haxe.io.Bytes.ofString(conditionalText);
		for (token in tokens) {
			if (!isMaskedSyntaxToken(token, masked))
				continue;
			switch FormatTokenTools.syntaxKind(token) {
				case TokenKind.LeftBrace:
					if (!syntax.blockOpens.exists(token.start))
						syntax.blockOpens.set(token.start, true);
				case TokenKind.RightBrace:
					if (!syntax.blockCloses.exists(token.start))
						syntax.blockCloses.set(token.start, true);
				default:
			}
		}
	}

	static function isMaskedSyntaxToken(token:FormatToken, masked:haxe.io.Bytes):Bool {
		if (!FormatTokenTools.isSyntax(token) || token.start < 0 || token.start >= masked.length)
			return false;
		return masked.get(token.start) == " ".code;
	}

	/** Applies authoritative delimiter information already known by the parser. */
	static function applyGrammarNodes(tokens:Array<FormatToken>, syntax:SyntaxInfo, tree:SyntaxTree, tokenAtStart:Map<Int, Int>,
			tokenAtEnd:Map<Int, Int>):Void {
		for (node in tree.grammarNodes())
			switch node.kind {
				case SyntaxKind.Block:
					applyBlockNode(tokens, syntax, node, tokenAtStart, tokenAtEnd);
				case SyntaxKind.CallExpression:
					applyCallNode(tokens, syntax, node, tokenAtStart, tokenAtEnd);
				case SyntaxKind.BinaryExpression:
					applyExpressionNode(tokens, syntax, node, FormatNodeKind.BinaryExpression, tokenAtStart, tokenAtEnd);
				case SyntaxKind.ConditionalExpression:
					applyExpressionNode(tokens, syntax, node, FormatNodeKind.ConditionalExpression, tokenAtStart, tokenAtEnd);
				case SyntaxKind.AssignmentExpression, SyntaxKind.AssignmentStatement:
					applyExpressionNode(tokens, syntax, node, FormatNodeKind.Assignment, tokenAtStart, tokenAtEnd);
				case SyntaxKind.MemberExpression:
					applyExpressionNode(tokens, syntax, node, FormatNodeKind.MemberChain, tokenAtStart, tokenAtEnd);
				case SyntaxKind.TypeArgumentList, SyntaxKind.TypeParameterList:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.TypeArgumentList, tokenAtStart, tokenAtEnd);
				case SyntaxKind.ParameterList:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.ParameterList, tokenAtStart, tokenAtEnd);
				case SyntaxKind.ArgumentList:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.ArgumentList, tokenAtStart, tokenAtEnd);
				case SyntaxKind.ParenthesizedExpression:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.Parenthesized, tokenAtStart, tokenAtEnd);
				case SyntaxKind.ArrayLiteral:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.ArrayLiteral, tokenAtStart, tokenAtEnd);
				case SyntaxKind.ObjectLiteral, SyntaxKind.MapLiteral, SyntaxKind.AnonymousType:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.ObjectLiteral, tokenAtStart, tokenAtEnd);
				case SyntaxKind.SourceFile, SyntaxKind.PackageDeclaration, SyntaxKind.ImportDeclaration,
					SyntaxKind.TypeAliasDeclaration, SyntaxKind.EnumDeclaration, SyntaxKind.EnumAbstractDeclaration,
					SyntaxKind.AbstractDeclaration, SyntaxKind.InterfaceDeclaration, SyntaxKind.ClassDeclaration,
					SyntaxKind.FunctionDeclaration, SyntaxKind.FieldDeclaration, SyntaxKind.Metadata,
					SyntaxKind.IndexExpression, SyntaxKind.VariableDeclaration, SyntaxKind.ThrowStatement,
					SyntaxKind.TryStatement, SyntaxKind.SwitchStatement, SyntaxKind.IncrementStatement,
					SyntaxKind.ExpressionStatement, SyntaxKind.ReturnStatement, SyntaxKind.BreakStatement,
					SyntaxKind.ContinueStatement, SyntaxKind.IfStatement, SyntaxKind.WhileStatement,
					SyntaxKind.DoWhileStatement, SyntaxKind.ForStatement, SyntaxKind.Error, SyntaxKind.Missing:
					// These nodes are structurally useful to other tooling, but do not
					// change formatter layout constraints yet.
			}
	}

	static function applyExpressionNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode, kind:FormatNodeKind,
		 tokenAtStart:Map<Int, Int>, tokenAtEnd:Map<Int, Int>):Void {
		var start = tokenAtStart.get(node.span.start), end = tokenAtEnd.get(node.span.end);
		if (start == null || end == null || end < start)
			return;
		var key = tokens[start].start + ":" + tokens[end].start;
		if (!syntax.nodeKinds.exists(key) || !isDelimiterNode(syntax.nodeKinds.get(key)))
			syntax.nodeKinds.set(key, kind);
	}

	static function applyBlockNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode, tokenAtStart:Map<Int, Int>,
			tokenAtEnd:Map<Int, Int>):Void {
		var open = tokenAtStart.get(node.span.start), close = tokenAtEnd.get(node.span.end);
		if (open == null || close == null || open >= close)
			return;
		if (FormatTokenTools.syntaxKind(tokens[open]) != TokenKind.LeftBrace
			|| FormatTokenTools.syntaxKind(tokens[close]) != TokenKind.RightBrace)
			return;
		setMatching(syntax, tokens, open, close);
		syntax.blockOpens.set(tokens[open].start, true);
		syntax.blockCloses.set(tokens[close].start, true);
		syntax.nodeKinds.set(open + ":" + close, FormatNodeKind.Block);
	}

	static function applyCallNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode, tokenAtStart:Map<Int, Int>,
			tokenAtEnd:Map<Int, Int>):Void {
		var argumentList:Null<SyntaxNode> = null;
		for (child in node.grammarChildren)
			if (child.kind == SyntaxKind.ArgumentList && child.span.end == node.span.end) {
				argumentList = child;
				break;
			}
		if (argumentList == null)
			return;
		var open = tokenAtStart.get(argumentList.span.start), close = tokenAtEnd.get(argumentList.span.end);
		if (open == null || close == null || close < open
			|| FormatTokenTools.syntaxKind(tokens[open]) != TokenKind.LeftParen
			|| FormatTokenTools.syntaxKind(tokens[close]) != TokenKind.RightParen)
			return;
		setMatching(syntax, tokens, open, close);
		syntax.nodeKinds.set(tokens[open].start + ":" + tokens[close].start, FormatNodeKind.Call);
	}

	static function applyDelimitedNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode, kind:FormatNodeKind,
			tokenAtStart:Map<Int, Int>, tokenAtEnd:Map<Int, Int>):Void {
		var open = tokenAtStart.get(node.span.start), close = tokenAtEnd.get(node.span.end);
		if (open == null || close == null || close < open)
			return;
		var openKind = FormatTokenTools.syntaxKind(tokens[open]), closeKind = FormatTokenTools.syntaxKind(tokens[close]), valid = switch kind {
			case FormatNodeKind.TypeArgumentList: openKind == TokenKind.Less && closeKind == TokenKind.Greater;
			case FormatNodeKind.ParameterList, FormatNodeKind.ArgumentList, FormatNodeKind.Parenthesized: openKind == TokenKind.LeftParen && closeKind == TokenKind.RightParen;
			case FormatNodeKind.ArrayLiteral: openKind == TokenKind.LeftBracket && closeKind == TokenKind.RightBracket;
			case FormatNodeKind.ObjectLiteral: openKind == TokenKind.LeftBrace && closeKind == TokenKind.RightBrace;
			default: false;
		};
		if (!valid)
			return;
		setMatching(syntax, tokens, open, close);
		syntax.nodeKinds.set(tokens[open].start + ":" + tokens[close].start, kind);
		if (kind == FormatNodeKind.ObjectLiteral)
			syntax.blockOpens.set(tokens[open].start, false);
	}

	static function setMatching(syntax:SyntaxInfo, tokens:Array<FormatToken>, open:Int, close:Int):Void {
		syntax.matchingByOffset.set(tokens[open].start, tokens[close].start);
		syntax.matchingByOffset.set(tokens[close].start, tokens[open].start);
	}

	static function isDelimiterNode(kind:FormatNodeKind):Bool
		return switch kind {
			case FormatNodeKind.Block, FormatNodeKind.Parenthesized, FormatNodeKind.ParameterList, FormatNodeKind.ArgumentList, FormatNodeKind.Call,
				FormatNodeKind.ArrayLiteral, FormatNodeKind.ObjectLiteral, FormatNodeKind.TypeArgumentList, FormatNodeKind.Condition: true;
			default: false;
		};
}

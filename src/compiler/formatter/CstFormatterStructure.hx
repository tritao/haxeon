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

typedef FormatNode = {
	final kind:FormatNodeKind;
	final start:Int;
	final end:Int;
	final parent:Null<Int>;
}

typedef SyntaxInfo = {
	final nodes:Array<FormatNode>;
	final nodeKinds:Map<String, FormatNodeKind>;
	final matching:Map<Int, Int>;
	final matchingByOffset:Map<Int, Int>;
	final blockOpens:Map<Int, Bool>;
	final blockCloses:Map<Int, Bool>;
	final blockDepth:Map<Int, Int>;
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
			nodes: [],
			nodeKinds: [],
			matching: [],
			matchingByOffset: [],
			blockOpens: [],
			blockCloses: [],
			blockDepth: []
		};
		applyGrammarNodes(tokens, result, tree);
		mergeInactiveBlockDelimiters(tokens, result, conditionalText);
		annotateParents(result.nodes);
		for (index in 0...tokens.length) {
			if (!FormatTokenTools.isSyntax(tokens[index]))
				continue;
			var depth = 0;
			for (node in result.nodes)
				if (node.kind == FormatNodeKind.Block
					&& tokens[node.start].start <= tokens[index].start
					&& tokens[node.end].end > tokens[index].start)
					depth++;
			result.blockDepth.set(tokens[index].start, depth);
		}
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
	static function applyGrammarNodes(tokens:Array<FormatToken>, syntax:SyntaxInfo, tree:SyntaxTree):Void {
		for (node in tree.grammarNodes())
			switch node.kind {
				case SyntaxKind.Block:
					applyBlockNode(tokens, syntax, node);
				case SyntaxKind.CallExpression:
					applyCallNode(tokens, syntax, node);
				case SyntaxKind.BinaryExpression:
					applyExpressionNode(tokens, syntax, node, FormatNodeKind.BinaryExpression);
				case SyntaxKind.ConditionalExpression:
					applyExpressionNode(tokens, syntax, node, FormatNodeKind.ConditionalExpression);
				case SyntaxKind.AssignmentExpression, SyntaxKind.AssignmentStatement:
					applyExpressionNode(tokens, syntax, node, FormatNodeKind.Assignment);
				case SyntaxKind.MemberExpression:
					applyExpressionNode(tokens, syntax, node, FormatNodeKind.MemberChain);
				case SyntaxKind.TypeArgumentList, SyntaxKind.TypeParameterList:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.TypeArgumentList);
				case SyntaxKind.ParameterList:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.ParameterList);
				case SyntaxKind.ArgumentList:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.ArgumentList);
				case SyntaxKind.ParenthesizedExpression:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.Parenthesized);
				case SyntaxKind.ArrayLiteral:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.ArrayLiteral);
				case SyntaxKind.ObjectLiteral, SyntaxKind.MapLiteral, SyntaxKind.AnonymousType:
					applyDelimitedNode(tokens, syntax, node, FormatNodeKind.ObjectLiteral);
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

	static function applyExpressionNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode, kind:FormatNodeKind):Void {
		var start = tokenIndexAt(tokens, node.span.start), end = tokenIndexEndingAt(tokens, node.span.end);
		if (start < 0 || end < start)
			return;
		var key = tokens[start].start + ":" + tokens[end].start;
		if (!syntax.nodeKinds.exists(key) || !isDelimiterNode(syntax.nodeKinds.get(key)))
			syntax.nodeKinds.set(key, kind);
		syntax.nodes.push({kind: kind, start: start, end: end, parent: null});
	}

	static function applyBlockNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode):Void {
		var open = tokenIndexAt(tokens, node.span.start), close = tokenIndexEndingAt(tokens, node.span.end);
		if (open < 0 || close < 0 || open >= close)
			return;
		if (FormatTokenTools.syntaxKind(tokens[open]) != TokenKind.LeftBrace
			|| FormatTokenTools.syntaxKind(tokens[close]) != TokenKind.RightBrace)
			return;
		setMatching(syntax, tokens, open, close);
		syntax.blockOpens.set(tokens[open].start, true);
		syntax.blockCloses.set(tokens[close].start, true);
		syntax.nodeKinds.set(open + ":" + close, FormatNodeKind.Block);
		syntax.nodes.push({kind: FormatNodeKind.Block, start: open, end: close, parent: null});
	}

	static function applyCallNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode):Void {
		var argumentList:Null<SyntaxNode> = null;
		for (child in node.grammarChildren)
			if (child.kind == SyntaxKind.ArgumentList && child.span.end == node.span.end) {
				argumentList = child;
				break;
			}
		if (argumentList == null)
			return;
		var open = tokenIndexAt(tokens, argumentList.span.start), close = tokenIndexEndingAt(tokens, argumentList.span.end);
		if (open < 0 || close < open
			|| FormatTokenTools.syntaxKind(tokens[open]) != TokenKind.LeftParen
			|| FormatTokenTools.syntaxKind(tokens[close]) != TokenKind.RightParen)
			return;
		setMatching(syntax, tokens, open, close);
		syntax.nodeKinds.set(tokens[open].start + ":" + tokens[close].start, FormatNodeKind.Call);
		syntax.nodes.push({kind: FormatNodeKind.Call, start: open, end: close, parent: null});
	}

	static function applyDelimitedNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode, kind:FormatNodeKind):Void {
		var open = tokenIndexAt(tokens, node.span.start), close = tokenIndexEndingAt(tokens, node.span.end);
		if (open < 0 || close < open)
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
		syntax.nodes.push({kind: kind, start: open, end: close, parent: null});
	}

	static function setMatching(syntax:SyntaxInfo, tokens:Array<FormatToken>, open:Int, close:Int):Void {
		syntax.matching.set(open, close);
		syntax.matching.set(close, open);
		syntax.matchingByOffset.set(tokens[open].start, tokens[close].start);
		syntax.matchingByOffset.set(tokens[close].start, tokens[open].start);
	}

	static function tokenIndexAt(tokens:Array<FormatToken>, offset:Int):Int {
		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index]) && tokens[index].start == offset)
				return index;
		return -1;
	}

	static function tokenIndexEndingAt(tokens:Array<FormatToken>, offset:Int):Int {
		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index]) && tokens[index].end == offset)
				return index;
		return -1;
	}

	static function annotateParents(nodes:Array<FormatNode>):Void {
		for (index in 0...nodes.length) {
			var node = nodes[index], parent:Null<FormatNode> = null;
			for (candidateIndex in 0...nodes.length) {
				if (candidateIndex == index)
					continue;
				var candidate = nodes[candidateIndex],
					contains = candidate.start <= node.start && candidate.end >= node.end,
					strict = candidate.start < node.start || candidate.end > node.end;
				if (!contains || !strict || (parent != null && candidate.end - candidate.start >= parent.end - parent.start))
					continue;
				parent = candidate;
			}
			if (parent != null)
				nodes[index] = {
					kind: node.kind,
					start: node.start,
					end: node.end,
					parent: parent.start
				};
		}
	}

	static function isDelimiterNode(kind:FormatNodeKind):Bool
		return switch kind {
			case FormatNodeKind.Block, FormatNodeKind.Parenthesized, FormatNodeKind.ParameterList, FormatNodeKind.ArgumentList, FormatNodeKind.Call,
				FormatNodeKind.ArrayLiteral, FormatNodeKind.ObjectLiteral, FormatNodeKind.TypeArgumentList, FormatNodeKind.Condition: true;
			default: false;
		};
}

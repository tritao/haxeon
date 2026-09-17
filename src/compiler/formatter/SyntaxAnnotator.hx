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
	final blockOpens:Map<Int, Bool>;
	final blockCloses:Map<Int, Bool>;
	final blockDepth:Map<Int, Int>;
}

private typedef OpenNode = {
	final tokenIndex:Int;
	final kind:FormatNodeKind;
	final block:Bool;
}

/** Translates parser structure into the formatter's layout-oriented view. */
class SyntaxAnnotator {
	/**
		Annotates formatter tokens with the parser's syntax tree when tooling mode
		is available. The legacy token pass remains as a compatibility fallback for
		grammar constructs that have not yet received parser events.
	*/
	public static function annotate(tokens:Array<FormatToken>, ?tree:SyntaxTree):SyntaxInfo {
		return tree == null ? annotateTokens(tokens) : annotateCst(tokens, tree);
	}

	/**
		Builds layout structure from parser-reported CST nodes. Token heuristics
		remain only for expression categories that are not yet grammar nodes; all
		delimiter and block ownership comes from the CST in tooling mode.
	*/
	static function annotateCst(tokens:Array<FormatToken>, tree:SyntaxTree):SyntaxInfo {
		var result:SyntaxInfo = {
			nodes: [],
			nodeKinds: [],
			matching: [],
			blockOpens: [],
			blockCloses: [],
			blockDepth: []
		};
		applyGrammarNodes(tokens, result, tree);
		mergeUnparsedSourceRegions(tokens, result);
		// Binary/conditional/member layout constraints are not represented by
		// grammar nodes yet. Keep this narrow pass until those parser events are
		// available; it cannot classify delimiters or braces.
		var syntaxIndexes:Array<Int> = [];
		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index]))
				syntaxIndexes.push(index);
		annotateExpressionNodes(tokens, syntaxIndexes, result.nodes);
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
	static function mergeUnparsedSourceRegions(tokens:Array<FormatToken>, syntax:SyntaxInfo):Void {
		var fallback = annotateTokens(tokens);
		for (key in fallback.blockOpens.keys())
			if (!syntax.blockOpens.exists(key))
				syntax.blockOpens.set(key, fallback.blockOpens.get(key));
		for (key in fallback.blockCloses.keys())
			if (!syntax.blockCloses.exists(key))
				syntax.blockCloses.set(key, fallback.blockCloses.get(key));
		for (key in fallback.matching.keys())
			if (!syntax.matching.exists(key))
				syntax.matching.set(key, fallback.matching.get(key));
		for (node in fallback.nodes) {
			var key = tokens[node.start].start + ":" + tokens[node.end].start;
			if (!syntax.nodeKinds.exists(key)) {
				syntax.nodeKinds.set(key, node.kind);
				syntax.nodes.push({kind: node.kind, start: node.start, end: node.end, parent: null});
			}
		}
	}

	static function annotateTokens(tokens:Array<FormatToken>):SyntaxInfo {
		var nodes:Array<FormatNode> = [], matching:Map<Int, Int> = [], blockOpens:Map<Int, Bool> = [], blockCloses:Map<Int, Bool> = [],
			blockDepth:Map<Int, Int> = [], stack:Array<OpenNode> = [], genericStack:Array<Int> = [], syntaxIndexes:Array<Int> = [], depth = 0;

		for (index in 0...tokens.length)
			if (FormatTokenTools.isSyntax(tokens[index]))
				syntaxIndexes.push(index);

		for (position in 0...syntaxIndexes.length) {
			var index = syntaxIndexes[position],
				token = tokens[index],
				kind = FormatTokenTools.syntaxKind(token);
			if (kind == null)
				continue;
			blockDepth.set(token.start, depth);
			switch kind {
				case TokenKind.LeftBrace:
					var block = isBlockOpen(tokens, syntaxIndexes, position),
						nodeKind = block ? FormatNodeKind.Block : FormatNodeKind.ObjectLiteral;
					blockOpens.set(token.start, block);
					stack.push({tokenIndex: index, kind: nodeKind, block: block});
					if (block)
						depth++;
				case TokenKind.LeftParen:
					var parenthesisKind = parenthesisKind(tokens, syntaxIndexes, position);
					stack.push({tokenIndex: index, kind: parenthesisKind, block: false});
				case TokenKind.LeftBracket:
					var previous = previousKind(tokens, syntaxIndexes, position),
						array = previous == null || previous == TokenKind.Assign || previous == TokenKind.Return || previous == TokenKind.Comma
							|| previous == TokenKind.LeftParen || previous == TokenKind.LeftBracket;
					stack.push({tokenIndex: index, kind: array ? FormatNodeKind.ArrayLiteral : FormatNodeKind.Parenthesized, block: false});
				case TokenKind.Less:
					if (isGenericOpen(tokens, syntaxIndexes, position))
						genericStack.push(index);
				case TokenKind.Greater:
					if (genericStack.length > 0) {
						var genericStart = genericStack.pop();
						nodes.push({
							kind: FormatNodeKind.TypeArgumentList,
							start: genericStart,
							end: index,
							parent: null
						});
						matching.set(genericStart, index);
						matching.set(index, genericStart);
					}
				case TokenKind.RightBrace, TokenKind.RightParen, TokenKind.RightBracket:
					closeNode(tokens, stack, nodes, matching, blockCloses, index);
				default:
			}
		}
		annotateExpressionNodes(tokens, syntaxIndexes, nodes);
		annotateParents(nodes);
		var nodeKinds:Map<String, FormatNodeKind> = [];
		for (node in nodes) {
			var key = tokens[node.start].start + ":" + tokens[node.end].start;
			if (!nodeKinds.exists(key) || isDelimiterNode(node.kind))
				nodeKinds.set(key, node.kind);
		}
		return {
			nodes: nodes,
			nodeKinds: nodeKinds,
			matching: matching,
			blockOpens: blockOpens,
			blockCloses: blockCloses,
			blockDepth: blockDepth
		};
	}

	/** Applies authoritative delimiter information already known by the parser. */
	static function applyGrammarNodes(tokens:Array<FormatToken>, syntax:SyntaxInfo, tree:SyntaxTree):Void {
		for (node in tree.grammarNodes())
			switch node.kind {
				case SyntaxKind.Block:
					applyBlockNode(tokens, syntax, node);
				case SyntaxKind.CallExpression:
					applyCallNode(tokens, syntax, node);
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
				default:
					// Declaration and recovery nodes are consumed by structural tooling;
					// they do not affect layout decisions yet.
			}
	}

	static function applyBlockNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode):Void {
		var open = tokenIndexAt(tokens, node.span.start), close = tokenIndexEndingAt(tokens, node.span.end);
		if (open < 0 || close < 0 || open >= close)
			return;
		if (FormatTokenTools.syntaxKind(tokens[open]) != TokenKind.LeftBrace
			|| FormatTokenTools.syntaxKind(tokens[close]) != TokenKind.RightBrace)
			return;
		syntax.matching.set(open, close);
		syntax.matching.set(close, open);
		syntax.blockOpens.set(tokens[open].start, true);
		syntax.blockCloses.set(tokens[close].start, true);
		syntax.nodeKinds.set(open + ":" + close, FormatNodeKind.Block);
		syntax.nodes.push({kind: FormatNodeKind.Block, start: open, end: close, parent: null});
	}

	static function applyCallNode(tokens:Array<FormatToken>, syntax:SyntaxInfo, node:SyntaxNode):Void {
		var start = tokenIndexAt(tokens, node.span.start), end = tokenIndexEndingAt(tokens, node.span.end);
		if (start < 0 || end < start || FormatTokenTools.syntaxKind(tokens[end]) != TokenKind.RightParen)
			return;
		var open = matchingLeftParen(tokens, start, end);
		if (open >= 0) {
			syntax.matching.set(open, end);
			syntax.matching.set(end, open);
			syntax.nodeKinds.set(tokens[open].start + ":" + tokens[end].start, FormatNodeKind.Call);
			syntax.nodes.push({kind: FormatNodeKind.Call, start: open, end: end, parent: null});
		}
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
		syntax.matching.set(open, close);
		syntax.matching.set(close, open);
		syntax.nodeKinds.set(tokens[open].start + ":" + tokens[close].start, kind);
		if (kind == FormatNodeKind.ObjectLiteral)
			syntax.blockOpens.set(tokens[open].start, false);
		syntax.nodes.push({kind: kind, start: open, end: close, parent: null});
	}

	static function matchingLeftParen(tokens:Array<FormatToken>, start:Int, close:Int):Int {
		var depth = 0, index = close;
		while (index >= start) {
			var kind = FormatTokenTools.syntaxKind(tokens[index]);
			switch kind {
				case TokenKind.RightParen:
					depth++;
				case TokenKind.LeftParen:
					if (depth == 0)
						return index;
					depth--;
				default:
			}
			index--;
		}
		return -1;
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

	static function closeNode(tokens:Array<FormatToken>, stack:Array<OpenNode>, nodes:Array<FormatNode>, matching:Map<Int, Int>, blockCloses:Map<Int, Bool>,
			closeIndex:Int):Void {
		if (stack.length == 0)
			return;
		var open = stack[stack.length - 1];
		var compatible = switch tokens[closeIndex].kind {
			case FormatTokenKind.Syntax(TokenKind.RightBrace): open.kind == FormatNodeKind.Block || open.kind == FormatNodeKind.ObjectLiteral;
			case FormatTokenKind.Syntax(TokenKind.RightParen):
				open.kind == FormatNodeKind.Parenthesized
				|| open.kind == FormatNodeKind.Condition
				|| open.kind == FormatNodeKind.ParameterList
				|| open.kind == FormatNodeKind.ArgumentList;
			case FormatTokenKind.Syntax(TokenKind.RightBracket): open.kind == FormatNodeKind.ArrayLiteral || open.kind == FormatNodeKind.Parenthesized;
			default: false;
		};
		if (!compatible)
			return;
		stack.pop();
		var parent:Null<Int> = null;
		if (stack.length > 0)
			parent = stack[stack.length - 1].tokenIndex;
		nodes.push({
			kind: open.kind,
			start: open.tokenIndex,
			end: closeIndex,
			parent: parent
		});
		if (open.kind == FormatNodeKind.ArgumentList)
			nodes.push({
				kind: FormatNodeKind.Call,
				start: open.tokenIndex,
				end: closeIndex,
				parent: parent
			});
		matching.set(open.tokenIndex, closeIndex);
		matching.set(closeIndex, open.tokenIndex);
		if (open.kind == FormatNodeKind.Block)
			blockCloses.set(tokens[closeIndex].start, true);
	}

	static function isBlockOpen(tokens:Array<FormatToken>, syntaxIndexes:Array<Int>, position:Int):Bool {
		var previous = previousKind(tokens, syntaxIndexes, position);
		if (previous == null || previous == TokenKind.RightParen || previous == TokenKind.Else || previous == TokenKind.Try || previous == TokenKind.Catch
			|| previous == TokenKind.Final)
			return true;
		return switch previous {
			case TokenKind.Assign, TokenKind.Colon, TokenKind.Comma, TokenKind.LeftParen, TokenKind.LeftBracket, TokenKind.Arrow, TokenKind.Return: false;
			default: true;
		};
	}

	static function parenthesisKind(tokens:Array<FormatToken>, syntaxIndexes:Array<Int>, position:Int):FormatNodeKind {
		var previous = previousKind(tokens, syntaxIndexes, position);
		if (previous == TokenKind.If || previous == TokenKind.While || previous == TokenKind.For || previous == TokenKind.Switch || previous == TokenKind.Catch)
			return FormatNodeKind.Condition;
		var lookback = position - 1;
		while (lookback >= 0 && position - lookback < 10) {
			var kind = FormatTokenTools.syntaxKind(tokens[syntaxIndexes[lookback]]);
			if (kind == TokenKind.Function)
				return FormatNodeKind.ParameterList;
			if (kind == TokenKind.Semicolon || kind == TokenKind.LeftBrace || kind == TokenKind.RightBrace)
				break;
			lookback--;
		}
		if (previous == TokenKind.Identifier || previous == TokenKind.New || previous == TokenKind.RightParen || previous == TokenKind.RightBracket
			|| previous == TokenKind.Dot)
			return FormatNodeKind.ArgumentList;
		return FormatNodeKind.Parenthesized;
	}

	static function previousKind(tokens:Array<FormatToken>, syntaxIndexes:Array<Int>, position:Int):Null<TokenKind> {
		if (position <= 0)
			return null;
		return FormatTokenTools.syntaxKind(tokens[syntaxIndexes[position - 1]]);
	}

	static function annotateExpressionNodes(tokens:Array<FormatToken>, syntaxIndexes:Array<Int>, nodes:Array<FormatNode>):Void {
		var segmentStart = 0, parens = 0, brackets = 0, braces = 0;
		for (position in 0...syntaxIndexes.length) {
			var kind = FormatTokenTools.syntaxKind(tokens[syntaxIndexes[position]]);
			switch kind {
				case TokenKind.LeftParen:
					parens++;
				case TokenKind.RightParen:
					parens = Std.int(Math.max(0, parens - 1));
				case TokenKind.LeftBracket:
					brackets++;
				case TokenKind.RightBracket:
					brackets = Std.int(Math.max(0, brackets - 1));
				case TokenKind.LeftBrace:
					braces++;
				case TokenKind.RightBrace:
					if (parens == 0 && brackets == 0 && braces == 0) {
						addExpressionNodes(tokens, syntaxIndexes, segmentStart, position, nodes);
						segmentStart = position + 1;
					}
					braces = Std.int(Math.max(0, braces - 1));
				case TokenKind.Semicolon:
					if (parens == 0 && brackets == 0 && braces == 0) {
						addExpressionNodes(tokens, syntaxIndexes, segmentStart, position, nodes);
						segmentStart = position + 1;
					}
				default:
			}
		}
		addExpressionNodes(tokens, syntaxIndexes, segmentStart, syntaxIndexes.length, nodes);
	}

	static function addExpressionNodes(tokens:Array<FormatToken>, syntaxIndexes:Array<Int>, start:Int, end:Int, nodes:Array<FormatNode>):Void {
		if (start >= end)
			return;
		var hasBinary = false,
			hasAssignment = false,
			hasConditional = false,
			hasMember = false;
		for (position in start...end) {
			var kind = FormatTokenTools.syntaxKind(tokens[syntaxIndexes[position]]);
			if (isAssignment(kind))
				hasAssignment = true;
			else if (isBinary(kind))
				hasBinary = true;
			if (kind == TokenKind.Question)
				hasConditional = true;
			if (kind == TokenKind.Dot)
				hasMember = true;
		}
		var first = syntaxIndexes[start], last = syntaxIndexes[end - 1];
		if (hasAssignment)
			nodes.push({
				kind: FormatNodeKind.Assignment,
				start: first,
				end: last,
				parent: null
			});
		if (hasConditional)
			nodes.push({
				kind: FormatNodeKind.ConditionalExpression,
				start: first,
				end: last,
				parent: null
			});
		if (hasBinary)
			nodes.push({
				kind: FormatNodeKind.BinaryExpression,
				start: first,
				end: last,
				parent: null
			});
		if (hasMember)
			nodes.push({
				kind: FormatNodeKind.MemberChain,
				start: first,
				end: last,
				parent: null
			});
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

	static function isAssignment(kind:Null<TokenKind>):Bool
		return kind == TokenKind.Assign || kind == TokenKind.PlusAssign || kind == TokenKind.MinusAssign || kind == TokenKind.StarAssign
			|| kind == TokenKind.SlashAssign || kind == TokenKind.PercentAssign || kind == TokenKind.AndAssign || kind == TokenKind.OrAssign
			|| kind == TokenKind.XorAssign;

	static function isBinary(kind:Null<TokenKind>):Bool
		return kind == TokenKind.AndAnd || kind == TokenKind.OrOr || kind == TokenKind.EqualEqual || kind == TokenKind.NotEqual || kind == TokenKind.Less
			|| kind == TokenKind.Greater || kind == TokenKind.LessEqual || kind == TokenKind.GreaterEqual || kind == TokenKind.Plus
			|| kind == TokenKind.Minus || kind == TokenKind.Star || kind == TokenKind.Slash || kind == TokenKind.Percent || kind == TokenKind.Ampersand
			|| kind == TokenKind.Pipe || kind == TokenKind.Caret;

	static function isGenericOpen(tokens:Array<FormatToken>, syntaxIndexes:Array<Int>, position:Int):Bool {
		if (position <= 0 || FormatTokenTools.syntaxKind(tokens[syntaxIndexes[position]]) != TokenKind.Less)
			return false;
		var previous = previousKind(tokens, syntaxIndexes, position);
		if (previous != TokenKind.Identifier && previous != TokenKind.TypeInt && previous != TokenKind.TypeBool && previous != TokenKind.TypeFloat
			&& previous != TokenKind.TypeString && previous != TokenKind.Void && previous != TokenKind.Greater && previous != TokenKind.RightBracket)
			return false;
		var depth = 0, hasContent = false;
		for (cursor in position...syntaxIndexes.length) {
			var kind = FormatTokenTools.syntaxKind(tokens[syntaxIndexes[cursor]]);
			switch kind {
				case TokenKind.Less:
					depth++;
				case TokenKind.Greater:
					depth--;
					if (depth == 0) {
						var after = cursor + 1 < syntaxIndexes.length ? FormatTokenTools.syntaxKind(tokens[syntaxIndexes[cursor + 1]]) : null;
						return hasContent
							&& (after == null || after == TokenKind.LeftParen || after == TokenKind.LeftBracket || after == TokenKind.Dot
								|| after == TokenKind.Comma || after == TokenKind.RightParen || after == TokenKind.RightBracket
								|| after == TokenKind.RightBrace || after == TokenKind.Assign || after == TokenKind.Colon || after == TokenKind.Semicolon
								|| after == TokenKind.Arrow);
					}
				case TokenKind.Comma, TokenKind.Identifier, TokenKind.TypeInt, TokenKind.TypeBool, TokenKind.TypeFloat, TokenKind.TypeString, TokenKind.Void:
					hasContent = true;
				default:
					return false;
			}
		}
		return false;
	}
}

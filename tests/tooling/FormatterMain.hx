import compiler.Source.SourceFile;
import compiler.formatter.FormatToken.FormatTokenKind;
import compiler.formatter.Formatter;
import compiler.formatter.FormatConfig.FormatConfigTools;
import compiler.formatter.CstFormatterAdapter;
import compiler.formatter.CstFormatterStructure;
import compiler.service.SourceFormatter;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.syntax.SyntaxTree.ParserMode;
import compiler.syntax.SyntaxTree.SyntaxKind;
import compiler.syntax.SyntaxTree.SyntaxTree;
import compiler.syntax.Token.TokenKind;

class FormatterMain {
	static function main():Void {
		var source = "function main():Int {\nvar text = \"{ literal }\"; // }\n/* keep { } */\nif (true) {\nreturn 42;   \n}\n}\n",
			expected = "function main():Int {\n  var text = \"{ literal }\"; // }\n  /* keep { } */\n  if (true) {\n    return 42;\n  }\n}\n",
			formatted = SourceFormatter.format(source, 2, true);
		if (formatted != expected || SourceFormatter.format(formatted, 2, true) != expected)
			throw "canonical formatter output was not stable";

		var metadataSource = new SourceFile("metadata.hx",
			"@:tag(\"demo\") class Main { @:field(\"value\") public var value:Int; }\n"),
			metadataParser = new Parser(new Lexer(metadataSource).tokenize(), null, ParserMode.Cst(metadataSource));
		metadataParser.parseProgram();
		var metadataTree = metadataParser.cst,
			metadataNodes = 0;
		for (node in metadataTree.grammarNodes())
			if (node.kind == SyntaxKind.Metadata)
				metadataNodes++;
		if (metadataNodes != 2)
			throw "formatter CST did not retain metadata structure";
		var metadataTokens = CstFormatterAdapter.tokens(metadataTree),
			metadataSyntax = CstFormatterStructure.annotate(metadataTokens, metadataTree),
			metadataOpen = metadataSource.text.indexOf("{");
		if (!metadataSyntax.blockOpens.exists(metadataOpen)
			|| !metadataSyntax.blockOpens.get(metadataOpen))
			throw "CST formatter structure did not retain declaration block ownership";
		var metadataFormatted = Formatter.format(metadataSource.text, FormatConfigTools.defaults(2, true));
		if (metadataFormatted == null
			|| metadataFormatted.indexOf("@:tag(\"demo\")") < 0
			|| metadataFormatted.indexOf("@:field(\"value\")") < 0
			|| Formatter.format(metadataFormatted, FormatConfigTools.defaults(2, true)) != metadataFormatted)
			throw "formatter did not preserve CST-backed metadata";

		var nestedCallSource = new SourceFile("nested-calls.hx",
			"function main():Int { return compute(transform(value)); }\n"),
			nestedCallParser = new Parser(new Lexer(nestedCallSource).tokenize(), null, ParserMode.Cst(nestedCallSource));
		nestedCallParser.parseProgram();
		var nestedCallTree = nestedCallParser.cst,
			nestedCallTokens = CstFormatterAdapter.tokens(nestedCallTree),
			nestedCallSyntax = CstFormatterStructure.annotate(nestedCallTokens, nestedCallTree),
			outerOpenOffset = nestedCallSource.text.indexOf("(", nestedCallSource.text.indexOf("compute")),
			innerOpenOffset = nestedCallSource.text.indexOf("(", nestedCallSource.text.indexOf("transform")),
			outerCloseOffset = nestedCallSource.text.lastIndexOf(")"),
			innerCloseOffset = nestedCallSource.text.indexOf(")", innerOpenOffset),
			outerOpen = -1, innerOpen = -1, outerClose = -1, innerClose = -1;
		for (index in 0...nestedCallTokens.length)
			switch nestedCallTokens[index].kind {
				case FormatTokenKind.Syntax(_):
					if (nestedCallTokens[index].start == outerOpenOffset) outerOpen = index;
					if (nestedCallTokens[index].start == innerOpenOffset) innerOpen = index;
					if (nestedCallTokens[index].end == outerCloseOffset + 1) outerClose = index;
					if (nestedCallTokens[index].end == innerCloseOffset + 1) innerClose = index;
				default:
			}
		if (outerOpen < 0 || innerOpen < 0 || outerClose < 0 || innerClose < 0
			|| !nestedCallSyntax.matching.exists(outerOpen) || nestedCallSyntax.matching.get(outerOpen) != outerClose
			|| !nestedCallSyntax.matching.exists(innerOpen) || nestedCallSyntax.matching.get(innerOpen) != innerClose)
			throw "formatter did not derive nested call delimiters from CST argument lists";

		var file = new SourceFile("round-trip.hx",
			"function main():String { var values:Array<Int> = [1,2]; var pattern=~/a[//]b/gi; var text='value ${1 + 2}'; // comment\nreturn text; }\n"),
			losslessTree = SyntaxTree.fromSource(file),
			tokens = CstFormatterAdapter.tokens(losslessTree);
		if (CstFormatterAdapter.roundTrip(tokens) != file.text)
			throw "shared lossless scanner did not round-trip source bytes";
		var cstParser = new Parser(new Lexer(file).tokenize(), null, ParserMode.Cst(file));
		cstParser.parseProgram();
		var cst = cstParser.cst;
		if (cst == null)
			throw "formatter parser did not produce a tooling CST";
		var cstTokens = CstFormatterAdapter.tokens(cst);
		if (CstFormatterAdapter.roundTrip(cstTokens) != file.text)
			throw "CST formatter adapter did not round-trip source bytes";
		if (cstTokens.length != tokens.length)
			throw "CST formatter adapter changed the lossless token stream";
		for (index in 0...tokens.length)
			if (Std.string(cstTokens[index].kind) != Std.string(tokens[index].kind) || cstTokens[index].text != tokens[index].text)
				throw "CST formatter adapter changed token spelling or trivia";
		var lexical = new Lexer(file).tokenize(),
			syntaxCount = 0,
			lexicalIndex = 0;
		for (token in tokens)
			switch token.kind {
				case FormatTokenKind.Syntax(kind):
					while (lexical[lexicalIndex].kind == TokenKind.Eof)
						break;
					if (lexical[lexicalIndex].kind != kind || lexical[lexicalIndex].text != token.text)
						throw "lossless scanner changed syntax token spelling";
					syntaxCount++;
					lexicalIndex++;
				default:
			}
		if (syntaxCount == 0 || lexical[lexicalIndex].kind != TokenKind.Eof)
			throw "lossless scanner changed syntax token sequence";
		var formattedRoundTrip = SourceFormatter.format(file.text, 2, true),
			reformattedLexical = new Lexer(new SourceFile("formatted.hx", formattedRoundTrip)).tokenize(),
			originalLexical = new Lexer(file).tokenize();
		lexicalIndex = 0;
		for (token in originalLexical) {
			if (token.kind == TokenKind.Eof)
				break;
			if (reformattedLexical[lexicalIndex].kind != token.kind || reformattedLexical[lexicalIndex].text != token.text)
				throw "formatting changed the syntax token sequence";
			lexicalIndex++;
		}
		if (reformattedLexical[lexicalIndex].kind != TokenKind.Eof)
			throw "formatted source contained unexpected syntax tokens";

		var config = FormatConfigTools.defaults(2, true);
		config.lineWidth = 60;
		var wrappedSource = "function build(name:String,arguments:Array<String>,configuration:Configuration):BuildResult { return computeSomething(firstValue,transform(secondValue),thirdValue); }\n",
			wrapped = Formatter.format(wrappedSource, config),
			expectedWrapped = "function build(\n  name:String,\n  arguments:Array<String>,\n  configuration:Configuration\n):BuildResult {\n  return computeSomething(\n    firstValue,\n    transform(secondValue),\n    thirdValue\n  );\n}\n";
		if (wrapped != expectedWrapped || Formatter.format(wrapped, config) != expectedWrapped)
			throw "width-aware formatter did not choose a stable expanded layout";
		for (line in wrapped.split("\n"))
			if (line.length > config.lineWidth)
				throw "breakable formatted output exceeded the configured line width";
		var wideContinuation = FormatConfigTools.defaults(2, true);
		wideContinuation.lineWidth = 40;
		wideContinuation.continuationIndentWidth = 4;
		var wideContinuationOutput = Formatter.format("function main():Int { return compute(firstValue,secondValue,thirdValue); }\n", wideContinuation);
		if (wideContinuationOutput == null
			|| wideContinuationOutput.indexOf("\n      firstValue,") < 0
			|| wideContinuationOutput.indexOf("\n    );") < 0)
			throw "continuation indentation width was not applied independently";
		var tabbed = SourceFormatter.format("function main():Int { return 0; }\n", 2, false);
		if (tabbed == null || tabbed.indexOf("\n\treturn 0;") < 0)
			throw "tab indentation configuration was not honored";
		var genericConfig = FormatConfigTools.defaults(2, true);
		genericConfig.lineWidth = 40;
		var generic = Formatter.format("function main():Int { var value:Map<FirstArgument,SecondArgument> = []; return 0; }\n", genericConfig),
			expectedGeneric = "function main():Int {\n  var value:Map<\n    FirstArgument,\n    SecondArgument\n  > = [];\n  return 0;\n}\n";
		if (generic != expectedGeneric)
			throw "generic argument list did not use a break opportunity";

		var switchSource = "function main():Int { switch value { case First: return firstValue; case Second: return secondValue; default: return 0; } return 0; }\n",
			switchFormatted = Formatter.format(switchSource, config),
			expectedSwitch = "function main():Int {\n  switch value {\n    case First:\n      return firstValue;\n    case Second:\n      return secondValue;\n    default:\n      return 0;\n  }\n  return 0;\n}\n";
		if (switchFormatted != expectedSwitch || Formatter.format(switchFormatted, config) != expectedSwitch)
			throw "switch cases did not receive stable structural indentation";
		var emptySwitch = Formatter.format("function main():Int { switch value {} return 0; }\n", config),
			expectedEmptySwitch = "function main():Int {\n  switch value {\n  }\n  return 0;\n}\n";
		if (emptySwitch != expectedEmptySwitch)
			throw "empty switch blocks did not close at the switch indentation";

		var expressionSource = "function main():Int { var result=firstCondition?firstValue:secondValue; return firstObject.secondObject.thirdObject.compute(firstArgument,secondArgument); }\n",
			expressionConfig = FormatConfigTools.defaults(2, true),
			expectedExpression = "function main():Int {\n  var result = firstCondition\n    ? firstValue : secondValue;\n  return firstObject\n    .secondObject.thirdObject.compute(\n      firstArgument,\n      secondArgument\n    );\n}\n";
		expressionConfig.lineWidth = 50;
		var expressionFormatted = Formatter.format(expressionSource, expressionConfig);
		if (expressionFormatted != expectedExpression || Formatter.format(expressionFormatted, expressionConfig) != expectedExpression)
			throw "expression chains and ternaries were not formatted canonically";

		var literalSource = "function main():Int { var values=[firstValue,secondValue,thirdValue,fourthValue]; var value={firstValue:firstValue,secondValue:secondValue,thirdValue:thirdValue}; return values[0]; }\n",
			literalFormatted = Formatter.format(literalSource, expressionConfig),
			expectedLiterals = "function main():Int {\n  var values = [\n    firstValue,\n    secondValue,\n    thirdValue,\n    fourthValue\n  ];\n  var value = {\n    firstValue: firstValue,\n    secondValue: secondValue,\n    thirdValue: thirdValue\n  };\n  return values[0];\n}\n";
		if (literalFormatted != expectedLiterals || Formatter.format(literalFormatted, expressionConfig) != expectedLiterals)
			throw "array and object literal groups were not stable";

		var rangeSource = "function main():Int {\nvar first=1;\nvar second=2;\nreturn first+second;\n}\n",
			rangeStart = rangeSource.indexOf("first"),
			rangeEnd = rangeSource.indexOf("second") + "second=2;".length,
			rangeFormatted = SourceFormatter.format(rangeSource, 2, true, rangeStart, rangeEnd);
		if (rangeFormatted == null || rangeFormatted.indexOf("\n  var first = 1;\n  var second = 2;\nreturn first+second;") < 0)
			throw "range formatting did not expand to complete logical lines";
		var rangeConfig = FormatConfigTools.defaults(2, true);
		rangeConfig.lineWidth = 40;
		var callRangeSource = "function main():Int {\nvar result=compute(firstArgument,secondArgument,thirdArgument);\nreturn result;\n}\n",
			callRangeStart = callRangeSource.indexOf("secondArgument"),
			callRangeEnd = callRangeStart + "secondArgument".length,
			callRangeFormatted = Formatter.format(callRangeSource, rangeConfig, callRangeStart, callRangeEnd),
			expectedCallRange = "function main():Int {\n  var result = compute(\n    firstArgument,\n    secondArgument,\n    thirdArgument\n  );\nreturn result;\n}\n";
		if (callRangeFormatted != expectedCallRange)
			throw "range formatting did not expand a partial call to its safe logical unit";

		var conditional = SourceFormatter.format("#if missing\nfunction first():Int {\nreturn 1;\n}\n#else\nfunction second():Int {\nreturn 2;\n}\n#end\n", 2,
			true),
			expectedConditional = "#if missing\nfunction first():Int {\n  return 1;\n}\n#else\nfunction second():Int {\n  return 2;\n}\n#end\n";
		if (conditional != expectedConditional)
			throw "conditional branches disturbed formatter indentation";

		var disabledSource = "function main():Int { // @formatter:off\n   var   untouched=foo( 1,2 );\n // @formatter:on\nreturn 0; }\n",
			disabled = SourceFormatter.format(disabledSource, 2, true),
			expectedDisabled = "function main():Int { // @formatter:off\n   var   untouched=foo( 1,2 );\n // @formatter:on\n  return 0;\n}\n";
		if (disabled != expectedDisabled)
			throw "formatter-off region was not preserved verbatim";
		var markerInString = SourceFormatter.format("function main():String {\nvar text=\"@formatter:off\";\nreturn text;\n}\n", 2, true),
			expectedMarkerInString = "function main():String {\n  var text = \"@formatter:off\";\n  return text;\n}\n";
		if (markerInString != expectedMarkerInString)
			throw "formatter markers inside strings changed formatting state";

		var crlf = SourceFormatter.format(StringTools.replace(source, "\n", "\r\n"), 2, true);
		if (crlf == null || crlf.indexOf("\r\n") < 0 || crlf.indexOf("\n") != crlf.indexOf("\r\n") + 1)
			throw "formatter did not preserve CRLF output";
		if (SourceFormatter.format("function main(:Int {", 2, true) != null)
			throw "formatter accepted malformed source";

		Sys.println("PASS: lossless width-aware formatter");
	}
}

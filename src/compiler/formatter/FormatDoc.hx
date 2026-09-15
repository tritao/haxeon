package compiler.formatter;

/** Small document algebra used by the formatter layout engine. */
enum FormatDoc {
	Text(value:String);
	HardLine;
	SoftLine(penalty:Int);
	Concat(items:Array<FormatDoc>);
	Indent(amount:Int, content:FormatDoc);
	Group(content:FormatDoc);
}

class FormatDocTools {
	public static function fromLine(line:UnwrappedLine, boundaries:Array<Boundary>):FormatDoc {
		var items:Array<FormatDoc> = [];
		for (index in 0...line.tokens.length) {
			if (index > 0) {
				var boundary = boundaries[index - 1];
				if (boundary.mustBreak)
					items.push(FormatDoc.HardLine);
				else if (boundary.canBreak)
					items.push(FormatDoc.SoftLine(boundary.penalty));
				else
					items.push(FormatDoc.Text(spaces(boundary.spaces)));
			}
			items.push(FormatDoc.Text(line.tokens[index].text));
		}
		return FormatDoc.Group(FormatDoc.Concat(items));
	}

	public static function flatLength(doc:FormatDoc):Int
		return switch doc {
			case Text(value): value.length;
			case HardLine: 0;
			case SoftLine(_): 1;
			case Concat(items):
				var total = 0;
				for (item in items)
					total += flatLength(item);
				total;
			case Indent(_, content), Group(content): flatLength(content);
		};

	public static function concat(items:Array<FormatDoc>):FormatDoc {
		var flattened:Array<FormatDoc> = [];
		for (item in items)
			switch item {
				case Concat(children):
					for (child in children)
						flattened.push(child);
				default:
					flattened.push(item);
			}
		return Concat(flattened);
	}

	static function spaces(count:Int):String {
		var result = "";
		for (_ in 0...count)
			result += " ";
		return result;
	}
}

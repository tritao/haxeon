package compiler.abi;

/**
 * Which line of a file's new text each line of its old text became, the way a text diff shows an edit: lines left as they
 * were match exactly (the longest common subsequence of lines), and between two such lines an old line and a new one that
 * read mostly the same are the same line edited. Lines deleted, inserted, or rewritten past recognition map to nothing.
 *
 * `LambdaAlignment` uses it to tell which edited lambda is which: a lambda's place in the old text, carried through the diff,
 * lands on the line the edited lambda now starts on. Comparing whole files costs time quadratic in the lines between the
 * first and the last changed one, so a larger change than `MAX_CHANGED_LINES` maps only the lines before and after it.
 */
class SourceLineMap {
	static inline final MAX_CHANGED_LINES:Int = 400;
	static inline final MAX_GAP_LINES:Int = 60;
	static inline final MAX_LINE_LENGTH:Int = 400;

	/** How much of two lines must be the same for them to be one line edited: twice the common characters over both lengths. */
	static inline final SIMILAR:Float = 0.6;

	/** The new line number (from 1) of each old line number that survived the edit. */
	public static function map(before:String, after:String):Map<Int, Int> {
		var a = lines(before), b = lines(after), result:Map<Int, Int> = [];
		var prefix = 0;
		while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
			result.set(prefix + 1, prefix + 1);
			prefix++;
		}
		var suffix = 0;
		while (suffix < a.length - prefix && suffix < b.length - prefix && a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
			result.set(a.length - suffix, b.length - suffix);
			suffix++;
		}
		var oldCount = a.length - suffix - prefix, newCount = b.length - suffix - prefix;
		if (oldCount == 0 || newCount == 0 || oldCount > MAX_CHANGED_LINES || newCount > MAX_CHANGED_LINES)
			return result;
		// The lines left as they were, as pairs of indices into the changed middle, then the edited lines between them.
		var anchors = commonLines(a, prefix, oldCount, b, prefix, newCount);
		var oldFrom = 0, newFrom = 0;
		anchors.push({old: oldCount, now: newCount});
		for (anchor in anchors) {
			pairSimilar(a, prefix + oldFrom, anchor.old - oldFrom, b, prefix + newFrom, anchor.now - newFrom, result);
			if (anchor.old < oldCount)
				result.set(prefix + anchor.old + 1, prefix + anchor.now + 1);
			oldFrom = anchor.old + 1;
			newFrom = anchor.now + 1;
		}
		return result;
	}

	static function lines(text:String):Array<String>
		return [for (line in text.split("\n")) StringTools.endsWith(line, "\r") ? line.substr(0, line.length - 1) : line];

	/** The longest common subsequence of the lines `a[aFrom...aFrom+aCount]` and `b[bFrom...bFrom+bCount]`, as index pairs. */
	static function commonLines(a:Array<String>, aFrom:Int, aCount:Int, b:Array<String>, bFrom:Int, bCount:Int):Array<{old:Int, now:Int}> {
		var width = bCount + 1, table:Array<Int> = [for (_ in 0...(aCount + 1) * width) 0];
		var i = aCount - 1;
		while (i >= 0) {
			var j = bCount - 1;
			while (j >= 0) {
				table[i * width + j] = a[aFrom + i] == b[bFrom + j] ? table[(i + 1) * width + j + 1] + 1 : max(table[(i + 1) * width + j],
					table[i * width + j + 1]);
				j--;
			}
			i--;
		}
		var pairs:Array<{old:Int, now:Int}> = [], x = 0, y = 0;
		while (x < aCount && y < bCount) {
			if (a[aFrom + x] == b[bFrom + y]) {
				pairs.push({old: x, now: y});
				x++;
				y++;
			} else if (table[(x + 1) * width + y] >= table[x * width + y + 1])
				x++;
			else
				y++;
		}
		return pairs;
	}

	/** Pairs, in order, the old and new lines of one changed stretch that read most alike, to maximize the total likeness. */
	static function pairSimilar(a:Array<String>, aFrom:Int, aCount:Int, b:Array<String>, bFrom:Int, bCount:Int, result:Map<Int, Int>):Void {
		if (aCount <= 0 || bCount <= 0 || aCount > MAX_GAP_LINES || bCount > MAX_GAP_LINES)
			return;
		var width = bCount + 1, best:Array<Float> = [for (_ in 0...(aCount + 1) * width) 0.0], likeness:Array<Float> = [for (_ in 0...aCount * bCount) 0.0];
		for (i in 0...aCount)
			for (j in 0...bCount)
				likeness[i * bCount + j] = similarity(a[aFrom + i], b[bFrom + j]);
		var i = aCount - 1;
		while (i >= 0) {
			var j = bCount - 1;
			while (j >= 0) {
				var skip = Math.max(best[(i + 1) * width + j], best[i * width + j + 1]), alike = likeness[i * bCount + j];
				best[i * width + j] = alike >= SIMILAR ? Math.max(skip, best[(i + 1) * width + j + 1] + alike) : skip;
				j--;
			}
			i--;
		}
		var x = 0, y = 0;
		while (x < aCount && y < bCount) {
			var alike = likeness[x * bCount + y];
			if (alike >= SIMILAR && best[x * width + y] == best[(x + 1) * width + y + 1] + alike) {
				result.set(aFrom + x + 1, bFrom + y + 1);
				x++;
				y++;
			} else if (best[(x + 1) * width + y] >= best[x * width + y + 1])
				x++;
			else
				y++;
		}
	}

	/** Twice the characters two lines have in common, in order, over their total length, leading and trailing spaces aside. */
	public static function similarity(left:String, right:String):Float {
		var a = StringTools.trim(left), b = StringTools.trim(right);
		if (a == b)
			return 1.0;
		if (a.length == 0 || b.length == 0 || a.length > MAX_LINE_LENGTH || b.length > MAX_LINE_LENGTH)
			return 0.0;
		var previous:Array<Int> = [for (_ in 0...b.length + 1) 0], current:Array<Int> = [for (_ in 0...b.length + 1) 0];
		for (i in 0...a.length) {
			current[0] = 0;
			for (j in 0...b.length)
				current[j + 1] = a.charCodeAt(i) == b.charCodeAt(j) ? previous[j] + 1 : max(previous[j + 1], current[j]);
			var swap = previous;
			previous = current;
			current = swap;
		}
		return 2.0 * previous[b.length] / (a.length + b.length);
	}

	static inline function max(a:Int, b:Int):Int
		return a > b ? a : b;
}

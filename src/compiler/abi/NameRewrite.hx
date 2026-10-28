package compiler.abi;

import compiler.semantic.LambdaName;

/**
 * One simultaneous renaming of lambdas (`LambdaName`): each key becomes its value. A lambda's name is part of the names of
 * everything made for it, so a rename moves them too: the lambdas written in it (`$lambda:<lambda>:...`), their environments
 * (`$lambda-env:<lambda>:...`), the cells of the variables it captures (`$cell:<lambda>:...`), its own environment
 * (`$lambda-env:<enclosing>:<identity>`), and these names wherever they appear in type keys or ABI descriptions.
 */
class NameRewrite {
	/** The renames the rewrite was made from, by full lambda name. */
	public final lambdas:Map<String, String>;

	final pairs:Array<{from:String, to:String}> = [];

	static inline final LAMBDA:String = LambdaName.PREFIX;
	static inline final ENVIRONMENT:String = LambdaName.ENVIRONMENT_PREFIX;

	public function new(lambdas:Map<String, String>) {
		this.lambdas = lambdas;
		for (from => to in lambdas) {
			if (!LambdaName.is(from) || !LambdaName.is(to))
				throw 'Only lambdas are renamed: $from -> $to';
			pairs.push({from: from, to: to});
			pairs.push({from: ENVIRONMENT + from.substr(LAMBDA.length), to: ENVIRONMENT + to.substr(LAMBDA.length)});
		}
		// The longest first, so a name never matches where a longer one it is a prefix of does.
		pairs.sort((a, b) -> b.from.length - a.from.length);
	}

	public function isEmpty():Bool
		return pairs.length == 0;

	/**
	 * `text` with every renamed name in it replaced. A name counts only as a whole: what comes before it must start a name (the
	 * start, or one of `:(,< =`) and what follows must end one (the end, or one of `:),> ;`), so `g#1` never matches in `g#10`.
	 */
	public function apply(text:String):String {
		if (pairs.length == 0 || text.indexOf("$lambda") < 0)
			return text;
		var result = new StringBuf(), index = 0, copied = 0;
		while (index < text.length) {
			var found = text.indexOf("$lambda", index);
			if (found < 0)
				break;
			var replaced = false;
			if (found == 0 || startsName(text.charCodeAt(found - 1)))
				for (pair in pairs) {
					var end = found + pair.from.length;
					if (end <= text.length && text.substr(found, pair.from.length) == pair.from
						&& (end == text.length || endsName(text.charCodeAt(end)))) {
						result.add(text.substring(copied, found));
						result.add(pair.to);
						copied = index = end;
						replaced = true;
						break;
					}
				}
			if (!replaced)
				index = found + 1;
		}
		if (copied == 0)
			return text;
		result.add(text.substring(copied));
		return result.toString();
	}

	static function startsName(code:Null<Int>):Bool
		return code == ":".code || code == "(".code || code == ",".code || code == "<".code || code == " ".code || code == "=".code;

	static function endsName(code:Null<Int>):Bool
		return code == ":".code || code == ")".code || code == ",".code || code == ">".code || code == " ".code || code == ";".code;

	/**
	 * `map` with its keys rewritten. Two keys that come out the same would silently lose one entry, so that throws: a rewrite
	 * that renames a name onto one the map still holds is a bug in whoever made it (see `LambdaAlignment.align`, which moves
	 * every name a rename lands on out of the way first).
	 */
	public function keys<T>(map:Map<String, T>):Map<String, T> {
		var result:Map<String, T> = [], sources:Map<String, String> = [];
		for (key => value in map) {
			var renamed = apply(key);
			var earlier = sources.get(renamed);
			if (earlier != null)
				throw 'Renaming lambdas gives $earlier and $key the same name $renamed';
			sources.set(renamed, key);
			result.set(renamed, value);
		}
		return result;
	}

	/** `map` with its keys and values rewritten; keys that come out the same throw, as in `keys`. */
	public function entries(map:Map<String, String>):Map<String, String> {
		var result:Map<String, String> = [];
		for (key => value in keys(map))
			result.set(key, apply(value));
		return result;
	}
}

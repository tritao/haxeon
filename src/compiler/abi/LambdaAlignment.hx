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

	/** `map` with its keys rewritten. */
	public function keys(map:Map<String, String>):Map<String, String> {
		var result:Map<String, String> = [];
		for (key => value in map)
			result.set(apply(key), value);
		return result;
	}

	/** `map` with its keys rewritten. */
	public function indexKeys(map:Map<String, Int>):Map<String, Int> {
		var result:Map<String, Int> = [];
		for (key => value in map)
			result.set(apply(key), value);
		return result;
	}

	/** `map` with its keys and values rewritten. */
	public function entries(map:Map<String, String>):Map<String, String> {
		var result:Map<String, String> = [];
		for (key => value in map)
			result.set(apply(key), apply(value));
		return result;
	}
}

/** How the lambdas of one build stand for the lambdas of the build the running module has. */
typedef LambdaAlignmentResult = {
	/**
	 * Renames that give each lambda of the running module the name its function has in the new build, applied in order.
	 * A running lambda the new build no longer has, whose name a different function takes, is renamed out of the way
	 * (`LambdaAlignment.retiredName`): it keeps its slot and code for the closures that hold it.
	 */
	final steps:Array<NameRewrite>;

	/** The group each step renames, in step order. */
	final renamed:Array<String>;

	/** Groups whose functions cannot be shown to be the same functions as before. */
	final refused:Array<String>;
}

/**
 * Matches positionally named lambdas (`PositionalName`) across an edit by what they do, not by their ordinal. A lambda is
 * named by its position among the lambdas written at the same place, so inserting, deleting or reordering siblings shifts
 * names onto other functions. A patch puts new code under each name, and closures the running program already made call
 * the code under their name: a shifted name would make a stored callback silently run another function's code.
 *
 * So within each group of siblings the lambdas are matched by their code fingerprint (`IrFunctionStateCodec.codeFingerprint`,
 * which leaves out lambda ordinals, so a lambda that only moved keeps its fingerprint):
 *
 * - Siblings with the same fingerprint are matched in order. Their code is the same, so which of them takes which slot cannot
 *   be observed.
 * - A new sibling nothing matches is added; a running one nothing matches is removed and keeps its slot and code.
 * - Between two matched siblings, one unmatched running sibling and one unmatched new sibling are the same function edited,
 *   provided neither's code appears elsewhere in its group (else nothing tells an edit from a copy inserted beside a
 *   deletion). Any other combination of unmatched siblings on both sides of the same gap is refused, as is one when the
 *   matches are reordered and siblings were also edited.
 *
 * The result renames the running module's names to the new build's. Function adapters (`$function-adapter:`) are not
 * renamed; their groups patch only while every name keeps its function (`PatchPlanner.sameFunctions`).
 */
class LambdaAlignment {
	static inline final RETIRED:String = "~retired";

	public static function align(previous:Null<Map<String, String>>, next:Null<Map<String, String>>, tag:String):LambdaAlignmentResult {
		var steps:Array<NameRewrite> = [], renamed:Array<String> = [], refused:Array<String> = [], after = groups(next);
		var names = [for (group in after.keys()) group];
		// A group nested in a lambda has that lambda's name in its own, so it comes after it and sees it renamed.
		names.sort((a, b) -> a.length != b.length ? a.length - b.length : Reflect.compare(a, b));
		if (previous == null)
			return {steps: steps, renamed: renamed, refused: names};
		var current = [for (name => print in previous) name => print], before = groups(current);
		for (group in names) {
			var old = before.get(group), now = after.get(group);
			if (old == null)
				continue;
			if (!LambdaName.is(group)) {
				if (!PatchPlanner.sameFunctions(old, now))
					refused.push(group);
				continue;
			}
			var aligned = alignGroup(old, now);
			if (aligned == null) {
				refused.push(group);
				continue;
			}
			var renames:Map<String, String> = [], sources:Map<String, Bool> = [];
			for (from => to in aligned.mapping)
				if (from != to) {
					renames.set(member(group, from), member(group, to));
					sources.set(member(group, from), true);
				}
			for (ordinal in aligned.retired) {
				renames.set(member(group, ordinal), retiredName(group, ordinal, tag));
				sources.set(member(group, ordinal), true);
			}
			// A name a rename moves onto may still be held by a function the running module no longer uses (removed by an
			// earlier edit); move it out of the way with its environments and nested lambdas.
			for (to in [for (_ => to in renames) to])
				if (!sources.exists(to) && to.indexOf(RETIRED) < 0)
					renames.set(to, retiredName(group, PositionalName.ordinal(to), tag));
			var count = 0;
			for (_ in renames.keys())
				count++;
			if (count == 0)
				continue;
			var step = new NameRewrite(renames);
			steps.push(step);
			renamed.push(group);
			current = step.keys(current);
			before = groups(current);
		}
		refused.sort(Reflect.compare);
		return {steps: steps, renamed: renamed, refused: refused};
	}

	/** `abi` with the running module's names renamed as `steps` say. */
	public static function renameAbi(abi:RuntimeAbi.RuntimeAbiDescriptor, steps:Array<NameRewrite>):RuntimeAbi.RuntimeAbiDescriptor {
		var functions = abi.functions, objects = abi.objects, positional = abi.positional;
		for (step in steps) {
			functions = step.entries(functions);
			objects = step.entries(objects);
			if (positional != null)
				positional = step.keys(positional);
		}
		return {
			functions: functions,
			objects: objects,
			interfaces: abi.interfaces,
			enums: abi.enums,
			globals: abi.globals,
			positional: positional
		};
	}

	/**
	 * The name a running lambda takes when the new build gives its name to another function: in a group of its own, which no
	 * build has, so nothing is ever compared with it or patched into it. `tag` keeps the names of different builds apart.
	 */
	public static function retiredName(group:String, ordinal:Int, tag:String):String
		return group + RETIRED + tag + "#" + ordinal;

	/** The name a function whose signature changed leaves behind in the slot it had (see `HlModuleAssembler`). */
	public static function retiredFunctionName(name:String, tag:String):String
		return name + RETIRED + tag;

	public static function isRetired(name:String):Bool
		return name.indexOf(RETIRED) >= 0;

	static function member(group:String, ordinal:Int):String
		return group + "#" + ordinal;

	static function groups(fingerprints:Null<Map<String, String>>):Map<String, Array<Null<String>>> {
		var result:Map<String, Array<Null<String>>> = [];
		if (fingerprints == null)
			return result;
		for (name => fingerprint in fingerprints) {
			if (!PositionalName.is(name))
				continue;
			var group = PositionalName.group(name),
				members = result.get(group);
			if (members == null) {
				members = [];
				result.set(group, members);
			}
			members[PositionalName.ordinal(name)] = fingerprint;
		}
		return result;
	}

	/**
	 * The running ordinal each new ordinal stands for (`mapping`, from running to new), and the running ordinals whose names
	 * the new build gives to another function (`retired`); null when the group cannot be matched.
	 */
	public static function alignGroup(before:Array<Null<String>>, after:Array<Null<String>>):Null<{mapping:Map<Int, Int>, retired:Array<Int>}> {
		var waiting:Map<String, Array<Int>> = [], mapping:Map<Int, Int> = [], matchedNew:Map<Int, Bool> = [];
		for (ordinal in 0...before.length) {
			var print = before[ordinal];
			if (print == null)
				continue;
			var list = waiting.get(print);
			if (list == null) {
				list = [];
				waiting.set(print, list);
			}
			list.push(ordinal);
		}
		for (ordinal in 0...after.length) {
			var print = after[ordinal];
			if (print == null)
				continue;
			var list = waiting.get(print);
			if (list != null && list.length > 0) {
				var from:Int = list.shift();
				mapping.set(from, ordinal);
				matchedNew.set(ordinal, true);
			}
		}
		var unmatchedOld = [for (ordinal in 0...before.length) if (before[ordinal] != null && !mapping.exists(ordinal)) ordinal],
			unmatchedNew = [for (ordinal in 0...after.length) if (after[ordinal] != null && !matchedNew.exists(ordinal)) ordinal];
		if (unmatchedOld.length > 0 && unmatchedNew.length > 0) {
			// Unmatched siblings on both sides may be edits. Pair them only between the same matched neighbours.
			var pairs = [for (from => to in mapping) {from: from, to: to}];
			pairs.sort((a, b) -> a.from - b.from);
			for (index in 1...pairs.length)
				if (pairs[index].to < pairs[index - 1].to)
					return null;
			function gap(ordinal:Int, old:Bool):Int {
				var count = 0;
				for (pair in pairs)
					if ((old ? pair.from : pair.to) < ordinal)
						count++;
				return count;
			}
			var gaps:Map<Int, {olds:Array<Int>, news:Array<Int>}> = [];
			function at(index:Int):{olds:Array<Int>, news:Array<Int>} {
				var entry = gaps.get(index);
				if (entry == null) {
					entry = {olds: [], news: []};
					gaps.set(index, entry);
				}
				return entry;
			}
			for (ordinal in unmatchedOld)
				at(gap(ordinal, true)).olds.push(ordinal);
			for (ordinal in unmatchedNew)
				at(gap(ordinal, false)).news.push(ordinal);
			for (entry in gaps) {
				if (entry.olds.length == 0 || entry.news.length == 0)
					continue;
				if (entry.olds.length != 1 || entry.news.length != 1)
					return null;
				var from = entry.olds[0], to = entry.news[0];
				if (occurrences(before, before[from]) != 1 || occurrences(after, after[to]) != 1)
					return null;
				mapping.set(from, to);
			}
		}
		// A running sibling nothing stands for keeps its name, unless the new build gives that name to another function.
		var retired = [
			for (ordinal in 0...before.length)
				if (before[ordinal] != null && !mapping.exists(ordinal) && ordinal < after.length && after[ordinal] != null) ordinal
		];
		return {mapping: mapping, retired: retired};
	}

	static function occurrences(sources:Array<Null<String>>, source:Null<String>):Int {
		var count = 0;
		for (candidate in sources)
			if (candidate == source)
				count++;
		return count;
	}
}

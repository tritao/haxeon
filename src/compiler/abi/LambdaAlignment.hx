package compiler.abi;

import compiler.semantic.LambdaName;

/** How the lambdas of one build stand for the lambdas of the build the running module has. */
typedef LambdaAlignmentResult = {
	/**
	 * Renames that give each lambda of the running module the name its function has in the new build, applied in order.
	 * A running lambda the new build no longer has, whose name a different function takes, is renamed out of the way
	 * (`RetiredName.lambda`): it keeps its slot and code for the closures that hold it.
	 */
	final steps:Array<NameRewrite>;

	/** The group each step renames, in step order. */
	final renamed:Array<String>;

	/** Groups whose functions cannot be shown to be the same functions as before. */
	final refused:Array<String>;
}

/**
 * Where the lambdas of both builds start in their sources, and the texts of those sources (`RuntimeAbiDescriptor.places`):
 * what lets `LambdaAlignment` follow an edited lambda through the edit's text diff.
 */
typedef LambdaPlaces = {
	final before:Map<String, String>;
	final after:Map<String, String>;
	final beforeSources:Map<String, String>;
	final afterSources:Map<String, String>;
}

/** How one group's running siblings stand for its new ones (`LambdaAlignment.alignGroup`). */
typedef GroupAlignment = {
	/** The new ordinal each matched running ordinal stands for. */
	final mapping:Map<Int, Int>;

	/** Running ordinals nothing stands for whose names the new build gives to another function. */
	final retired:Array<Int>;
}

/**
 * Matches positionally named lambdas (`PositionalName`) across an edit by what they do, not by their ordinal. A lambda is
 * named by its position among the lambdas written at the same place, so inserting, deleting or reordering siblings shifts
 * names onto other functions. A patch puts new code under each name, and closures the running program already made call
 * the code under their name: a shifted name would make a stored callback silently run another function's code.
 *
 * So within each group of siblings the lambdas are matched by their code fingerprint (`IrFunctionStateCodec.codeFingerprint`,
 * which leaves out lambda ordinals, so a lambda that only moved keeps its fingerprint), folded with the fingerprints of the
 * lambdas written in it all the way down (`PositionalName.nested`):
 *
 * - Siblings with the same fingerprint are matched in order. They and every lambda written in them run the same code, so
 *   which of them takes which slot cannot be observed.
 * - An edited sibling is followed through the saved file's text diff (`followEdit`, `SourceLineMap`), when both builds
 *   recorded where their lambdas start; a pair is taken only when neither's code appears elsewhere in its group.
 * - A new sibling nothing matches is added; a running one nothing matches is removed and keeps its slot and code, and the
 *   patch applies only when no stored closure reaches it (`HlModuleAssembler.dropGuards`).
 * - Between two matched siblings, one unmatched running sibling and one unmatched new sibling are the same function edited,
 *   provided neither's code appears elsewhere in its group (else nothing tells an edit from a copy inserted beside a
 *   deletion). Any other combination of unmatched siblings on both sides of the same gap is refused, as is one when the
 *   matches are reordered and siblings were also edited.
 *
 * The result renames the running module's names to the new build's. Function adapters (`$function-adapter:`) are not
 * renamed; their groups patch only while every name keeps its function (`keepsNames`).
 */
class LambdaAlignment {
	/**
	 * The tag `PatchPlanner` aligns with. The planner reads only which groups are renamed or refused; the names it would retire
	 * lambdas to are never used, so they need no build to tell them apart.
	 */
	public static inline final PLANNING:String = "";

	/**
	 * How to rename the running module's lambdas (`previous` fingerprints, by name) so that each stands for its function in
	 * the new build (`next`). `tag` goes into the names of lambdas retired by this build (`RetiredName.lambda`).
	 */
	public static function align(previous:Null<Map<String, String>>, next:Null<Map<String, String>>, tag:String,
			?places:LambdaPlaces):LambdaAlignmentResult {
		var steps:Array<NameRewrite> = [], renamed:Array<String> = [], refused:Array<String> = [], after = groups(next);
		var names = [for (group in after.keys()) group];
		// A group nested in a lambda has that lambda's name in its own, so it comes after it and sees it renamed.
		names.sort((a, b) -> a.length != b.length ? a.length - b.length : Reflect.compare(a, b));
		if (previous == null)
			return {steps: steps, renamed: renamed, refused: names};
		var current = [for (name => print in previous) name => print], before = groups(current);
		var beforePlaces = places == null ? null : [for (name => place in places.before) name => place], lineMaps:Map<String, Map<Int, Int>> = [];
		for (group in names) {
			var old = before.get(group), now = after.get(group);
			if (old == null)
				continue;
			if (!LambdaName.is(group)) {
				if (!keepsNames(old, now))
					refused.push(group);
				continue;
			}
			var known = beforePlaces, given = places;
			var aligned = alignGroup(old, now, known == null || given == null ? null : (ordinal:Int) -> followEdit(group, known, given, lineMaps, ordinal));
			if (aligned == null) {
				refused.push(group);
				continue;
			}
			var renames = groupRenames(group, aligned, tag);
			if (!renames.keys().hasNext())
				continue;
			var step = new NameRewrite(renames);
			steps.push(step);
			renamed.push(group);
			current = step.keys(current);
			before = groups(current);
			if (beforePlaces != null)
				beforePlaces = step.keys(beforePlaces);
		}
		refused.sort(Reflect.compare);
		return {steps: steps, renamed: renamed, refused: refused};
	}

	/**
	 * The new ordinal of `group` the running lambda at `ordinal` became, by the edit's text diff (`SourceLineMap`): the line its
	 * code started on, carried through the diff, is the line the new lambda starts on, and among the group's lambdas that
	 * start on one line they keep their order. Null when the diff does not carry the line over or no lambda starts there.
	 */
	static function followEdit(group:String, beforePlaces:Map<String, String>, places:LambdaPlaces, lineMaps:Map<String, Map<Int, Int>>,
			ordinal:Int):Null<Int> {
		var from = PositionalName.parsePlace(beforePlaces.get(member(group, ordinal)));
		if (from == null)
			return null;
		var lines = lineMaps.get(from.path);
		if (lines == null) {
			var oldText = places.beforeSources.get(from.path), newText = places.afterSources.get(from.path);
			lines = oldText == null || newText == null ? [] : SourceLineMap.map(oldText, newText);
			lineMaps.set(from.path, lines);
		}
		var line = lines.get(from.line);
		if (line == null)
			return null;
		// Its rank among the group's lambdas starting on its old line picks it out among those on the new line.
		var rank = 0;
		for (name => text in beforePlaces) {
			var other = PositionalName.parsePlace(text);
			if (other != null && PositionalName.is(name) && PositionalName.group(name) == group && other.path == from.path && other.line == from.line
				&& other.offset < from.offset)
				rank++;
		}
		var candidates:Array<{ordinal:Int, offset:Int}> = [];
		for (name => text in places.after) {
			var other = PositionalName.parsePlace(text);
			if (other != null && PositionalName.is(name) && PositionalName.group(name) == group && other.path == from.path && other.line == line)
				candidates.push({ordinal: PositionalName.ordinal(name), offset: other.offset});
		}
		candidates.sort((a, b) -> a.offset - b.offset);
		return rank < candidates.length ? candidates[rank].ordinal : null;
	}

	/** The places of the lambdas of `previous` and `next`, when both builds recorded them. */
	public static function placesOf(previous:RuntimeAbi.RuntimeAbiDescriptor, next:RuntimeAbi.RuntimeAbiDescriptor):Null<LambdaPlaces> {
		var before = previous.places, after = next.places, beforeSources = previous.sources, afterSources = next.sources;
		return before == null || after == null || beforeSources == null || afterSources == null ? null : {
			before: before,
			after: after,
			beforeSources: beforeSources,
			afterSources: afterSources
		};
	}

	/** The renames that carry out `aligned` for `group`, by full lambda name. */
	static function groupRenames(group:String, aligned:GroupAlignment, tag:String):Map<String, String> {
		var renames:Map<String, String> = [], sources:Map<String, Bool> = [];
		for (from => to in aligned.mapping)
			if (from != to) {
				renames.set(member(group, from), member(group, to));
				sources.set(member(group, from), true);
			}
		for (ordinal in aligned.retired) {
			renames.set(member(group, ordinal), RetiredName.lambda(group, ordinal, tag));
			sources.set(member(group, ordinal), true);
		}
		// A name a rename moves onto may still be held by a function the running module no longer uses (removed by an earlier
		// edit); move it out of the way with its environments and nested lambdas.
		for (to in [for (_ => to in renames) to])
			if (!sources.exists(to) && !RetiredName.is(to))
				renames.set(to, RetiredName.lambda(group, PositionalName.ordinal(to), tag));
		return renames;
	}

	/** `abi` with the running module's names renamed as `steps` say. */
	public static function renameAbi(abi:RuntimeAbi.RuntimeAbiDescriptor, steps:Array<NameRewrite>):RuntimeAbi.RuntimeAbiDescriptor {
		var functions = abi.functions, objects = abi.objects, positional = abi.positional, places = abi.places;
		for (step in steps) {
			functions = step.entries(functions);
			objects = step.entries(objects);
			if (positional != null)
				positional = step.keys(positional);
			if (places != null)
				places = step.keys(places);
		}
		return {
			functions: functions,
			objects: objects,
			interfaces: abi.interfaces,
			enums: abi.enums,
			globals: abi.globals,
			positional: positional,
			places: places,
			sources: abi.sources
		};
	}

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
	public static function alignGroup(before:Array<Null<String>>, after:Array<Null<String>>, ?followEdit:Int->Null<Int>):Null<GroupAlignment> {
		var mapping = matchSameCode(before, after);
		var matchedNew:Map<Int, Bool> = [for (_ => to in mapping) to => true];
		var unmatchedOld = [for (ordinal in 0...before.length) if (before[ordinal] != null && !mapping.exists(ordinal)) ordinal],
			unmatchedNew = [for (ordinal in 0...after.length) if (after[ordinal] != null && !matchedNew.exists(ordinal)) ordinal];
		// The edit's text diff tells which edited lambda each running one became. The fingerprints keep it honest: a pair is
		// taken only when neither's code appears elsewhere in its group, where a copy could be taken for an edit.
		if (followEdit != null && unmatchedOld.length > 0 && unmatchedNew.length > 0) {
			var open:Map<Int, Bool> = [for (ordinal in unmatchedNew) ordinal => true];
			for (from in unmatchedOld) {
				var to = followEdit(from);
				if (to != null && open.exists(to) && occurrences(before, before[from]) == 1 && occurrences(after, after[to]) == 1) {
					mapping.set(from, to);
					open.remove(to);
				}
			}
			unmatchedOld = [for (ordinal in unmatchedOld) if (!mapping.exists(ordinal)) ordinal];
			unmatchedNew = [for (ordinal in unmatchedNew) if (open.exists(ordinal)) ordinal];
		}
		if (unmatchedOld.length > 0 && unmatchedNew.length > 0 && !pairEdits(before, after, mapping, unmatchedOld, unmatchedNew))
			return null;
		// A running sibling nothing stands for keeps its name, unless the new build gives that name to another function.
		var retired = [
			for (ordinal in 0...before.length)
				if (before[ordinal] != null && !mapping.exists(ordinal) && ordinal < after.length && after[ordinal] != null) ordinal
		];
		return {mapping: mapping, retired: retired};
	}

	/** Siblings with the same fingerprint, matched in order: running ordinal to new ordinal. */
	static function matchSameCode(before:Array<Null<String>>, after:Array<Null<String>>):Map<Int, Int> {
		var waiting:Map<String, Array<Int>> = [], mapping:Map<Int, Int> = [];
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
			}
		}
		return mapping;
	}

	/**
	 * Pairs the unmatched siblings on both sides as edits, adding them to `mapping`: only one running and one new sibling between
	 * the same matched neighbours, neither of whose code appears elsewhere in its group. False when they cannot be told apart.
	 */
	static function pairEdits(before:Array<Null<String>>, after:Array<Null<String>>, mapping:Map<Int, Int>, unmatchedOld:Array<Int>,
			unmatchedNew:Array<Int>):Bool {
		var pairs = [for (from => to in mapping) {from: from, to: to}];
		pairs.sort((a, b) -> a.from - b.from);
		for (index in 1...pairs.length)
			if (pairs[index].to < pairs[index - 1].to)
				return false;
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
				return false;
			var from = entry.olds[0], to = entry.news[0];
			if (occurrences(before, before[from]) != 1 || occurrences(after, after[to]) != 1)
				return false;
			mapping.set(from, to);
		}
		return true;
	}

	/**
	 * Whether a group that is never renamed (function adapters) provably keeps its names, by its code fingerprints:
	 *
	 * - None changed, or functions were only added or removed after the last one that is kept: every kept name runs its old code.
	 * - Exactly one changed, the count is the same, and neither its old nor its new code appears elsewhere in the group: that is
	 *   an edit of that function. (A sibling inserted above and a later one deleted changes every name in between, unless those
	 *   siblings have identical code, which the uniqueness check rules out.)
	 */
	public static function keepsNames(previous:Array<Null<String>>, next:Array<Null<String>>):Bool {
		var changed:Array<Int> = [];
		for (ordinal in 0...(previous.length < next.length ? previous.length : next.length))
			if (previous[ordinal] == null || previous[ordinal] != next[ordinal])
				changed.push(ordinal);
		if (changed.length == 0)
			return true;
		if (changed.length > 1 || previous.length != next.length)
			return false;
		var ordinal = changed[0];
		return occurrences(previous, previous[ordinal]) == 1 && occurrences(next, next[ordinal]) == 1;
	}

	static function occurrences(sources:Array<Null<String>>, source:Null<String>):Int {
		var count = 0;
		for (candidate in sources)
			if (candidate == source)
				count++;
		return count;
	}
}

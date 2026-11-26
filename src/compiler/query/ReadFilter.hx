package compiler.query;

import compiler.query.QueryKind.QueryRead;

/**
 * Which results may have read a key, by group: a stage that keeps results with their reads (`QueryRead`) finds those that read
 * one of a few changed keys without walking every result's reads. Each group (a module, say) has a Bloom filter of the reads its
 * members recorded, and the list of its members; a group whose filter may hold a changed key has its members checked exactly.
 *
 * A filter only grows: a member's reads are added when it is written and stay after it reads otherwise or is gone, so it answers
 * for every result written since it was built, a result a rollback restores among them. A false yes costs an exact check of the
 * group's members. The owner builds the filters again (`rebuild`) once more reads were added than they were built for (`full`).
 */
class ReadFilter {
	// Each group's bits in `bits`, from `starts[group]`, `sizes[group]` of them; a group past `starts` has none yet and may hold
	// any key.
	var bits:Array<Int> = [];
	var starts:Array<Int> = [];
	var sizes:Array<Int> = [];
	var members:Array<Array<Int>> = [];
	var added = 0;
	var built = 0;

	static inline final BITS_PER_KEY = 10;

	public function new() {}

	/** Whether the filters took more reads since the last `rebuild` than they were built with, so they answer yes too often. */
	public var full(get, never):Bool;

	inline function get_full():Bool
		return added > built * 2 + 1024;

	/** How many groups have members. */
	public var groups(get, never):Int;

	inline function get_groups():Int
		return members.length;

	/** The members of `group`, each at least once. */
	public inline function membersOf(group:Int):Array<Int>
		return group < members.length ? members[group] : [];

	/** Lists `member` in `group` when `listed` is false, and adds what it read to the group's filter. */
	public function add(group:Int, member:Int, reads:Array<Int>, listed:Bool):Void {
		while (members.length <= group)
			members.push([]);
		if (!listed)
			members[group].push(member);
		added += reads.length;
		if (group >= starts.length)
			return;
		var start = starts[group], size = sizes[group];
		for (read in reads)
			for (probe in 0...PROBES)
				setBit(start + position(read, probe, size));
	}

	/** Whether some member of `group` may have read `read`. */
	public function mayRead(group:Int, read:Int):Bool {
		if (group >= starts.length)
			return true;
		var start = starts[group], size = sizes[group];
		for (probe in 0...PROBES)
			if (!getBit(start + position(read, probe, size)))
				return false;
		return true;
	}

	/**
	 * Builds the filters again from every result, which `each` gives as a group, a member and its reads (a member may come more than
	 * once, with each result that is its own or that a rollback can restore; a negative member only keeps its group). `limit` is
	 * above every read and every member.
	 */
	public function rebuild(limit:Int, each:(visit:(group:Int, member:Int, reads:Array<Int>) -> Void) -> Void):Void {
		// Each key is marked with the last group that listed it as a member (negative) and that read it (positive).
		var byGroup:Array<Array<Array<Int>>> = [], listed:Array<Array<Int>> = [], marks:Array<Int> = [];
		QueryRead.extend(marks, limit);
		each((group, member, reads) -> {
			while (byGroup.length <= group) {
				byGroup.push([]);
				listed.push([]);
			}
			byGroup[group].push(reads);
			if (member >= 0 && marks[member] != -group - 1) {
				marks[member] = -group - 1;
				listed[group].push(member);
			}
		});
		// A group's filter is sized by the keys its members read, each counted once.
		starts = [];
		sizes = [];
		var total = 0;
		for (group in 0...byGroup.length) {
			var distinct = 0;
			for (reads in byGroup[group])
				for (read in reads)
					if (read < limit && marks[read] != group + 1) {
						marks[read] = group + 1;
						distinct++;
					}
			starts.push(total);
			var size = distinct * BITS_PER_KEY + 32;
			sizes.push(size);
			total += size;
		}
		bits = [];
		QueryRead.extend(bits, (total >> 5) + 1);
		members = listed;
		added = 0;
		for (group in 0...byGroup.length) {
			var start = starts[group], size = sizes[group];
			for (reads in byGroup[group]) {
				added += reads.length;
				for (read in reads)
					for (probe in 0...PROBES)
						setBit(start + position(read, probe, size));
			}
		}
		built = added;
	}

	/** Forgets every group. */
	public function clear():Void {
		bits = [];
		starts = [];
		sizes = [];
		members = [];
		added = 0;
		built = 0;
	}

	static inline final PROBES = 3;

	/** The `probe`-th bit of `read` in a filter of `size` bits. */
	static inline function position(read:Int, probe:Int, size:Int):Int {
		var hash = (read + probe * (cast 0x9E3779B9:Int)) * (cast 0x85EBCA6B:Int);
		hash ^= hash >>> 13;
		hash *= (cast 0xC2B2AE35:Int);
		hash ^= hash >>> 16;
		return (hash >>> 1) % size;
	}

	inline function setBit(index:Int):Void
		bits[index >> 5] = bits[index >> 5] | (1 << (index & 31));

	inline function getBit(index:Int):Bool
		return bits[index >> 5] & (1 << (index & 31)) != 0;
}

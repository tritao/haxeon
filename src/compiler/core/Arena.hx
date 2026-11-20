package compiler.core;

/**
 * An arena: what a thread allocates while the arena is current goes to pages of its own, released in bulk when the work
 * that used it ends (docs/design/ARENAS.md). A release is checked: when nothing outside points into the arena its pages are
 * reused at once and what it allocated no longer counts toward the next collection; otherwise they are left to the
 * collector, which frees them as their blocks die. Correctness never depends on an arena, only memory does.
 *
 * Built with Haxeon for HashLink, the fork's runtime does the work; built with stock Haxe, or for another target, an arena
 * does nothing and `within` just calls its function.
 */
class Arena {
	/** The collector's own pages: work run within it allocates outside every arena. */
	public static final global:Arena = new Arena(true);

	/** Arenas released without a collection, arenas left to the collector, references that kept them, release time. */
	@:processWide("a process-wide count, like the collector's own; a compile reads the difference")
	public static var released(default, null) = 0;

	@:processWide("a process-wide count, like the collector's own; a compile reads the difference")
	public static var kept(default, null) = 0;
	@:processWide("a process-wide count, like the collector's own; a compile reads the difference")
	public static var references(default, null) = 0;
	@:processWide("a process-wide count, like the collector's own; a compile reads the difference")
	public static var releaseSeconds(default, null) = 0.0;

	/**
	 * Whether a release may evacuate: when only heap words and roots point into an arena, what they reach there is copied
	 * out to their owners and the arena is released anyway (the fork's evacuating release). For work whose leftovers are not
	 * all placed outside yet; a stack reference still keeps the arena.
	 */
	public static function evacuate(on:Bool):Void {
		#if (haxeon && hl)
		setEvacuation(on);
		#end
	}

	/** The arenas an evacuating release has released, and the bytes it copied out of them. */
	public static function evacuated():Float {
		#if (haxeon && hl)
		return evacuatedArenas();
		#else
		return 0;
		#end
	}

	public static function evacuatedBytes():Float {
		#if (haxeon && hl)
		return evacuatedCopied();
		#else
		return 0;
		#end
	}

	/** How many unit arenas are open on this thread: none, and no value can be inside one. */
	@:processWide("the units open on the running thread: zero between them, whichever compile runs")
	public static var depth(default, null) = 0;

	final isGlobal:Bool;

	public function new(?isGlobal = false)
		this.isGlobal = isGlobal;

	/** Runs `work` with `arena` current on this thread, and the arena current before current again afterwards. */
	public static function within<T>(arena:Arena, work:() -> T):T {
		#if (haxeon && hl)
		var previous = enter(arena.isGlobal ? null : arena);
		var result = try work() catch (error:haxe.Exception) {
			leave(previous);
			throw error;
		}
		leave(previous);
		return result;
		#else
		return work();
		#end
	}

	/**
	 * Runs `work` in a fresh arena and returns its result copied out of it, into the arena current before (the collector's pages
	 * when there is none); the arena is then released, from this frame, which existed while `work` ran (frames made after it
	 * still hold its values in slots they have not written). What else `work` leaves outside must not point into the arena:
	 * build it within the arena it belongs to, or hand it out with the result, which `publish` puts back where it belongs
	 * before the release. `released`, `kept` and `references` count the outcome, and `onKept` hears the references when the
	 * arena is kept.
	 */
	public static function unit<T>(work:() -> T, ?publish:T->Void, ?onKept:Int->Void):T {
		#if (haxeon && hl)
		var arena = new Arena(), previous = enter(arena);
		depth++;
		var result = copied(arena, previous, work);
		depth--;
		leave(previous);
		if (publish != null && failure == null)
			publish(result);
		var started = Sys.time(), found = free(arena);
		releaseSeconds += Sys.time() - started;
		var error = failure;
		failure = null;
		if (found == 0)
			released++;
		else {
			kept++;
			if (found > 0)
				references += found;
			if (onKept != null && error == null)
				onKept(found);
		}
		if (error != null)
			throw error;
		return result;
		#else
		return work();
		#end
	}

	/**
	 * `value` copied out of the current arena into the collector's pages, with what it reaches there, or `value` itself when
	 * it is not in one: for what outlives the work that made it (an interned name).
	 */
	public static function toGlobal<T>(value:T):T {
		#if (haxeon && hl)
		return depth == 0 ? value : cast copy(cast value, null, null);
		#else
		return value;
		#end
	}

	#if (haxeon && hl)
	/** What made the last `copied` fail; kept outside the frames the release reads. */
	@:processWide("set and taken within one `unit` call, null between them")
	static var failure:Null<haxe.Exception> = null;

	/** `work`'s result copied out of `arena`, in a frame of its own, gone before the release reads the stack. */
	static function copied<T>(arena:Arena, target:Dynamic, work:() -> T):Null<T> {
		try {
			return cast copy(cast work(), arena, target);
		} catch (error:haxe.Exception) {
			failure = error;
			return null;
		}
	}

	@:hlNative("std", "gc_arena_copy") static function copy(value:Dynamic, arena:Dynamic, target:Dynamic):Dynamic
		return value;
	#end

	#if (haxeon && hl)
	@:hlNative("std", "gc_arena_set_evacuation") static function setEvacuation(on:Bool):Void {}

	@:hlNative("std", "gc_arena_evacuated") static function evacuatedArenas():Float
		return 0;

	@:hlNative("std", "gc_arena_evacuated_bytes") static function evacuatedCopied():Float
		return 0;

	@:hlNative("std", "gc_arena_enter") static function enter(arena:Dynamic):Dynamic
		return null;

	@:hlNative("std", "gc_arena_leave") static function leave(previous:Dynamic):Void {}

	@:hlNative("std", "gc_arena_free") static function free(arena:Dynamic):Int
		return 0;
	#end
}

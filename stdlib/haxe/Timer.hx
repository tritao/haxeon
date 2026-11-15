package haxe;

/**
 * Haxe's Timer for what a program without an event loop can use: time stamps. Delayed and repeating timers (`new Timer`,
 * `Timer.delay`) need an event loop, which Haxeon programs do not have.
 */
class Timer {
	/** The current time in seconds, with sub-millisecond precision, for measuring how long something takes. */
	public static inline function stamp():Float
		return Sys.time();
}

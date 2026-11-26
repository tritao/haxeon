package haxeon.audio;

/** Cutoff frequency and order for a bus filter effect. */
class FilterSettings {
	/** The cutoff frequency. */
	public final cutoffFrequencyHz:Float;

	/** The filter order; higher is steeper. */
	public final order:Int;

	/** Settings of `order` at `cutoffFrequencyHz`. */
	public function new(cutoffFrequencyHz:Float, order:Int) {
		this.cutoffFrequencyHz = cutoffFrequencyHz;
		this.order = order;
	}
}

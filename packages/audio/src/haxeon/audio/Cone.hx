package haxeon.audio;

/** Directional attenuation cone in radians and linear gain. */
class Cone {
	/** The angle within which the sound is at full gain. */
	public final innerAngleRadians:Float;

	/** The angle beyond which it is at `outerGain`. */
	public final outerAngleRadians:Float;

	/** The gain outside the outer angle. */
	public final outerGain:Float;

	/** A cone; gain falls from full to `outerGain` between the two angles. */
	public function new(innerAngleRadians:Float, outerAngleRadians:Float, outerGain:Float) {
		this.innerAngleRadians = innerAngleRadians;
		this.outerAngleRadians = outerAngleRadians;
		this.outerGain = outerGain;
	}
}

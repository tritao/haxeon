package haxeon.editor;

/**
 * The neutral look of a 3D editor viewport, shared so that editors read the same: a light background
 * gradient, a workplane grid, and a three-light studio rig that turns with the camera, with presets.
 *
 * Colors are linear RGB triples and light directions are camera-space vectors, so this has no UI or
 * renderer dependency; each editor wraps them in its own color type and camera.
 */
class ViewportLook {
	public static inline var Studio:Int = 0;
	public static inline var Soft:Int = 1;
	public static inline var Contrast:Int = 2;

	/** Preset names, indexed by preset, for settings and menus. */
	public static final PresetNames:Array<String> = ["studio", "soft", "contrast"];

	/** Default multisample count for the scene image. */
	public static inline var SampleCount:Int = 4;

	/** Default workplane grid spacing, in metres. */
	public static inline var GridStep:Float = 0.2;

	public static function backgroundTop():Array<Float>
		return [0.894, 0.910, 0.922];

	public static function backgroundBottom():Array<Float>
		return [0.847, 0.867, 0.882];

	/**
	 * Directions from each of the three lights into the scene, in camera space (x right, y up, z toward
	 * the viewer). Shaders take the direction toward the light, so callers pass the negated vector.
	 */
	public static function lightDirections():Array<Array<Float>>
		return [
			[0.6841049, -0.12062616, -0.7193398],
			[-0.6403416, 0.7631294, 0.087155744],
			[-0.7544065, -0.63302225, -0.17364818]
		];

	/** Key, fill and rim intensities, in the order of `lightDirections`. */
	public static function intensities(preset:Int):Array<Float>
		return switch checked(preset) {
			case Soft: [0.65, 0.45, 0.25];
			case Contrast: [0.95, 0.20, 0.65];
			default: [0.76, 0.34, 0.50];
		};

	/** Ambient light from above. */
	public static function sky(preset:Int):Array<Float>
		return switch checked(preset) {
			case Soft: [0.25, 0.26, 0.27];
			case Contrast: [0.18, 0.19, 0.20];
			default: [0.22, 0.23, 0.24];
		};

	/** Ambient light from below. */
	public static function ground(preset:Int):Array<Float>
		return switch checked(preset) {
			case Soft: [0.22, 0.22, 0.23];
			case Contrast: [0.08, 0.08, 0.09];
			default: [0.16, 0.16, 0.17];
		};

	static function checked(preset:Int):Int {
		if (preset < Studio || preset > Contrast)
			throw "Unknown viewport lighting preset: " + preset;
		return preset;
	}
}

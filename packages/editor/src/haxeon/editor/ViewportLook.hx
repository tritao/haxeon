package haxeon.editor;

/** One light of a viewport's studio rig, in camera space. */
class ViewportLight {
	/** Unit direction from the light into the scene, in camera space (x right, y up, z toward the viewer). */
	public final direction:Array<Float>;

	/** Irradiance scale: a surface facing the light receives `intensity` times its albedo. */
	public final intensity:Float;

	/** Linear RGB tint. */
	public final color:Array<Float>;

	/**
	 * Angular radius of the light's soft panel, in radians. A panel is what metal reflects; zero makes the light a
	 * point that only gives a specular highlight.
	 */
	public final radius:Float;

	public function new(direction:Array<Float>, intensity:Float, color:Array<Float>, radius:Float) {
		var length = Math.sqrt(direction[0] * direction[0] + direction[1] * direction[1] + direction[2] * direction[2]);
		if (direction.length != 3 || !(length > 0) || color.length != 3 || !(intensity >= 0) || !(radius >= 0))
			throw "Invalid viewport light";
		this.direction = [direction[0] / length, direction[1] / length, direction[2] / length];
		this.intensity = intensity;
		this.color = color;
		this.radius = radius;
	}
}

/**
 * The look of a 3D editor viewport, shared so that every view of a part reads the same: a light background
 * gradient, a workplane grid, and a studio rig of three lights that turns with the camera, with presets. A preset
 * is the whole lighting: lights, the room's sky and ground light, how strongly surfaces reflect the room, contact
 * obscurance, the roughness floor and the exposure. Edge lines contrast with their surface (`edgeColor`).
 *
 * Colors are linear RGB triples and light directions are camera-space vectors, so this has no UI or renderer
 * dependency; each editor wraps them in its own color type and camera, and renderers outside the editor (the docs'
 * component viewers) build the same environment from these numbers.
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

	/** Edge lines on light surfaces: near black (display sRGB). */
	public static function edgeOnLight():Array<Float>
		return [0.035, 0.045, 0.055];

	/** Edge lines on dark surfaces (black oxide, rubber, dark paint): a light grey, so their edges stay readable. */
	public static function edgeOnDark():Array<Float>
		return [0.60, 0.63, 0.68];

	/** Surfaces whose base colour has a linear luminance below this get `edgeOnDark` edges. */
	public static inline var EdgeContrastLuminance:Float = 0.04;

	/** The edge colour for a surface of sRGB base colour `surface`. */
	public static function edgeColor(surface:Array<Float>):Array<Float> {
		function linear(value:Float):Float
			return value <= 0.04045 ? value / 12.92 : Math.pow((value + 0.055) / 1.055, 2.4);
		var luminance = 0.2126 * linear(surface[0]) + 0.7152 * linear(surface[1]) + 0.0722 * linear(surface[2]);
		return luminance < EdgeContrastLuminance ? edgeOnDark() : edgeOnLight();
	}

	/** Key, fill and rim, in that order. */
	public final lights:Array<ViewportLight>;

	/** Room light from above and from below: the ambient term, and what surfaces reflect away from the lights. */
	public final sky:Array<Float>;

	public final ground:Array<Float>;

	/** How strongly surfaces reflect the room, in [0, 1]. */
	public final reflection:Float;

	/** Contact obscurance radius, in metres; zero disables it. */
	public final occlusionRadius:Float;

	/** Contact obscurance strength and angular bias, in [0, 1]. */
	public final occlusionStrength:Float;

	public final occlusionBias:Float;

	/** Display-only minimum roughness, which broadens highlights on polished CAD faces. */
	public final roughnessFloor:Float;

	/** Exposure before tone mapping; zero shows shading clamped, without tone mapping. */
	public final exposure:Float;

	function new(lights:Array<ViewportLight>, sky:Array<Float>, ground:Array<Float>, reflection:Float, occlusionRadius:Float,
			occlusionStrength:Float, occlusionBias:Float, roughnessFloor:Float, exposure:Float) {
		this.lights = lights;
		this.sky = sky;
		this.ground = ground;
		this.reflection = reflection;
		this.occlusionRadius = occlusionRadius;
		this.occlusionStrength = occlusionStrength;
		this.occlusionBias = occlusionBias;
		this.roughnessFloor = roughnessFloor;
		this.exposure = exposure;
	}

	public static function preset(preset:Int):ViewportLook {
		// Key from above-left, which avoids a frontal wash of recess walls; fill from the right; rim from behind.
		var key = [0.60, -0.60, -0.53], fill = [-0.65, -0.15, -0.74], rim = [-0.45, 0.75, 0.48];
		var white = [1.0, 1.0, 1.0];
		// Panel sizes (radians): large soft key and fill, a narrower rim; metal reflects them as broad highlights.
		// The room is a light studio, so flat metal faces away from the panels still read as metal, not black.
		function rig(intensities:Array<Float>, radii:Array<Float>):Array<ViewportLight>
			return [
				new ViewportLight(key, intensities[0], white, radii[0]),
				new ViewportLight(fill, intensities[1], white, radii[1]),
				new ViewportLight(rim, intensities[2], white, radii[2])
			];
		return switch checked(preset) {
			case Soft: new ViewportLook(rig([0.65, 0.45, 0.25], [0.6, 0.9, 0.5]), [0.45, 0.47, 0.49], [0.38, 0.38, 0.40], 1.0, 0.025,
					0.50, 0.08, 0.48, 1.0);
			case Contrast: new ViewportLook(rig([0.95, 0.20, 0.65], [0.3, 0.5, 0.25]), [0.32, 0.34, 0.36], [0.08, 0.08, 0.09], 0.8,
					0.025, 0.75, 0.08, 0.40, 1.0);
			default: new ViewportLook(rig([0.95, 0.16, 0.30], [0.45, 0.7, 0.35]), [0.50, 0.53, 0.58], [0.22, 0.23, 0.26], 1.0, 0.025,
					0.75, 0.08, 0.40, 1.0);
		};
	}

	static function checked(preset:Int):Int {
		if (preset < Studio || preset > Contrast)
			throw "Unknown viewport lighting preset: " + preset;
		return preset;
	}
}

package haxeon.ui.style;

/** Typed effect families understood by the native compositor. */
enum EffectKind implements Equatable {
	Blur;
	Brightness;
	Contrast;
	Saturate;
	HueRotate;
	ColorMatrix;
	DropShadow;
	/** A renderer-owned shader/effect registration. */
	Custom;
}

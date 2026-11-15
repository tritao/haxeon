package haxeon.ui;

import NativeKitUI.UiLayoutAlignment as NativeAlignment;
import haxeon.ui.style.EffectKind;

/**
 * The UI choices that have no single native counterpart: each layout axis has its own alignment type over one native
 * enum, and effects include operations normalization removes before they reach the native compositor. Every other UI
 * enum is the generated native type itself.
 */
class NativeEnums {
	public static inline function alignmentXCode(value:LayoutAlignmentX):NativeAlignment
		return switch value {
			case Start: NativeAlignment.Start;
			case End: NativeAlignment.End;
			case Center: NativeAlignment.Center;
		};

	public static inline function alignmentYCode(value:LayoutAlignmentY):NativeAlignment
		return switch value {
			case Start: NativeAlignment.Start;
			case End: NativeAlignment.End;
			case Center: NativeAlignment.Center;
			case Baseline: NativeAlignment.Baseline;
		};

	public static function effectKind(value:EffectKind):NativeKitUI.UiEffectKind {
		return switch value {
			case EffectKind.Blur: NativeKitUI.UiEffectKind.Blur;
			case EffectKind.DropShadow: NativeKitUI.UiEffectKind.DropShadow;
			case EffectKind.Custom: NativeKitUI.UiEffectKind.Custom;
			case EffectKind.ColorMatrix: NativeKitUI.UiEffectKind.ColorMatrix;
			case EffectKind.Brightness | EffectKind.Contrast | EffectKind.Saturate | EffectKind.HueRotate:
				throw "Effect chain normalization left an unsupported operation";
		};
	}

}

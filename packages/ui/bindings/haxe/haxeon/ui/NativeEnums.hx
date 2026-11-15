package haxeon.ui;

import haxeon.ui.style.EffectKind;

/**
 * The one UI choice with no single native counterpart: effects include operations normalization removes before they reach
 * the native compositor. Every other UI enum is the generated native type itself.
 */
class NativeEnums {
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

import haxeon.ui.style.Decoration;
import haxeon.ui.style.DecorationKind;
import haxeon.ui.style.EffectKind;
import haxeon.ui.style.EffectParameter;
import haxeon.ui.style.EffectParameterType;
import haxeon.ui.style.EffectParameterTypeUtil;
import haxeon.ui.style.VisualEffect;

@:access(haxeon.ui.style.VisualEffect)
private class StyleKindsProbe {
	public static function run():Int {
		var kinds = [EffectKind.Blur, EffectKind.Brightness, EffectKind.Contrast, EffectKind.Saturate,
			EffectKind.HueRotate, EffectKind.ColorMatrix, EffectKind.DropShadow, EffectKind.Custom];
		var labels = ["blur", "brightness", "contrast", "saturate", "hue-rotate", "color-matrix", "drop-shadow", "custom"];
		for (index in 0...kinds.length) {
			var effect = new VisualEffect(kinds[index]);
			if (effect.describe() != labels[index] || !effect.isEqual(effect.copy())) return 1;
		}
		var decorations = [DecorationKind.Background, DecorationKind.Gradient, DecorationKind.Image,
			DecorationKind.NineSlice, DecorationKind.Border, DecorationKind.Outline, DecorationKind.Shadow, DecorationKind.Custom];
		var names = ["background", "gradient", "image", "nine-slice", "border", "outline", "shadow", "custom"];
		for (index in 0...decorations.length)
			if (new Decoration(decorations[index]).describe() != names[index]) return 2;
		var types = [EffectParameterType.Float, EffectParameterType.Vec2, EffectParameterType.Vec4, EffectParameterType.Color];
		var counts = [1, 2, 4, 4], typeNames = ["float", "vec2", "vec4", "color"];
		for (index in 0...types.length)
			if (EffectParameterTypeUtil.componentCount(types[index]) != counts[index]
				|| EffectParameterTypeUtil.label(types[index]) != typeNames[index]) return 3;
		if (EffectParameterTypeUtil.componentCount(null) != 0) return 4;
		var scalar = EffectParameter.scalar(2.0);
		if (scalar.describe() != "float(2)" || EffectParameter.vec2(1, 2) != EffectParameter.vec2(1, 2)) return 5;
		return 42;
	}
}

function main():Int return StyleKindsProbe.run();

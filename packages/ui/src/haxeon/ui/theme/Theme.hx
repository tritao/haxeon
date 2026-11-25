package haxeon.ui.theme;

import haxeon.ui.LayoutStyle;

import haxeon.ui.widgets.controls.Button;


import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutAxis;
import haxeon.ui.TextStyle;
import haxeon.ui.style.Decoration;
import haxeon.ui.style.VisualEffect;
import haxeon.ui.style.EffectChain;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleValue;

import haxeon.ui.theme.TextRole;
/** The look of a UI: its tokens, text roles and the built-in rules generated from them. */
class Theme {
	/** The colors and metrics the theme is built from. */
	public final tokens:ThemeTokens;

	/** The built-in rules for the standard widgets, generated from `tokens` by `refreshStyles`. */
	public final styles:StyleSheet;

	/** The fill behind selected text in a focused field. */
	public var textSelection:Color;

	/** The fill behind selected text in a field without focus. */
	public var textSelectionInactive:Color;

	/** The text caret's color. */
	public var textCaret:Color;

	/** The `Body` text role. */
	public var body:TextRoleStyle;

	/** The `Heading` text role. */
	public var heading:TextRoleStyle;

	/** The `Label` text role. */
	public var label:TextRoleStyle;

	/** The `Caption` text role. */
	public var caption:TextRoleStyle;

	/** The `Button` text role. */
	public var button:TextRoleStyle;

	/** A theme over `tokens`, or the default dark tokens when null. */
	public function new(?tokens:ThemeTokens) {
		this.tokens = tokens == null ? new ThemeTokens() : tokens;
		styles = new StyleSheet("Theme");
		textSelection = Color.rgba(0.2, 0.43, 0.82, 0.55);
		textSelectionInactive = Color.rgba(0.2, 0.43, 0.82, 0.30);
		textCaret = Color.rgba(0.96, 0.97, 0.99, 1.0);
		body = new TextRoleStyle(new TextStyle(), new ParagraphStyle(), this.tokens.textPrimary);
		heading = new TextRoleStyle(new TextStyle(24.0), new ParagraphStyle(), this.tokens.textPrimary);
		label = new TextRoleStyle(new TextStyle(14.0),
			new ParagraphStyle(TextWrap.None), this.tokens.textPrimary);
		caption = new TextRoleStyle(new TextStyle(12.0), new ParagraphStyle(), this.tokens.textSecondary);
		button = new TextRoleStyle(new TextStyle(),
			new ParagraphStyle(TextWrap.None), this.tokens.textOnAccent);
		refreshStyles();
	}

	/** The built-in light theme. */
	public static function light():Theme return palette(true);

	/** The built-in dark theme. */
	public static function dark():Theme return palette(false);

	static function palette(light:Bool):Theme {
		var tokens = new ThemeTokens();
		tokens.accent = light ? rgba(0.12, 0.37, 0.72) : rgba(0.25, 0.61, 0.89);
		tokens.accentHover = light ? rgba(0.16, 0.38, 0.69) : rgba(0.22, 0.48, 0.82);
		tokens.accentPressed = light ? rgba(0.11, 0.29, 0.54) : rgba(0.13, 0.34, 0.67);
		tokens.textPrimary = light ? rgba(0.10, 0.14, 0.21) : rgba(0.91, 0.94, 0.98);
		tokens.textSecondary = light ? rgba(0.32, 0.38, 0.47) : rgba(0.62, 0.68, 0.77);
		tokens.textDisabled = light ? rgba(0.38, 0.42, 0.49) : rgba(0.53, 0.55, 0.59);
		tokens.textOnAccent = rgba(1.0, 1.0, 1.0);
		tokens.surface = light ? rgba(0.98, 0.98, 1.0) : rgba(0.14, 0.16, 0.20);
		tokens.surfaceRaised = light ? rgba(0.87, 0.90, 0.95) : rgba(0.075, 0.10, 0.16);
		tokens.surfaceSunken = light ? rgba(0.93, 0.95, 0.98) : rgba(0.12, 0.15, 0.20);
		tokens.surfaceHover = light ? rgba(0.79, 0.85, 0.94) : rgba(0.12, 0.18, 0.28);
		tokens.border = light ? rgba(0.67, 0.72, 0.80) : rgba(0.32, 0.38, 0.48);
		tokens.borderStrong = light ? rgba(0.78, 0.81, 0.86) : rgba(0.45, 0.50, 0.58);
		tokens.focusRing = light ? rgba(0.22, 0.43, 0.73) : rgba(0.27, 0.52, 0.91);
		tokens.selection = light ? rgba(0.82, 0.89, 0.98) : rgba(0.16, 0.29, 0.50);
		tokens.info = tokens.accent;
		tokens.success = light ? rgba(0.09, 0.47, 0.29) : rgba(0.35, 0.85, 0.69);
		tokens.warning = light ? rgba(0.68, 0.34, 0.03) : rgba(0.96, 0.58, 0.31);
		tokens.overlayBackdrop = rgba(0.0, 0.0, 0.0, 0.54);
		tokens.tooltipBackground = light ? rgba(0.13, 0.17, 0.23) : rgba(0.08, 0.09, 0.11);
		tokens.selectionPopupShadow = rgba(0.0, 0.0, 0.0, light ? 0.20 : 0.42);
		var theme = new Theme(tokens);
		theme.textCaret = tokens.textPrimary;
		return theme;
	}

	static inline function rgba(red:Float, green:Float, blue:Float,
			alpha:Float = 1.0):Color return Color.rgba(red, green, blue, alpha);

	/** Rebuilds `styles` after a change to `tokens`. */
	public function refreshStyles():Void {
		styles.clear();
		styles.rule(StyleSelector.widget("button"), [
			StyleValue.background(tokens.accent),
			StyleValue.paddingSymmetric(tokens.spacingLarge, tokens.spacingMedium),
			StyleValue.radius(StyleProperty.RadiusTopLeft, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusTopRight, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusBottomRight, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, tokens.radiusMedium)
		]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Selected),
			[StyleValue.background(tokens.accentPressed)]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Focused),
			[
				StyleValue.borderColor(tokens.textOnAccent),
				StyleValue.borderWidth(1.0)
			]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Hovered),
			[StyleValue.background(tokens.accentHover)]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Pressed),
			[StyleValue.background(tokens.accentPressed)]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Disabled),
			[StyleValue.background(tokens.surfaceSunken)]);
		styles.rule(StyleSelector.widget("button").className("navigation"),
			[StyleValue.background(tokens.surfaceRaised)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Pressed),
			[StyleValue.background(tokens.surfaceSunken)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Focused),
			[
				StyleValue.borderColor(tokens.focusRing),
				StyleValue.borderWidth(1.0)
			]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Selected),
			[StyleValue.background(tokens.selection)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Disabled),
			[StyleValue.background(tokens.surface)]);
		styles.rule(StyleSelector.widget("button").className("secondary"), [
			StyleValue.background(tokens.surfaceRaised),
			StyleValue.borderColor(tokens.border), StyleValue.borderWidth(1.0)
		]);
		styles.rule(StyleSelector.widget("button").className("secondary").state(StyleState.Hovered), [
			StyleValue.background(tokens.surfaceHover), StyleValue.borderColor(tokens.borderStrong)
		]);
		styles.rule(StyleSelector.widget("button").className("secondary").state(StyleState.Pressed),
			[StyleValue.background(tokens.surfaceSunken)]);
		styles.rule(StyleSelector.widget("button").className("secondary").state(StyleState.Focused),
			[StyleValue.borderColor(tokens.focusRing)]);
		styles.rule(StyleSelector.widget("button").className("secondary").state(StyleState.Selected),
			[StyleValue.background(tokens.selection)]);
		styles.rule(StyleSelector.widget("button").className("secondary").state(StyleState.Disabled),
			[StyleValue.background(tokens.surfaceSunken)]);
		styles.rule(StyleSelector.widget("button").className("tab-header"), [
			StyleValue.fontSize(tokens.tabHeaderFontSize),
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.padding(new Insets(10.0, 6.0, 10.0, 6.0)),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 0.0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 0.0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 0.0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 0.0)
		]);
		styles.rule(StyleSelector.widget("button").className("tab-header").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("tab-header").state(StyleState.Selected),
			[StyleValue.background(tokens.surfaceRaised)]);
		styles.rule(StyleSelector.widget("button").className("tab-header").state(StyleState.Focused),
			[
				StyleValue.borderColor(tokens.focusRing),
				StyleValue.borderWidth(1.0)
			]);
		styles.rule(StyleSelector.widget("button").className("tab-close"),
			[StyleValue.background(Color.rgba(0, 0, 0, 0))]);
		for (state in [StyleState.Focused, StyleState.Pressed])
			styles.rule(StyleSelector.widget("button").className("tab-close").state(state),
				[StyleValue.background(Color.rgba(0, 0, 0, 0))]);
		styles.rule(StyleSelector.widget("button").className("tab-close").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("tab-close").state(StyleState.Disabled),
			[StyleValue.background(Color.rgba(0, 0, 0, 0))]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool"), [
			StyleValue.height(LayoutAxis.fixed(30.0)),
			StyleValue.padding(new Insets(7.0, 5.0, 7.0, 5.0)),
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.borderWidth(0.0),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 0.0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 0.0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 0.0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 0.0)
		]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Pressed),
			[StyleValue.background(tokens.surfaceRaised)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Selected),
			[StyleValue.background(tokens.selection)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Focused),
			[
				StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
				StyleValue.borderColor(tokens.focusRing),
				StyleValue.borderWidth(1.0)
			]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool")
			.state(StyleState.Selected).state(StyleState.Focused),
			[StyleValue.background(tokens.selection)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Disabled),
			[StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0))]);
		styles.rule(StyleSelector.widget("button").className("inspector-section-header"), [
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.borderWidth(0.0)
		]);
		styles.rule(StyleSelector.widget("button").className("inspector-section-header").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("inspector-section-header").state(StyleState.Focused),
			[
				StyleValue.borderColor(tokens.focusRing),
				StyleValue.borderWidth(1.0)
			]);
		styles.rule(StyleSelector.widget("button").className("menu-item"), [
			StyleValue.width(LayoutAxis.grow()),
			StyleValue.height(LayoutAxis.fit(30.0)),
			StyleValue.padding(new Insets(12.0, 5.0, 12.0, 5.0)),
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 4.0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 4.0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 4.0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 4.0)
		]);
		styles.rule(StyleSelector.widget("button").className("menu-item").state(StyleState.Disabled),
			[StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0))]);
		styles.rule(StyleSelector.widget("button").className("menu-item").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("menu-item").state(StyleState.Focused),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("menu-item").state(StyleState.Pressed),
			[StyleValue.background(tokens.surfaceRaised)]);
		styles.rule(StyleSelector.widget("button").className("select-trigger"), [
			StyleValue.background(tokens.surfaceSunken),
			StyleValue.padding(new Insets(12.0, 8.0, 34.0, 8.0)),
			StyleValue.borderColor(tokens.border), StyleValue.borderWidth(1.0)
		]);
		styles.rule(StyleSelector.widget("button").className("select-trigger").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("select-trigger").state(StyleState.Pressed),
			[StyleValue.background(tokens.surfaceRaised)]);
		styles.rule(StyleSelector.widget("button").className("select-trigger").state(StyleState.Focused), [
			StyleValue.background(tokens.surfaceSunken), StyleValue.borderColor(tokens.accent),
			StyleValue.borderWidth(2.0)
		]);
		styles.rule(StyleSelector.widget("button").className("selection-option"), [
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.padding(new Insets(28.0, 5.0, 10.0, 5.0))
		]);
		styles.rule(StyleSelector.widget("button").className("selection-option").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("selection-option").state(StyleState.Focused),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("selection-option").state(StyleState.Selected),
			[StyleValue.background(tokens.selection)]);
		styles.rule(StyleSelector.widget("text-field"), [
			StyleValue.textColor(tokens.textPrimary), StyleValue.background(tokens.surfaceSunken),
			StyleValue.borderColor(tokens.border), StyleValue.borderWidth(1.0)
		]);
		styles.rule(StyleSelector.widget("text-field").state(StyleState.Disabled),
			[StyleValue.textColor(tokens.textDisabled)]);
		styles.rule(StyleSelector.widget("text-field").state(StyleState.Focused),
			[StyleValue.borderColor(tokens.focusRing)]);
		styles.rule(StyleSelector.widget("text-field").className("search-input"), [
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.padding(new Insets(0.0, 0.0, 0.0, 0.0)),
			StyleValue.borderWidth(0.0)
		]);
		styles.rule(StyleSelector.widget("text-field").className("property-input"), [
			StyleValue.height(LayoutAxis.fixed(32.0)),
			StyleValue.padding(new Insets(8.0, 5.0, 8.0, 5.0)),
			StyleValue.textColor(tokens.textPrimary),
			StyleValue.background(tokens.surfaceSunken),
			StyleValue.borderColor(tokens.border),
			StyleValue.borderWidth(1.0)
		]);
		styles.rule(StyleSelector.widget("text-field").className("property-input").state(StyleState.Disabled),
			[StyleValue.textColor(tokens.textDisabled)]);
		styles.rule(StyleSelector.widget("text-field").className("property-input").state(StyleState.Hovered),
			[StyleValue.borderColor(tokens.borderStrong)]);
		styles.rule(StyleSelector.widget("text-field").className("property-input").state(StyleState.Focused),
			[StyleValue.borderColor(tokens.focusRing)]);
		styles.rule(StyleSelector.widget("text-field").className("combo-trigger"), [
			StyleValue.background(tokens.surfaceSunken),
			StyleValue.padding(new Insets(34.0, 8.0, 34.0, 8.0)),
			StyleValue.borderColor(tokens.border), StyleValue.borderWidth(1.0)
		]);
		styles.rule(StyleSelector.widget("text-field").className("combo-trigger").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("text-field").className("combo-trigger").state(StyleState.Focused), [
			StyleValue.background(tokens.surfaceSunken), StyleValue.borderColor(tokens.accent),
			StyleValue.borderWidth(2.0)
		]);
		styles.rule(StyleSelector.widget("checkbox"), [StyleValue.textColor(tokens.textPrimary)]);
		styles.rule(StyleSelector.widget("checkbox").state(StyleState.Disabled),
			[StyleValue.textColor(tokens.textDisabled)]);
		styles.rule(StyleSelector.widget("toggle"), [StyleValue.textColor(tokens.textPrimary)]);
		styles.rule(StyleSelector.widget("toggle").state(StyleState.Disabled),
			[StyleValue.textColor(tokens.textDisabled)]);
		styles.rule(StyleSelector.widget("radio"), [StyleValue.textColor(tokens.textPrimary)]);
		styles.rule(StyleSelector.widget("radio").state(StyleState.Disabled),
			[StyleValue.textColor(tokens.textDisabled)]);

		styles.rule(StyleSelector.widget("checkbox-indicator"),
			[StyleValue.background(tokens.borderStrong)]);
		styles.rule(StyleSelector.widget("checkbox-indicator").state(StyleState.Checked),
			[StyleValue.background(tokens.accent)]);
		styles.rule(StyleSelector.widget("checkbox-indicator").state(StyleState.Disabled),
			[StyleValue.background(tokens.border)]);

		styles.rule(StyleSelector.widget("toggle-indicator"), [
			StyleValue.background(tokens.borderStrong), StyleValue.alignX(LayoutAlignmentX.Start)
		]);
		styles.rule(StyleSelector.widget("toggle-indicator").state(StyleState.Checked), [
			StyleValue.background(tokens.accent), StyleValue.alignX(LayoutAlignmentX.End)
		]);
		styles.rule(StyleSelector.widget("toggle-indicator").state(StyleState.Disabled),
			[StyleValue.background(tokens.border)]);
		styles.rule(StyleSelector.widget("toggle-thumb"),
			[StyleValue.background(Color.rgba(0.98, 0.98, 0.99, 1.0))]);

		styles.rule(StyleSelector.widget("radio-indicator"), [StyleValue.background(tokens.borderStrong)]);
		styles.rule(StyleSelector.widget("radio-indicator").state(StyleState.Selected),
			[StyleValue.background(tokens.accent)]);
		styles.rule(StyleSelector.widget("radio-indicator").state(StyleState.Disabled),
			[StyleValue.background(tokens.border)]);
		styles.rule(StyleSelector.widget("radio-dot"),
			[StyleValue.background(tokens.surface)]);
		styles.rule(StyleSelector.widget("radio-mark"),
			[StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0))]);
		styles.rule(StyleSelector.widget("radio-mark").state(StyleState.Selected),
			[StyleValue.background(tokens.accent)]);
		styles.rule(StyleSelector.widget("radio-mark").state(StyleState.Selected).state(StyleState.Disabled),
			[StyleValue.background(tokens.border)]);

		styles.rule(StyleSelector.widget("slider"), [
			StyleValue.sliderTrackColor(tokens.borderStrong),
			StyleValue.sliderFillColor(tokens.accent),
			StyleValue.sliderThumbColor(tokens.textPrimary)
		]);
		styles.rule(StyleSelector.widget("slider").state(StyleState.Disabled), [
			StyleValue.sliderTrackColor(tokens.border),
			StyleValue.sliderFillColor(tokens.border),
			StyleValue.sliderThumbColor(tokens.textDisabled)
		]);
		styles.rule(StyleSelector.widget("split-divider"),
			[StyleValue.background(Color.rgba(tokens.textPrimary.red, tokens.textPrimary.green, tokens.textPrimary.blue,
			0.14))]);
		styles.rule(StyleSelector.widget("split-divider").state(StyleState.Focused),
			[StyleValue.background(tokens.accent)]);
		styles.rule(StyleSelector.widget("split-divider").state(StyleState.Hovered),
			[StyleValue.background(tokens.accentHover)]);
		styles.rule(StyleSelector.widget("split-divider").state(StyleState.Pressed),
			[StyleValue.background(tokens.accentPressed)]);
		styles.rule(StyleSelector.widget("progress-bar"), [
			StyleValue.progressTrackColor(tokens.surfaceSunken),
			StyleValue.progressFillColor(tokens.accent)
		]);
		styles.rule(StyleSelector.widget("popup-content"), [
			StyleValue.padding(new Insets(8.0, 8.0, 8.0, 8.0)),
			StyleValue.background(tokens.surface),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 5.0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 5.0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 5.0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 5.0)
		]);
		styles.rule(StyleSelector.widget("selection-popup"), [
			StyleValue.background(tokens.surface), StyleValue.borderColor(tokens.border),
			StyleValue.borderWidth(1.0), StyleValue.shadowColor(tokens.selectionPopupShadow),
			StyleValue.number(StyleProperty.ShadowOffsetY, 3.0), StyleValue.shadowBlur(8.0),
			StyleValue.radius(StyleProperty.RadiusTopLeft, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusTopRight, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusBottomRight, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, tokens.radiusMedium)
		]);
		styles.rule(StyleSelector.widget("popup-backdrop"),
			[StyleValue.background(tokens.overlayBackdrop)]);
		styles.rule(StyleSelector.widget("dialog-backdrop"),
			[StyleValue.background(tokens.overlayBackdrop)]);
		styles.rule(StyleSelector.widget("dialog-panel"), [
			StyleValue.padding(new Insets(24.0, 24.0, 24.0, 24.0)),
			StyleValue.background(tokens.surface),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 8.0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 8.0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 8.0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 8.0),
			StyleValue.number(StyleProperty.ChildGap, 16.0)
		]);
		styles.rule(StyleSelector.widget("dialog-heading"),
			[StyleValue.textColor(tokens.textPrimary)]);
		styles.rule(StyleSelector.widget("tooltip"), [
			StyleValue.fontSize(tokens.tooltipFontSize),
			StyleValue.padding(new Insets(10.0, 7.0, 10.0, 7.0)),
			StyleValue.background(tokens.surfaceRaised),
			StyleValue.textColor(tokens.textPrimary),
			StyleValue.decorations(DecorationChain.of([new BackgroundDecoration()])),
			// Compositor effects include their ink overflow; shadow parameters alone
			// do not paint a shadow, and node-local decorations are clipped.
			StyleValue.effects(EffectChain.of([new DropShadowEffect(0.0, 2.0, 3.0, tokens.selectionPopupShadow)])),
			StyleValue.radius(StyleProperty.RadiusTopLeft, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusTopRight, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusBottomRight, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, tokens.radiusSmall)
		]);
	}

	/** The body text color, or the disabled one. */
	public function textColor(enabled:Bool):Color
		return textRoleColor(TextRole.Body, enabled);

	/** Resolves a role's normal color while applying the shared disabled state. */
	public function textRoleColor(role:TextRole, enabled:Bool):Color
		return enabled ? textRole(role).color : tokens.textDisabled;

	/** Resolve the foreground against the actual state background, including custom fills. */
	public function buttonLabelColor(enabled:Bool, background:Null<Color>, ?preferred:Color):Color {
		if (!enabled) return tokens.textDisabled;
		var fill = background == null ? tokens.surface
			: Color.rgba(background.red * background.alpha + tokens.surface.red * (1 - background.alpha),
			background.green * background.alpha + tokens.surface.green * (1 - background.alpha),
			background.blue * background.alpha + tokens.surface.blue * (1 - background.alpha), 1);
		var foreground = preferred == null ? button.color : preferred;
		if (contrastRatio(foreground, fill) >= 4.5) return foreground;
		var white = Color.rgba(1, 1, 1, 1);
		var black = Color.rgba(0, 0, 0, 1);
		return contrastRatio(white, fill) >= contrastRatio(black, fill) ? white : black;
	}

	/** Keeps decorative ink muted where possible, with contrast measured after blending. */
	public static function contrastingDecoration(preferred:Color, background:Color):Color {
		// Neutral gray keeps whitespace subordinate to text. Aim for a modest
		// decorative contrast rather than the stronger contrast of readable text.
		var gray = (preferred.red + preferred.green + preferred.blue) / 3;
		var ink = Color.rgba(gray, gray, gray, preferred.alpha).compositeOver(background);
		var ratio = contrastRatio(ink, background);
		if (ratio >= 2 && ratio <= 2.5) return ink;
		var white = Color.rgba(1, 1, 1), black = Color.rgba(0, 0, 0);
		var backgroundGray = (background.red + background.green + background.blue) / 3;
		var target = ratio > 2.5 ? Color.rgba(backgroundGray, backgroundGray, backgroundGray) : contrastRatio(white,
			background) >= contrastRatio(black, background) ? white : black;
		var low = 0.0, high = 1.0;
		for (_ in 0...12) {
			var amount = (low + high) / 2;
			var candidate = Color.rgba(gray + (target.red - gray) * amount,
				gray + (target.green - gray) * amount, gray + (target.blue - gray) * amount);
			if ((contrastRatio(candidate, background) > 2.25) == (ratio > 2.5)) low = amount;
			else high = amount;
		}
		var amount = (low + high) / 2;
		return Color.rgba(gray + (target.red - gray) * amount,
			gray + (target.green - gray) * amount, gray + (target.blue - gray) * amount);
	}

	/** WCAG relative luminance ratio for opaque UI colors. */
	public static function contrastRatio(left:Color, right:Color):Float {
		var a = luminance(left), b = luminance(right);
		return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
	}

	static function luminance(color:Color):Float
		return channelLuminance(color.red) * 0.2126 + channelLuminance(color.green) * 0.7152
			+ channelLuminance(color.blue) * 0.0722;

	/** Returns the complete concrete style associated with a semantic role. */
	public function textRole(role:TextRole):TextRoleStyle {
		return switch role {
			case Body: body;
			case Heading: heading;
			case Label: label;
			case Caption: caption;
			case Button: button;
		};
	}

	static inline function channelLuminance(channel:Float):Float
		return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);

	/** The fill of a check box, toggle or radio indicator in the given state. */
	public function controlColor(selected:Bool, enabled:Bool):Color {
		if (!enabled)
			return tokens.border;
		return selected ? tokens.accent : tokens.borderStrong;
	}

}

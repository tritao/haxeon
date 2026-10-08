package haxeon.ui.theme;

import haxeon.ui.TextWrap;

import haxeon.ui.widgets.controls.Button;


import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutStyle;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.TextStyle;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutAxis;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.style.StyleSelector;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleValue;

/** Theme tokens plus the stylesheet generated from those tokens. */
class Theme {
	public final tokens:ThemeTokens;
	public final styles:StyleSheet;

	public var textSelection:Color;
	public var textSelectionInactive:Color;
	public var textCaret:Color;
	public var body:TextRoleStyle;
	public var heading:TextRoleStyle;
	public var label:TextRoleStyle;
	public var caption:TextRoleStyle;
	public var button:TextRoleStyle;
	public var accent(get, set):Color;
	public var text(get, set):Color;
	public var mutedText(get, set):Color;
	public var disabledText(get, set):Color;
	public var buttonText(get, set):Color;
	public var disabledButtonText(get, set):Color;
	public var buttonBackground(get, set):Color;
	public var buttonHover(get, set):Color;
	public var buttonPressed(get, set):Color;
	public var buttonFocused(get, set):Color;
	public var buttonSelected(get, set):Color;
	public var buttonDisabled(get, set):Color;
	public var controlSelected(get, set):Color;
	public var controlUnselected(get, set):Color;
	public var controlDisabled(get, set):Color;
	public var panelBackground(get, set):Color;
	public var overlayBackdrop(get, set):Color;
	public var tooltipBackground(get, set):Color;

	public function new(?tokens:ThemeTokens) {
		this.tokens = tokens == null ? new ThemeTokens() : tokens;
		styles = new StyleSheet("Theme");
		textSelection = Color.rgba(0.2, 0.43, 0.82, 0.55);
		textSelectionInactive = Color.rgba(0.2, 0.43, 0.82, 0.30);
		textCaret = Color.rgba(0.96, 0.97, 0.99, 1.0);
		body = new TextRoleStyle(new TextStyle(), new ParagraphStyle(), this.tokens.text);
		heading = new TextRoleStyle(new TextStyle(24.0), new ParagraphStyle(), this.tokens.text);
		label = new TextRoleStyle(new TextStyle(14.0),
			new ParagraphStyle(TextWrap.None), this.tokens.text);
		caption = new TextRoleStyle(new TextStyle(12.0), new ParagraphStyle(), this.tokens.mutedText);
		button = new TextRoleStyle(new TextStyle(),
			new ParagraphStyle(TextWrap.None), this.tokens.buttonText);
		refreshStyles();
	}

	/** Creates the canonical light palette used by UIKit applications. */
	public static function light():Theme return palette(true);

	/** Creates the canonical dark palette used by UIKit applications. */
	public static function dark():Theme return palette(false);

	static function palette(light:Bool):Theme {
		var tokens = new ThemeTokens();
		tokens.accent = light ? rgba(0.12, 0.37, 0.72) : rgba(0.25, 0.61, 0.89);
		tokens.text = light ? rgba(0.10, 0.14, 0.21) : rgba(0.91, 0.94, 0.98);
		tokens.mutedText = light ? rgba(0.32, 0.38, 0.47) : rgba(0.62, 0.68, 0.77);
		tokens.disabledText = light ? rgba(0.38, 0.42, 0.49) : rgba(0.53, 0.55, 0.59);
		tokens.buttonText = rgba(1.0, 1.0, 1.0);
		tokens.disabledButtonText = light ? rgba(0.28, 0.31, 0.36) : rgba(0.62, 0.65, 0.70);
		tokens.buttonBackground = light ? rgba(0.18, 0.39, 0.70) : rgba(0.16, 0.38, 0.70);
		tokens.buttonHover = light ? rgba(0.16, 0.38, 0.69) : rgba(0.22, 0.48, 0.82);
		tokens.buttonPressed = light ? rgba(0.11, 0.29, 0.54) : rgba(0.13, 0.34, 0.67);
		tokens.buttonFocused = light ? rgba(0.22, 0.43, 0.73) : rgba(0.27, 0.52, 0.91);
		tokens.buttonSelected = light ? rgba(0.16, 0.36, 0.65) : rgba(0.17, 0.37, 0.68);
		tokens.buttonDisabled = light ? rgba(0.82, 0.84, 0.88) : rgba(0.22, 0.24, 0.28);
		tokens.controlSelected = tokens.accent;
		tokens.controlUnselected = light ? rgba(0.78, 0.81, 0.86) : rgba(0.16, 0.18, 0.22);
		tokens.controlDisabled = light ? rgba(0.82, 0.84, 0.88) : rgba(0.20, 0.21, 0.24);
		tokens.progressTrack = light ? rgba(0.78, 0.84, 0.92) : rgba(0.20, 0.25, 0.33);
		tokens.progressFill = tokens.accent;
		tokens.selectionField = light ? rgba(0.93, 0.95, 0.98) : rgba(0.12, 0.15, 0.20);
		tokens.selectionHover = light ? rgba(0.91, 0.94, 0.98) : rgba(0.18, 0.23, 0.31);
		tokens.selectionPressed = light ? rgba(0.85, 0.90, 0.97) : rgba(0.15, 0.20, 0.28);
		tokens.selectionHighlight = light ? rgba(0.82, 0.89, 0.98) : rgba(0.16, 0.29, 0.50);
		tokens.selectionBorder = light ? rgba(0.67, 0.72, 0.80) : rgba(0.32, 0.38, 0.48);
		tokens.selectionPopupShadow = rgba(0.0, 0.0, 0.0, light ? 0.20 : 0.42);
		tokens.panelBackground = light ? rgba(0.98, 0.98, 1.0) : rgba(0.14, 0.16, 0.20);
		tokens.overlayBackdrop = rgba(0.0, 0.0, 0.0, 0.54);
		tokens.tooltipBackground = light ? rgba(0.13, 0.17, 0.23) : rgba(0.08, 0.09, 0.11);
		tokens.navigationBackground = light ? rgba(0.87, 0.90, 0.95) : rgba(0.075, 0.10, 0.16);
		tokens.navigationHover = light ? rgba(0.79, 0.85, 0.94) : rgba(0.12, 0.18, 0.28);
		tokens.navigationPressed = light ? rgba(0.72, 0.81, 0.92) : rgba(0.15, 0.23, 0.36);
		tokens.navigationFocused = light ? rgba(0.76, 0.84, 0.94) : rgba(0.14, 0.25, 0.41);
		tokens.navigationSelected = light ? rgba(0.74, 0.83, 0.95) : rgba(0.16, 0.29, 0.50);
		tokens.navigationDisabled = light ? rgba(0.89, 0.90, 0.92) : rgba(0.10, 0.12, 0.16);
		tokens.accentHover = tokens.buttonHover;
		tokens.accentPressed = tokens.buttonPressed;
		tokens.textPrimary = tokens.text;
		tokens.textSecondary = tokens.mutedText;
		tokens.textDisabled = tokens.disabledText;
		tokens.textOnAccent = tokens.buttonText;
		tokens.surface = tokens.panelBackground;
		tokens.surfaceRaised = tokens.navigationBackground;
		tokens.surfaceSunken = tokens.selectionField;
		tokens.surfaceHover = tokens.navigationHover;
		tokens.border = tokens.selectionBorder;
		tokens.borderStrong = tokens.controlUnselected;
		tokens.focusRing = tokens.buttonFocused;
		tokens.selection = tokens.selectionHighlight;
		tokens.info = tokens.accent;
		tokens.deriveComponents();
		var theme = new Theme(tokens);
		theme.textCaret = tokens.text;
		return theme;
	}

	static inline function rgba(red:Float, green:Float, blue:Float,
			alpha:Float = 1.0):Color return Color.rgba(red, green, blue, alpha);

	/** Rebuilds built-in rules after callers change a compatibility token. */
	public function refreshStyles():Void {
		styles.clear();
		styles.rule(StyleSelector.widget("button"), [
			StyleValue.background(buttonBackground),
			StyleValue.paddingSymmetric(tokens.spacingLarge, tokens.spacingMedium),
			StyleValue.radius(StyleProperty.RadiusTopLeft, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusTopRight, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusBottomRight, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, tokens.radiusMedium)
		]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Selected),
			[StyleValue.background(buttonSelected)]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Focused),
			[StyleValue.borderColor(tokens.textOnAccent), StyleValue.borderWidth(1.0)]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Hovered),
			[StyleValue.background(buttonHover)]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Pressed),
			[StyleValue.background(buttonPressed)]);
		styles.rule(StyleSelector.widget("button").state(StyleState.Disabled),
			[StyleValue.background(buttonDisabled)]);
		styles.rule(StyleSelector.widget("button").className("navigation"),
			[StyleValue.background(tokens.navigationBackground)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Hovered),
			[StyleValue.background(tokens.navigationHover)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Pressed),
			[StyleValue.background(tokens.navigationPressed)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Focused),
			[StyleValue.borderColor(tokens.focusRing), StyleValue.borderWidth(1.0)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Selected),
			[StyleValue.background(tokens.navigationSelected)]);
		styles.rule(StyleSelector.widget("button").className("navigation").state(StyleState.Disabled),
			[StyleValue.background(tokens.navigationDisabled)]);
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
			[StyleValue.borderColor(tokens.focusRing), StyleValue.borderWidth(1.0)]);
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
			[StyleValue.background(tokens.selectionHover)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Pressed),
			[StyleValue.background(tokens.selectionPressed)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Selected),
			[StyleValue.background(tokens.selectionHighlight)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Focused),
			[StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
				StyleValue.borderColor(tokens.focusRing), StyleValue.borderWidth(1.0)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool")
			.state(StyleState.Selected).state(StyleState.Focused),
			[StyleValue.background(tokens.selectionHighlight)]);
		styles.rule(StyleSelector.widget("button").className("viewport-tool").state(StyleState.Disabled),
			[StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0))]);
		styles.rule(StyleSelector.widget("button").className("inspector-section-header"), [
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.borderWidth(0.0)
		]);
		styles.rule(StyleSelector.widget("button").className("inspector-section-header").state(StyleState.Hovered),
			[StyleValue.background(tokens.surfaceHover)]);
		styles.rule(StyleSelector.widget("button").className("inspector-section-header").state(StyleState.Focused),
			[StyleValue.borderColor(tokens.focusRing), StyleValue.borderWidth(1.0)]);
		styles.rule(StyleSelector.widget("button").className("menu-item"), [
			StyleValue.width(LayoutAxis.grow()),
			StyleValue.padding(new Insets(10.0, 10.0, 6.0, 6.0)),
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 0.0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 0.0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 0.0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 0.0)
		]);
		styles.rule(StyleSelector.widget("button").className("menu-item").state(StyleState.Disabled),
			[StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0))]);
		styles.rule(StyleSelector.widget("button").className("menu-item").state(StyleState.Hovered),
			[StyleValue.background(tokens.selectionHover)]);
		styles.rule(StyleSelector.widget("button").className("menu-item").state(StyleState.Focused),
			[StyleValue.background(tokens.selectionField)]);
		styles.rule(StyleSelector.widget("button").className("menu-item").state(StyleState.Pressed),
			[StyleValue.background(tokens.selectionPressed)]);
		styles.rule(StyleSelector.widget("button").className("select-trigger"), [
			StyleValue.background(tokens.selectionField),
			StyleValue.padding(new Insets(12.0, 8.0, 34.0, 8.0)),
			StyleValue.borderColor(tokens.selectionBorder), StyleValue.borderWidth(1.0)
		]);
		styles.rule(StyleSelector.widget("button").className("select-trigger").state(StyleState.Hovered),
			[StyleValue.background(tokens.selectionHover)]);
		styles.rule(StyleSelector.widget("button").className("select-trigger").state(StyleState.Pressed),
			[StyleValue.background(tokens.selectionPressed)]);
		styles.rule(StyleSelector.widget("button").className("select-trigger").state(StyleState.Focused), [
			StyleValue.background(tokens.selectionField), StyleValue.borderColor(accent),
			StyleValue.borderWidth(2.0)
		]);
		styles.rule(StyleSelector.widget("button").className("selection-option"), [
			StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0)),
			StyleValue.padding(new Insets(28.0, 5.0, 10.0, 5.0))
		]);
		styles.rule(StyleSelector.widget("button").className("selection-option").state(StyleState.Hovered),
			[StyleValue.background(tokens.selectionHover)]);
		styles.rule(StyleSelector.widget("button").className("selection-option").state(StyleState.Focused),
			[StyleValue.background(tokens.selectionHover)]);
		styles.rule(StyleSelector.widget("button").className("selection-option").state(StyleState.Selected),
			[StyleValue.background(tokens.selectionHighlight)]);
		styles.rule(StyleSelector.widget("text-field"), [
			StyleValue.textColor(text), StyleValue.background(tokens.surfaceSunken),
			StyleValue.borderColor(tokens.border), StyleValue.borderWidth(1.0)
		]);
		styles.rule(StyleSelector.widget("text-field").state(StyleState.Disabled),
			[StyleValue.textColor(disabledText)]);
		styles.rule(StyleSelector.widget("text-field").state(StyleState.Focused),
			[StyleValue.borderColor(tokens.focusRing)]);
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
			StyleValue.background(tokens.selectionField),
			StyleValue.padding(new Insets(34.0, 8.0, 34.0, 8.0)),
			StyleValue.borderColor(tokens.selectionBorder), StyleValue.borderWidth(1.0)
		]);
		styles.rule(StyleSelector.widget("text-field").className("combo-trigger").state(StyleState.Hovered),
			[StyleValue.background(tokens.selectionHover)]);
		styles.rule(StyleSelector.widget("text-field").className("combo-trigger").state(StyleState.Focused), [
			StyleValue.background(tokens.selectionField), StyleValue.borderColor(accent),
			StyleValue.borderWidth(2.0)
		]);
		styles.rule(StyleSelector.widget("checkbox"), [StyleValue.textColor(text)]);
		styles.rule(StyleSelector.widget("checkbox").state(StyleState.Disabled),
			[StyleValue.textColor(disabledText)]);
		styles.rule(StyleSelector.widget("toggle"), [StyleValue.textColor(text)]);
		styles.rule(StyleSelector.widget("toggle").state(StyleState.Disabled),
			[StyleValue.textColor(disabledText)]);
		styles.rule(StyleSelector.widget("radio"), [StyleValue.textColor(text)]);
		styles.rule(StyleSelector.widget("radio").state(StyleState.Disabled),
			[StyleValue.textColor(disabledText)]);

		styles.rule(StyleSelector.widget("checkbox-indicator"),
			[StyleValue.background(controlUnselected)]);
		styles.rule(StyleSelector.widget("checkbox-indicator").state(StyleState.Checked),
			[StyleValue.background(controlSelected)]);
		styles.rule(StyleSelector.widget("checkbox-indicator").state(StyleState.Disabled),
			[StyleValue.background(controlDisabled)]);

		styles.rule(StyleSelector.widget("toggle-indicator"), [
			StyleValue.background(controlUnselected), StyleValue.alignX(LayoutAlignmentX.Start)]);
		styles.rule(StyleSelector.widget("toggle-indicator").state(StyleState.Checked), [
			StyleValue.background(controlSelected), StyleValue.alignX(LayoutAlignmentX.End)]);
		styles.rule(StyleSelector.widget("toggle-indicator").state(StyleState.Disabled),
			[StyleValue.background(controlDisabled)]);
		styles.rule(StyleSelector.widget("toggle-thumb"),
			[StyleValue.background(Color.rgba(0.98, 0.98, 0.99, 1.0))]);

		styles.rule(StyleSelector.widget("radio-indicator"), [StyleValue.background(controlUnselected)]);
		styles.rule(StyleSelector.widget("radio-indicator").state(StyleState.Selected),
			[StyleValue.background(controlSelected)]);
		styles.rule(StyleSelector.widget("radio-indicator").state(StyleState.Disabled),
			[StyleValue.background(controlDisabled)]);
		styles.rule(StyleSelector.widget("radio-dot"),
			[StyleValue.background(panelBackground)]);
		styles.rule(StyleSelector.widget("radio-mark"),
			[StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 0.0))]);
		styles.rule(StyleSelector.widget("radio-mark").state(StyleState.Selected),
			[StyleValue.background(controlSelected)]);
		styles.rule(StyleSelector.widget("radio-mark").state(StyleState.Selected).state(StyleState.Disabled),
			[StyleValue.background(controlDisabled)]);

		styles.rule(StyleSelector.widget("slider"), [
			StyleValue.sliderTrackColor(controlUnselected),
			StyleValue.sliderFillColor(accent),
			StyleValue.sliderThumbColor(text)
		]);
		styles.rule(StyleSelector.widget("slider").state(StyleState.Disabled), [
			StyleValue.sliderTrackColor(controlDisabled),
			StyleValue.sliderFillColor(controlDisabled),
			StyleValue.sliderThumbColor(disabledText)
		]);
		styles.rule(StyleSelector.widget("split-divider"),
			[StyleValue.background(tokens.selectionBorder)]);
		styles.rule(StyleSelector.widget("split-divider").state(StyleState.Hovered),
			[StyleValue.background(tokens.controlSelected)]);
		styles.rule(StyleSelector.widget("split-divider").state(StyleState.Pressed),
			[StyleValue.background(tokens.buttonPressed)]);
		styles.rule(StyleSelector.widget("split-divider").state(StyleState.Focused),
			[StyleValue.background(tokens.buttonFocused)]);
		styles.rule(StyleSelector.widget("progress-bar"), [
			StyleValue.progressTrackColor(tokens.progressTrack),
			StyleValue.progressFillColor(tokens.progressFill)
		]);
		styles.rule(StyleSelector.widget("popup-content"), [
			StyleValue.padding(new Insets(8.0, 8.0, 8.0, 8.0)),
			StyleValue.background(panelBackground),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 5.0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 5.0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 5.0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 5.0)
		]);
		styles.rule(StyleSelector.widget("selection-popup"), [
			StyleValue.background(panelBackground), StyleValue.borderColor(tokens.selectionBorder),
			StyleValue.borderWidth(1.0), StyleValue.shadowColor(tokens.selectionPopupShadow),
			StyleValue.of(StyleProperty.ShadowOffsetY, 3.0), StyleValue.shadowBlur(8.0),
			StyleValue.radius(StyleProperty.RadiusTopLeft, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusTopRight, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusBottomRight, tokens.radiusMedium),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, tokens.radiusMedium)
		]);
		styles.rule(StyleSelector.widget("popup-backdrop"),
			[StyleValue.background(overlayBackdrop)]);
		styles.rule(StyleSelector.widget("dialog-backdrop"),
			[StyleValue.background(overlayBackdrop)]);
		styles.rule(StyleSelector.widget("dialog-panel"), [
			StyleValue.padding(new Insets(24.0, 24.0, 24.0, 24.0)),
			StyleValue.background(panelBackground),
			StyleValue.radius(StyleProperty.RadiusTopLeft, 8.0),
			StyleValue.radius(StyleProperty.RadiusTopRight, 8.0),
			StyleValue.radius(StyleProperty.RadiusBottomRight, 8.0),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, 8.0),
			StyleValue.of(StyleProperty.ChildGap, 16.0)
		]);
		styles.rule(StyleSelector.widget("dialog-heading"),
			[StyleValue.textColor(text)]);
		styles.rule(StyleSelector.widget("tooltip"), [
			StyleValue.padding(new Insets(10.0, 7.0, 10.0, 7.0)),
			StyleValue.background(tokens.surfaceRaised),
			StyleValue.textColor(tokens.textPrimary),
			StyleValue.borderColor(tokens.borderStrong), StyleValue.borderWidth(1.0),
			StyleValue.shadowColor(tokens.selectionPopupShadow),
			StyleValue.of(StyleProperty.ShadowOffsetY, 2.0), StyleValue.shadowBlur(6.0),
			StyleValue.radius(StyleProperty.RadiusTopLeft, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusTopRight, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusBottomRight, tokens.radiusSmall),
			StyleValue.radius(StyleProperty.RadiusBottomLeft, tokens.radiusSmall)
		]);
	}

	public function textColor(enabled:Bool):Color
		return textRoleColor(TextRole.Body, enabled);

	/** Resolves a role's normal color while applying the shared disabled state. */
	public function textRoleColor(role:TextRole, enabled:Bool):Color
		return enabled ? textRole(role).color : disabledText;

	/** Resolve the foreground against the actual state background, including custom fills. */
	public function buttonLabelColor(enabled:Bool, background:Color, ?preferred:Color):Color {
		if (!enabled) return disabledButtonText;
		var fill = background == null ? tokens.surface : Color.rgba(
			background.red * background.alpha + tokens.surface.red * (1 - background.alpha),
			background.green * background.alpha + tokens.surface.green * (1 - background.alpha),
			background.blue * background.alpha + tokens.surface.blue * (1 - background.alpha), 1);
		var foreground = preferred == null ? button.color : preferred;
		if (contrastRatio(foreground, fill) >= 4.5) return foreground;
		var white = Color.rgba(1, 1, 1, 1);
		var black = Color.rgba(0, 0, 0, 1);
		return contrastRatio(white, fill) >= contrastRatio(black, fill) ? white : black;
	}

	/** WCAG relative luminance ratio for opaque UI colors. */
	public static function contrastRatio(left:Color, right:Color):Float {
		var a = luminance(left), b = luminance(right);
		return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
	}

	static function luminance(color:Color):Float
		return channelLuminance(color.red) * 0.2126 + channelLuminance(color.green) * 0.7152 + channelLuminance(color.blue) * 0.0722;

	/** Returns the complete concrete style associated with a semantic role. */
	public function textRole(role:TextRole):TextRoleStyle {
		if (role == TextRole.Heading)
			return heading;
		if (role == TextRole.Label)
			return label;
		if (role == TextRole.Caption)
			return caption;
		if (role == TextRole.Button)
			return button;
		return body;
	}

	static inline function channelLuminance(channel:Float):Float
		return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);

	public function controlColor(selected:Bool, enabled:Bool):Color {
		if (!enabled)
			return controlDisabled;
		return selected ? controlSelected : controlUnselected;
	}

	function get_accent():Color return tokens.accent;
	function set_accent(value:Color):Color { tokens.accent = value; return value; }
	function get_text():Color return body == null ? tokens.text : body.color;
	function set_text(value:Color):Color {
		tokens.text = value;
		tokens.textPrimary = value;
		if (body != null)
			body.color = value;
		return value;
	}
	function get_mutedText():Color return caption == null ? tokens.mutedText : caption.color;
	function set_mutedText(value:Color):Color {
		tokens.mutedText = value;
		tokens.textSecondary = value;
		if (caption != null)
			caption.color = value;
		return value;
	}
	function get_disabledText():Color return tokens.disabledText;
	function set_disabledText(value:Color):Color { tokens.disabledText = value; tokens.textDisabled = value; return value; }
	function get_buttonText():Color return button == null ? tokens.buttonText : button.color;
	function set_buttonText(value:Color):Color {
		tokens.buttonText = value;
		tokens.textOnAccent = value;
		if (button != null)
			button.color = value;
		return value;
	}
	function get_disabledButtonText():Color return tokens.disabledButtonText;
	function set_disabledButtonText(value:Color):Color { tokens.disabledButtonText = value; return value; }
	function get_buttonBackground():Color return tokens.buttonBackground;
	function set_buttonBackground(value:Color):Color { tokens.buttonBackground = value; return value; }
	function get_buttonHover():Color return tokens.buttonHover;
	function set_buttonHover(value:Color):Color { tokens.buttonHover = value; return value; }
	function get_buttonPressed():Color return tokens.buttonPressed;
	function set_buttonPressed(value:Color):Color { tokens.buttonPressed = value; return value; }
	function get_buttonFocused():Color return tokens.buttonFocused;
	function set_buttonFocused(value:Color):Color { tokens.buttonFocused = value; return value; }
	function get_buttonSelected():Color return tokens.buttonSelected;
	function set_buttonSelected(value:Color):Color { tokens.buttonSelected = value; return value; }
	function get_buttonDisabled():Color return tokens.buttonDisabled;
	function set_buttonDisabled(value:Color):Color { tokens.buttonDisabled = value; return value; }
	function get_controlSelected():Color return tokens.controlSelected;
	function set_controlSelected(value:Color):Color { tokens.controlSelected = value; return value; }
	function get_controlUnselected():Color return tokens.controlUnselected;
	function set_controlUnselected(value:Color):Color { tokens.controlUnselected = value; return value; }
	function get_controlDisabled():Color return tokens.controlDisabled;
	function set_controlDisabled(value:Color):Color { tokens.controlDisabled = value; return value; }
	function get_panelBackground():Color return tokens.panelBackground;
	function set_panelBackground(value:Color):Color { tokens.panelBackground = value; tokens.surface = value; return value; }
	function get_overlayBackdrop():Color return tokens.overlayBackdrop;
	function set_overlayBackdrop(value:Color):Color { tokens.overlayBackdrop = value; return value; }
	function get_tooltipBackground():Color return tokens.tooltipBackground;
	function set_tooltipBackground(value:Color):Color { tokens.tooltipBackground = value; return value; }
}

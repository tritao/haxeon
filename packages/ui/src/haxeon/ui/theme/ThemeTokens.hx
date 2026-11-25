package haxeon.ui.theme;

import haxeon.ui.Color;

/**
 * The colors and metrics a theme is built from, in two tiers: the semantic palette (`accent`, `textPrimary`, `surface`,
 * `border` and their kin) says what a color means, and the component tokens (`button*`, `navigation*`, `control*`,
 * `selection*` and the like) say where it is used. `deriveComponents` sets the second from the first; set the palette,
 * derive, then adjust single components.
 */
class ThemeTokens {
	/** The brand color: primary buttons, selected controls and focus. */
	public var accent:Color;

	/** Derived from `textPrimary` by `deriveComponents`. */
	public var text:Color;

	/** Derived from `textSecondary` by `deriveComponents`. */
	public var mutedText:Color;

	/** Derived from `textDisabled` by `deriveComponents`. */
	public var disabledText:Color;

	/** Derived from `textOnAccent` by `deriveComponents`. */
	public var buttonText:Color;

	/** Derived from `textDisabled` by `deriveComponents`. */
	public var disabledButtonText:Color;

	/** Derived from `accent` by `deriveComponents`. */
	public var buttonBackground:Color;

	/** Derived from `accentHover` by `deriveComponents`. */
	public var buttonHover:Color;

	/** Derived from `accentPressed` by `deriveComponents`. */
	public var buttonPressed:Color;

	/** Derived from `focusRing` by `deriveComponents`. */
	public var buttonFocused:Color;

	/** Derived from `accentPressed` by `deriveComponents`. */
	public var buttonSelected:Color;

	/** Derived from `surfaceSunken` by `deriveComponents`. */
	public var buttonDisabled:Color;

	/** Derived from `surfaceRaised` by `deriveComponents`. */
	public var navigationBackground:Color;

	/** Derived from `surfaceHover` by `deriveComponents`. */
	public var navigationHover:Color;

	/** Derived from `surfaceSunken` by `deriveComponents`. */
	public var navigationPressed:Color;

	/** Derived from `surfaceRaised` by `deriveComponents`. */
	public var navigationFocused:Color;

	/** Derived from `selection` by `deriveComponents`. */
	public var navigationSelected:Color;

	/** Derived from `surface` by `deriveComponents`. */
	public var navigationDisabled:Color;

	/** Derived from `accent` by `deriveComponents`. Fills a checked check box, toggle or radio. */
	public var controlSelected:Color;

	/** Derived from `borderStrong` by `deriveComponents`. */
	public var controlUnselected:Color;

	/** Derived from `border` by `deriveComponents`. */
	public var controlDisabled:Color;

	/** Derived from `surfaceSunken` by `deriveComponents`. */
	public var progressTrack:Color;

	/** Derived from `accent` by `deriveComponents`. */
	public var progressFill:Color;

	/** Derived from `surfaceSunken` by `deriveComponents`. The field of a select or combo box. */
	public var selectionField:Color;

	/** Derived from `surfaceHover` by `deriveComponents`. */
	public var selectionHover:Color;

	/** Derived from `surfaceRaised` by `deriveComponents`. */
	public var selectionPressed:Color;

	/** Derived from `selection` by `deriveComponents`. The highlighted option in a popup. */
	public var selectionHighlight:Color;

	/** Derived from `border` by `deriveComponents`. */
	public var selectionBorder:Color;

	/** The shadow under a select's popup. */
	public var selectionPopupShadow:Color;

	/** Derived from `surface` by `deriveComponents`. */
	public var panelBackground:Color;

	/** The dimming behind modal overlays. */
	public var overlayBackdrop:Color;

	/** The fill of tooltips. */
	public var tooltipBackground:Color;
	/** Logical font size shared by ordinary tooltip content. */
	public var tooltipFontSize:Float = 13.0;
	/** Shared tab chrome metrics, in logical pixels. */
	public var tabHeaderHeight:Float = 36.0;

	/** The font size of tab labels. */
	public var tabHeaderFontSize:Float = 14.0;

	/** Corner radius of small surfaces: tooltips. */
	public var radiusSmall:Float;

	/** Corner radius of buttons and select popups. */
	public var radiusMedium:Float;

	/** Corner radius for large surfaces; the built-in rules do not use it. */
	public var radiusLarge:Float;

	/** The small gap, in logical pixels. */
	public var spacingSmall:Float;

	/** The medium gap. */
	public var spacingMedium:Float;

	/** The large gap. */
	public var spacingLarge:Float;

	// Application-independent visual meanings. Component defaults are derived below.

	/** The accent under the pointer. */
	public var accentHover:Color;

	/** The accent while pressed. */
	public var accentPressed:Color;

	/** Ordinary text. */
	public var textPrimary:Color;

	/** Secondary text: hints, captions, metadata. */
	public var textSecondary:Color;

	/** Text of disabled controls. */
	public var textDisabled:Color;

	/** Text drawn on the accent color. */
	public var textOnAccent:Color;

	/** The base background of panels. */
	public var surface:Color;

	/** Surfaces above the base, such as bars and popups. */
	public var surfaceRaised:Color;

	/** Surfaces set into the base, such as fields and tracks. */
	public var surfaceSunken:Color;

	/** A surface under the pointer. */
	public var surfaceHover:Color;

	/** Ordinary borders and separators. */
	public var border:Color;

	/** Borders that must stand out; also the track of an unchecked toggle. */
	public var borderStrong:Color;

	/** The keyboard focus indicator. */
	public var focusRing:Color;

	/** Informational status. */
	public var info:Color;

	/** Success status. */
	public var success:Color;

	/** Warning status. */
	public var warning:Color;

	/** Errors and destructive actions. */
	public var danger:Color;

	/** Selected items in lists and trees. */
	public var selection:Color;

	/** The default dark tokens, with the component tokens derived. */
	public function new() {
		accent = Color.rgba(0.22, 0.48, 0.86, 1.0);
		text = Color.rgba(0.96, 0.97, 0.99, 1.0);
		mutedText = Color.rgba(0.69, 0.72, 0.77, 1.0);
		disabledText = Color.rgba(0.53, 0.55, 0.59, 1.0);
		buttonText = text;
		disabledButtonText = disabledText;
		buttonBackground = Color.rgba(0.16, 0.4, 0.78, 1.0);
		buttonHover = Color.rgba(0.21, 0.46, 0.84, 1.0);
		buttonPressed = Color.rgba(0.13, 0.34, 0.67, 1.0);
		buttonFocused = Color.rgba(0.27, 0.52, 0.91, 1.0);
		buttonSelected = Color.rgba(0.17, 0.37, 0.68, 1.0);
		buttonDisabled = Color.rgba(0.22, 0.24, 0.28, 1.0);
		navigationBackground = Color.rgba(0.075, 0.10, 0.16, 1.0);
		navigationHover = Color.rgba(0.12, 0.18, 0.28, 1.0);
		navigationPressed = Color.rgba(0.15, 0.23, 0.36, 1.0);
		navigationFocused = Color.rgba(0.14, 0.25, 0.41, 1.0);
		navigationSelected = Color.rgba(0.16, 0.29, 0.50, 1.0);
		navigationDisabled = Color.rgba(0.10, 0.12, 0.16, 1.0);
		controlSelected = accent;
		controlUnselected = Color.rgba(0.16, 0.18, 0.22, 1.0);
		controlDisabled = Color.rgba(0.20, 0.21, 0.24, 1.0);
		progressTrack = Color.rgba(0.20, 0.23, 0.29, 1.0);
		progressFill = accent;
		selectionField = Color.rgba(0.13, 0.14, 0.17, 1.0);
		selectionHover = Color.rgba(0.18, 0.21, 0.27, 1.0);
		selectionPressed = Color.rgba(0.15, 0.18, 0.24, 1.0);
		selectionHighlight = Color.rgba(0.16, 0.29, 0.50, 1.0);
		selectionBorder = Color.rgba(0.31, 0.35, 0.42, 1.0);
		selectionPopupShadow = Color.rgba(0.0, 0.0, 0.0, 0.36);
		panelBackground = Color.rgba(0.13, 0.14, 0.17, 1.0);
		overlayBackdrop = Color.rgba(0.0, 0.0, 0.0, 0.48);
		tooltipBackground = Color.rgba(0.08, 0.09, 0.11, 0.96);
		radiusSmall = 3.0;
		radiusMedium = 6.0;
		radiusLarge = 10.0;
		spacingSmall = 4.0;
		spacingMedium = 8.0;
		spacingLarge = 12.0;
		accentHover = buttonHover;
		accentPressed = buttonPressed;
		textPrimary = text;
		textSecondary = mutedText;
		textDisabled = disabledText;
		textOnAccent = buttonText;
		surface = panelBackground;
		surfaceRaised = navigationBackground;
		surfaceSunken = selectionField;
		surfaceHover = navigationHover;
		border = selectionBorder;
		borderStrong = controlUnselected;
		focusRing = buttonFocused;
		info = Color.rgba(0.25, 0.61, 0.89, 1.0);
		success = Color.rgba(0.26, 0.72, 0.45, 1.0);
		warning = Color.rgba(0.95, 0.68, 0.23, 1.0);
		danger = Color.rgba(0.87, 0.32, 0.34, 1.0);
		selection = selectionHighlight;
		deriveComponents();
	}

	/** Set component defaults from the semantic palette. Call after changing palette colors. */
	public function deriveComponents():Void {
		text = textPrimary;
		mutedText = textSecondary;
		disabledText = textDisabled;
		buttonText = textOnAccent;
		disabledButtonText = textDisabled;
		buttonBackground = accent;
		buttonHover = accentHover;
		buttonPressed = accentPressed;
		buttonFocused = focusRing;
		buttonSelected = accentPressed;
		buttonDisabled = surfaceSunken;
		navigationBackground = surfaceRaised;
		navigationHover = surfaceHover;
		navigationPressed = surfaceSunken;
		navigationFocused = surfaceRaised;
		navigationSelected = selection;
		navigationDisabled = surface;
		controlSelected = accent;
		controlUnselected = borderStrong;
		controlDisabled = border;
		progressTrack = surfaceSunken;
		progressFill = accent;
		selectionField = surfaceSunken;
		selectionHover = surfaceHover;
		selectionPressed = surfaceRaised;
		selectionHighlight = selection;
		selectionBorder = border;
		panelBackground = surface;
	}
}

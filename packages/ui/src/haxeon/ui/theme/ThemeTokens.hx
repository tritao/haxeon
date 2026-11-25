package haxeon.ui.theme;

import haxeon.ui.Color;

/**
 * The colors and metrics a theme is built from. Each color says what it means (`accent`, `textPrimary`, `surface`,
 * `border` and their kin), not where it is used: the theme's rules map the palette onto the widgets, and an
 * application restyles one widget with its own rules rather than with a token of that widget.
 */
class ThemeTokens {
	/** The brand color: primary buttons, selected controls and progress. */
	public var accent:Color;

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

	/** Text drawn on the accent color, as on primary buttons. */
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

	/** Selected items in lists and trees. */
	public var selection:Color;

	/** Informational status. */
	public var info:Color;

	/** Success status. */
	public var success:Color;

	/** Warning status. */
	public var warning:Color;

	/** Errors and destructive actions. */
	public var danger:Color;

	/** The dimming behind modal overlays. */
	public var overlayBackdrop:Color;

	/** The fill of tooltips. */
	public var tooltipBackground:Color;

	/** The shadow under a select's popup. */
	public var selectionPopupShadow:Color;

	/** Logical font size shared by ordinary tooltip content. */
	public var tooltipFontSize:Float = 13.0;

	/** The height of tab headers, in logical pixels. */
	public var tabHeaderHeight:Float = 36.0;

	/** The font size of tab labels. */
	public var tabHeaderFontSize:Float = 14.0;

	/** Corner radius of small surfaces: tooltips. */
	public var radiusSmall:Float = 3.0;

	/** Corner radius of buttons and select popups. */
	public var radiusMedium:Float = 6.0;

	/** Corner radius for large surfaces; the built-in rules do not use it. */
	public var radiusLarge:Float = 10.0;

	/** The small gap, in logical pixels. */
	public var spacingSmall:Float = 4.0;

	/** The medium gap. */
	public var spacingMedium:Float = 8.0;

	/** The large gap. */
	public var spacingLarge:Float = 12.0;

	/** The default dark palette. */
	public function new() {
		accent = Color.rgba(0.22, 0.48, 0.86, 1.0);
		accentHover = Color.rgba(0.21, 0.46, 0.84, 1.0);
		accentPressed = Color.rgba(0.13, 0.34, 0.67, 1.0);
		textPrimary = Color.rgba(0.96, 0.97, 0.99, 1.0);
		textSecondary = Color.rgba(0.69, 0.72, 0.77, 1.0);
		textDisabled = Color.rgba(0.53, 0.55, 0.59, 1.0);
		textOnAccent = textPrimary;
		surface = Color.rgba(0.13, 0.14, 0.17, 1.0);
		surfaceRaised = Color.rgba(0.075, 0.10, 0.16, 1.0);
		surfaceSunken = Color.rgba(0.13, 0.14, 0.17, 1.0);
		surfaceHover = Color.rgba(0.12, 0.18, 0.28, 1.0);
		border = Color.rgba(0.31, 0.35, 0.42, 1.0);
		borderStrong = Color.rgba(0.16, 0.18, 0.22, 1.0);
		focusRing = Color.rgba(0.27, 0.52, 0.91, 1.0);
		selection = Color.rgba(0.16, 0.29, 0.50, 1.0);
		info = Color.rgba(0.25, 0.61, 0.89, 1.0);
		success = Color.rgba(0.26, 0.72, 0.45, 1.0);
		warning = Color.rgba(0.95, 0.68, 0.23, 1.0);
		danger = Color.rgba(0.87, 0.32, 0.34, 1.0);
		overlayBackdrop = Color.rgba(0.0, 0.0, 0.0, 0.48);
		tooltipBackground = Color.rgba(0.08, 0.09, 0.11, 0.96);
		selectionPopupShadow = Color.rgba(0.0, 0.0, 0.0, 0.36);
	}

}

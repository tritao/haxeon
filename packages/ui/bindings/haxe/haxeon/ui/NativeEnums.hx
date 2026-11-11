package haxeon.ui;

import NativeKitUI.UiLayoutSizing as NativeLayoutSizing;
import NativeKitUI.UiLayoutVisualKind as NativeLayoutVisualKind;
import NativeKitUI.UiFontFamily as NativeFontFamily;
import NativeKitUI.UiTextAlignment as NativeTextAlignment;
import NativeKitUI.UiTextWrap as NativeTextWrap;
import NativeKitUI.UiTextDirection as NativeTextDirection;
import NativeKitUI.UiCompositeMode as NativeCompositeMode;
import NativeKitUI.UiLineCap as NativeLineCap;
import NativeKitUI.UiLineJoin as NativeLineJoin;
import NativeKitUI.UiImageFormat as NativeImageFormat;
import NativeKitUI.UiImageFilter as NativeImageFilter;

import NativeKitUI.UiLayoutDirection as NativeDirection;
import NativeKitUI.UiLayoutAlignment as NativeAlignment;
import NativeKitUI.NkuiLayoutDistribution as NativeDistribution;
import NativeKitUI.NkuiLayoutWrapMode as NativeWrapMode;
import NativeKitUI.NkuiLayoutSelfAlignment as NativeSelfAlignment;
import nativekit.ffi.NativeKitTypes.CursorShape as NativeCursorShape;
import haxeon.ui.core.CursorShape as UiCursorShape;
import haxeon.ui.core.CachePolicy;
import haxeon.ui.style.MaskKind;
import haxeon.ui.style.EffectKind;

/** The generated binding owns native codes; UI choices have their own nominal tags. */
class NativeEnums {
	public static function layoutSizing(value:LayoutSizing):NativeLayoutSizing {
		return switch value {
			case LayoutSizing.Fit: NativeLayoutSizing.Fit;
			case LayoutSizing.Grow: NativeLayoutSizing.Grow;
			case LayoutSizing.Fixed: NativeLayoutSizing.Fixed;
			case LayoutSizing.Percent: NativeLayoutSizing.Percent;
		};
	}

	public static function layoutVisualKind(value:LayoutVisualKind):NativeLayoutVisualKind {
		return switch value {
			case LayoutVisualKind.Box: NativeLayoutVisualKind.Box;
			case LayoutVisualKind.Text: NativeLayoutVisualKind.Text;
			case LayoutVisualKind.Image: NativeLayoutVisualKind.Image;
			case LayoutVisualKind.Custom: NativeLayoutVisualKind.Custom;
		};
	}

	public static function fontFamily(value:FontFamily):NativeFontFamily {
		return switch value {
			case FontFamily.Default: NativeFontFamily.Default;
			case FontFamily.Emoji: NativeFontFamily.Emoji;
			case FontFamily.Monospace: NativeFontFamily.Monospace;
		};
	}

	public static function textAlignment(value:TextAlignment):NativeTextAlignment {
		return switch value {
			case TextAlignment.Start: NativeTextAlignment.Start;
			case TextAlignment.Center: NativeTextAlignment.Center;
			case TextAlignment.End: NativeTextAlignment.End;
		};
	}

	public static function textWrap(value:TextWrap):NativeTextWrap {
		return switch value {
			case TextWrap.None: NativeTextWrap.None;
			case TextWrap.Word: NativeTextWrap.Word;
			case TextWrap.WordCharacter: NativeTextWrap.WordCharacter;
		};
	}

	public static function textDirection(value:TextDirection):NativeTextDirection {
		return switch value {
			case TextDirection.Auto: NativeTextDirection.Auto;
			case TextDirection.Ltr: NativeTextDirection.Ltr;
			case TextDirection.Rtl: NativeTextDirection.Rtl;
		};
	}

	public static function compositeMode(value:CompositeMode):NativeCompositeMode {
		return switch value {
			case CompositeMode.SourceOver: NativeCompositeMode.NkuiCompositeSourceOver;
		};
	}

	public static function lineCap(value:LineCap):NativeLineCap {
		return switch value {
			case LineCap.Butt: NativeLineCap.Butt;
			case LineCap.Round: NativeLineCap.Round;
			case LineCap.Square: NativeLineCap.Square;
		};
	}

	public static function lineJoin(value:LineJoin):NativeLineJoin {
		return switch value {
			case LineJoin.Round: NativeLineJoin.Round;
			case LineJoin.Bevel: NativeLineJoin.Bevel;
			case LineJoin.Miter: NativeLineJoin.Miter;
		};
	}

	public static function imageFormat(value:ImageFormat):NativeImageFormat {
		return switch value {
			case ImageFormat.R8: NativeImageFormat.R8;
			case ImageFormat.RGBA8: NativeImageFormat.Rgba8;
		};
	}

	public static function imageFilter(value:ImageFilter):NativeImageFilter {
		return switch value {
			case ImageFilter.Linear: NativeImageFilter.Linear;
			case ImageFilter.Nearest: NativeImageFilter.Nearest;
		};
	}

	public static function textDirectionFromNative(value:NativeTextDirection):TextDirection {
		return switch value {
			case NativeTextDirection.Auto: TextDirection.Auto;
			case NativeTextDirection.Ltr: TextDirection.Ltr;
			case NativeTextDirection.Rtl: TextDirection.Rtl;
			default: throw "Invalid native text direction";
		};
	}

	/** UI case order is independent of the integer codes declared by the native binding. */
	public static inline function directionCode(value:LayoutDirection):NativeDirection
		return switch value {
			case LeftToRight: NativeDirection.LeftToRight;
			case TopToBottom: NativeDirection.TopToBottom;
		};

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

	public static inline function distributionCode(value:LayoutDistribution):NativeDistribution
		return switch value {
			case Start: NativeDistribution.Start;
			case Center: NativeDistribution.Center;
			case End: NativeDistribution.End;
			case SpaceBetween: NativeDistribution.SpaceBetween;
			case SpaceAround: NativeDistribution.SpaceAround;
			case SpaceEvenly: NativeDistribution.SpaceEvenly;
		};

	public static inline function wrapModeCode(value:LayoutWrapMode):NativeWrapMode
		return switch value {
			case NoWrap: NativeWrapMode.NoWrap;
			case Wrap: NativeWrapMode.Wrap;
		};

	public static inline function selfAlignmentCode(value:LayoutSelfAlignment):NativeSelfAlignment
		return switch value {
			case Inherit: NativeSelfAlignment.Inherit;
			case Start: NativeSelfAlignment.Start;
			case End: NativeSelfAlignment.End;
			case Center: NativeSelfAlignment.Center;
			case Baseline: NativeSelfAlignment.Baseline;
		};

	public static function cachePolicy(value:CachePolicy):NativeKitUI.NkuiLayoutCachePolicy {
		return switch value {
			case CachePolicy.None: NativeKitUI.NkuiLayoutCachePolicy.None;
			case CachePolicy.Auto: NativeKitUI.NkuiLayoutCachePolicy.Auto;
			case CachePolicy.Raster: NativeKitUI.NkuiLayoutCachePolicy.Raster;
		};
	}

	public static function maskKind(value:MaskKind):NativeKitUI.NkuiMaskKind {
		return switch value {
			case MaskKind.Rectangle: NativeKitUI.NkuiMaskKind.Rectangle;
			case MaskKind.RoundedRect: NativeKitUI.NkuiMaskKind.RoundedRect;
			case MaskKind.Circle: NativeKitUI.NkuiMaskKind.Circle;
			case MaskKind.LinearGradient: NativeKitUI.NkuiMaskKind.LinearGradient;
			case MaskKind.Image: NativeKitUI.NkuiMaskKind.Image;
		};
	}

	public static function accessibilityRole(value:haxeon.ui.semantics.AccessibilityRole):nativekit.ffi.NativeKitTypes.AccessibilityRole {
		return switch value {
			case haxeon.ui.semantics.AccessibilityRole.Group: nativekit.ffi.NativeKitTypes.AccessibilityRole.Group;
			case haxeon.ui.semantics.AccessibilityRole.Button: nativekit.ffi.NativeKitTypes.AccessibilityRole.Button;
			case haxeon.ui.semantics.AccessibilityRole.Checkbox: nativekit.ffi.NativeKitTypes.AccessibilityRole.Checkbox;
			case haxeon.ui.semantics.AccessibilityRole.Radio: nativekit.ffi.NativeKitTypes.AccessibilityRole.Radio;
			case haxeon.ui.semantics.AccessibilityRole.Text: nativekit.ffi.NativeKitTypes.AccessibilityRole.Text;
			case haxeon.ui.semantics.AccessibilityRole.TextField: nativekit.ffi.NativeKitTypes.AccessibilityRole.TextField;
			case haxeon.ui.semantics.AccessibilityRole.Link: nativekit.ffi.NativeKitTypes.AccessibilityRole.Link;
			case haxeon.ui.semantics.AccessibilityRole.Image: nativekit.ffi.NativeKitTypes.AccessibilityRole.Image;
			case haxeon.ui.semantics.AccessibilityRole.Heading: nativekit.ffi.NativeKitTypes.AccessibilityRole.Heading;
			case haxeon.ui.semantics.AccessibilityRole.List: nativekit.ffi.NativeKitTypes.AccessibilityRole.List;
			case haxeon.ui.semantics.AccessibilityRole.ListItem: nativekit.ffi.NativeKitTypes.AccessibilityRole.ListItem;
			case haxeon.ui.semantics.AccessibilityRole.Slider: nativekit.ffi.NativeKitTypes.AccessibilityRole.Slider;
			case haxeon.ui.semantics.AccessibilityRole.ScrollArea: nativekit.ffi.NativeKitTypes.AccessibilityRole.ScrollArea;
			case haxeon.ui.semantics.AccessibilityRole.Dialog: nativekit.ffi.NativeKitTypes.AccessibilityRole.Dialog;
			case haxeon.ui.semantics.AccessibilityRole.Menu: nativekit.ffi.NativeKitTypes.AccessibilityRole.Menu;
			case haxeon.ui.semantics.AccessibilityRole.MenuBar: nativekit.ffi.NativeKitTypes.AccessibilityRole.MenuBar;
			case haxeon.ui.semantics.AccessibilityRole.MenuItem: nativekit.ffi.NativeKitTypes.AccessibilityRole.MenuItem;
			case haxeon.ui.semantics.AccessibilityRole.TabList: nativekit.ffi.NativeKitTypes.AccessibilityRole.TabList;
			case haxeon.ui.semantics.AccessibilityRole.Tab: nativekit.ffi.NativeKitTypes.AccessibilityRole.Tab;
			case haxeon.ui.semantics.AccessibilityRole.TabPanel: nativekit.ffi.NativeKitTypes.AccessibilityRole.TabPanel;
			case haxeon.ui.semantics.AccessibilityRole.Switch: nativekit.ffi.NativeKitTypes.AccessibilityRole.Switch;
			case haxeon.ui.semantics.AccessibilityRole.ProgressBar: nativekit.ffi.NativeKitTypes.AccessibilityRole.ProgressBar;
			case haxeon.ui.semantics.AccessibilityRole.ComboBox: nativekit.ffi.NativeKitTypes.AccessibilityRole.ComboBox;
			case haxeon.ui.semantics.AccessibilityRole.Collection: nativekit.ffi.NativeKitTypes.AccessibilityRole.Collection;
			case haxeon.ui.semantics.AccessibilityRole.CollectionItem: nativekit.ffi.NativeKitTypes.AccessibilityRole.CollectionItem;
			case haxeon.ui.semantics.AccessibilityRole.Grid: nativekit.ffi.NativeKitTypes.AccessibilityRole.Grid;
			case haxeon.ui.semantics.AccessibilityRole.Row: nativekit.ffi.NativeKitTypes.AccessibilityRole.Row;
			case haxeon.ui.semantics.AccessibilityRole.Cell: nativekit.ffi.NativeKitTypes.AccessibilityRole.Cell;
			case haxeon.ui.semantics.AccessibilityRole.ColumnHeader: nativekit.ffi.NativeKitTypes.AccessibilityRole.ColumnHeader;
			case haxeon.ui.semantics.AccessibilityRole.RowHeader: nativekit.ffi.NativeKitTypes.AccessibilityRole.RowHeader;
			case haxeon.ui.semantics.AccessibilityRole.Tree: nativekit.ffi.NativeKitTypes.AccessibilityRole.Tree;
			case haxeon.ui.semantics.AccessibilityRole.TreeItem: nativekit.ffi.NativeKitTypes.AccessibilityRole.TreeItem;
			case haxeon.ui.semantics.AccessibilityRole.Separator: nativekit.ffi.NativeKitTypes.AccessibilityRole.Separator;
			case haxeon.ui.semantics.AccessibilityRole.Toolbar: nativekit.ffi.NativeKitTypes.AccessibilityRole.Toolbar;
			case haxeon.ui.semantics.AccessibilityRole.Status: nativekit.ffi.NativeKitTypes.AccessibilityRole.Status;
			case haxeon.ui.semantics.AccessibilityRole.Alert: nativekit.ffi.NativeKitTypes.AccessibilityRole.Alert;
		};
	}

	public static function accessibilityOrientation(value:haxeon.ui.semantics.AccessibilityOrientation):nativekit.ffi.NativeKitTypes.AccessibilityOrientation {
		return switch value {
			case haxeon.ui.semantics.AccessibilityOrientation.Unspecified: nativekit.ffi.NativeKitTypes.AccessibilityOrientation.Unspecified;
			case haxeon.ui.semantics.AccessibilityOrientation.Horizontal: nativekit.ffi.NativeKitTypes.AccessibilityOrientation.Horizontal;
			case haxeon.ui.semantics.AccessibilityOrientation.Vertical: nativekit.ffi.NativeKitTypes.AccessibilityOrientation.Vertical;
		};
	}

	public static function cursorShape(shape:UiCursorShape):NativeCursorShape {
		return switch shape {
			case UiCursorShape.Text: NativeCursorShape.Ibeam;
			case UiCursorShape.Crosshair: NativeCursorShape.Crosshair;
			case UiCursorShape.Hand: NativeCursorShape.Hand;
			case UiCursorShape.HorizontalResize: NativeCursorShape.HorizontalResize;
			case UiCursorShape.VerticalResize: NativeCursorShape.VerticalResize;
			case UiCursorShape.DiagonalResize: NativeCursorShape.NwseResize;
			case UiCursorShape.DiagonalResizeNesw: NativeCursorShape.NeswResize;
			case UiCursorShape.Move: NativeCursorShape.Move;
			case UiCursorShape.NotAllowed: NativeCursorShape.NotAllowed;
			case UiCursorShape.Arrow: NativeCursorShape.Arrow;
		};
	}

	public static function effectKind(value:EffectKind):NativeKitUI.NkuiEffectKind {
		return switch value {
			case EffectKind.Blur: NativeKitUI.NkuiEffectKind.Blur;
			case EffectKind.DropShadow: NativeKitUI.NkuiEffectKind.DropShadow;
			case EffectKind.Custom: NativeKitUI.NkuiEffectKind.Custom;
			case EffectKind.ColorMatrix: NativeKitUI.NkuiEffectKind.ColorMatrix;
			case EffectKind.Brightness | EffectKind.Contrast | EffectKind.Saturate | EffectKind.HueRotate:
				throw "Effect chain normalization left an unsupported operation";
		};
	}
}

import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.TextLayout.TextRangeRect;

import haxeon.ui.LayoutSession;
import haxeon.ui.Paint;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.PathBuilder;
import haxeon.ui.Surface;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitTypes;
import haxeon.ui.Color;
import haxeon.ui.Canvas;
import haxeon.ui.DisplayList;
import haxeon.ui.CompositeMode;
import haxeon.ui.FontCollection;
import haxeon.ui.FontFamily;
import haxeon.ui.GradientStop;
import haxeon.ui.Image;
import haxeon.ui.ImageFormat;
import haxeon.ui.ImageFilter;
import haxeon.ui.Insets;
import haxeon.ui.Path;
import haxeon.ui.Paint.SolidPaint;
import haxeon.ui.icons.IconName;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutSizing;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutSizing;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.TextAlignment;
import haxeon.ui.Rect;
import haxeon.ui.Point;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.Transform2D;
import haxeon.ui.TextLayout;
import haxeon.ui.TextDirection;
import haxeon.ui.TextStyle;
import haxeon.ui.TextColorRange;
import haxeon.ui.widgets.text.TextDecoration;
import haxeon.ui.widgets.text.TextDecorationKind;
import haxeon.ui.TextWrap;
import haxeon.platform.NativeKitEventValue;
import haxeon.platform.NativeKitEventValue.NativeKitTextEdit;
import haxeon.platform.NativeKitEvents;
import haxeon.platform.NativeKitRuntime;
import NativeKitEventDecoderTests;
import haxeon.ui.core.NativeInputAdapter;
import haxeon.ui.core.CursorShape as UiCursorShape;
import haxeon.ui.core.CachePolicy;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Command;
import haxeon.ui.core.CommandContext;
import haxeon.ui.core.CommandParameters;
import haxeon.ui.core.CommandRegistry;
import haxeon.ui.core.CommandResult;
import haxeon.ui.docking.DockDropZone;
import haxeon.ui.widgets.docking.DockDropTarget;
import haxeon.ui.docking.DockNode;
import haxeon.ui.docking.DockPanelDescriptor;
import haxeon.ui.docking.DockWorkspaceStorage;
import haxeon.ui.docking.DockWorkspaceCommands;
import haxeon.ui.widgets.docking.DockPanelContent;
import haxeon.ui.docking.DockSplitAxis;
import haxeon.ui.docking.DockWorkspacePersistence;
import haxeon.ui.docking.DockWorkspaceModel;
import haxeon.ui.widgets.docking.DockWorkspaceInteraction;
import haxeon.ui.editing.EditorDocument;
import haxeon.ui.editing.EditHistory;
import haxeon.ui.editing.EditOperation;
import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyDescriptorOptions;
import haxeon.ui.properties.PropertyBinding;
import haxeon.ui.properties.PropertyEditResult;
import haxeon.ui.properties.PropertyEditorExtension;
import haxeon.ui.properties.PropertyEditorRegistry;
import haxeon.ui.properties.PropertyInspectorSection;
import haxeon.ui.properties.PropertyOption;
import haxeon.ui.properties.PropertyType;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.properties.PropertyValueTools;
import haxeon.ui.plotting.PlotModel;
import haxeon.ui.plotting.PlotPoint;
import haxeon.ui.plotting.PlotSeries;
import haxeon.ui.core.ViewportCamera;
import haxeon.ui.core.ViewportContent;
import haxeon.ui.core.EventDispatcher;
import haxeon.ui.core.FocusManager;
import haxeon.ui.core.HitTest;
import haxeon.ui.core.HitTestBehavior;
import haxeon.ui.core.InteractionStateStore;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.StateStore;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.UiDirtyFlag;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.UiTouchData;
import haxeon.ui.core.WidgetId;
import haxeon.ui.core.View;
import haxeon.ui.core.Shortcut;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityBridge;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.AccessibilityRequest;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.ButtonVariant;
import haxeon.ui.widgets.commands.CommandButton;
import haxeon.ui.widgets.commands.CommandMenu;
import haxeon.ui.widgets.commands.CommandPalette;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Align;
import haxeon.ui.widgets.layout.AppShell;
import haxeon.ui.widgets.CanvasView;
import haxeon.ui.widgets.Shape;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.ImageView;
import haxeon.ui.widgets.LayeredImageView;
import haxeon.ui.widgets.LayeredImageView.ImageLayer;
import haxeon.ui.widgets.NineSliceView;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.collections.ListView;
import haxeon.ui.widgets.collections.ListViewModel;
import haxeon.ui.widgets.layout.Padding;
import haxeon.ui.widgets.controls.ProgressBar;
import haxeon.ui.widgets.properties.PropertyEditor;
import haxeon.ui.widgets.properties.PropertyInspector;
import haxeon.ui.widgets.GpuViewport;
import haxeon.ui.widgets.plotting.PlotView;
import haxeon.ui.widgets.overlays.Dialog;
import haxeon.ui.widgets.docking.DockWorkspace;
import haxeon.ui.widgets.text.DefaultTextStyle;
import haxeon.ui.widgets.overlays.Menu;
import haxeon.ui.widgets.overlays.MenuItem;
import haxeon.ui.widgets.overlays.Popup;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.widgets.scroll.ScrollController;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.controls.SearchField;
import haxeon.ui.widgets.layout.SizedBox;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.widgets.text.TextEditorState;
import haxeon.ui.widgets.text.TextEditorHistoryKind;
import haxeon.ui.widgets.text.TextEditorDiagnostics;
import haxeon.ui.widgets.text.TextArea;
import haxeon.ui.widgets.text.TextField;
import haxeon.ui.widgets.text.TextSelection;
import haxeon.ui.widgets.text.EditTransaction;
import haxeon.editor.TextDocument;
import haxeon.ui.widgets.layout.Spacer;
import haxeon.ui.widgets.controls.Slider;
import haxeon.ui.widgets.layout.Stack;
import haxeon.ui.widgets.layout.StackChild;
import haxeon.ui.widgets.controls.Spinner;
import haxeon.ui.widgets.controls.SpinnerPainter;
import haxeon.ui.widgets.controls.SpinnerKind;
import haxeon.ui.widgets.layout.SplitOrientation;
import haxeon.ui.widgets.layout.SplitSide;
import haxeon.ui.widgets.layout.SplitView;
import haxeon.ui.widgets.layout.SplitViewOptions;
import haxeon.ui.widgets.collections.TableColumn;
import haxeon.ui.widgets.collections.TableView;
import haxeon.ui.widgets.controls.Toggle;
import haxeon.ui.widgets.overlays.Tooltip;
import haxeon.ui.widgets.controls.Toolbar;
import haxeon.ui.widgets.collections.TreeView;
import haxeon.ui.widgets.collections.TreeViewModel;
import haxeon.ui.widgets.collections.TreeRootMetadata;
import haxeon.ui.widgets.text.Utf8Text;
import haxeon.ui.widgets.collections.VirtualGrid;
import haxeon.ui.widgets.collections.VirtualList;
import haxeon.ui.widgets.collections.VirtualExtentViewport;
import haxeon.ui.widgets.collections.VirtualExtentIndex;
import haxeon.ui.widgets.collections.VirtualizationPolicy;
import haxeon.ui.widgets.collections.VirtualViewport;
import haxeon.ui.widgets.WindowChrome;
import haxeon.ui.theme.Theme;
import haxeon.ui.theme.ThemeTokens;
import haxeon.ui.theme.TextRole;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.style.DecorationChain;
import haxeon.ui.style.Decoration;
import haxeon.ui.style.BackgroundDecoration;
import haxeon.ui.style.BorderDecoration;
import haxeon.ui.style.GradientDecoration;
import haxeon.ui.style.ShadowDecoration;
import haxeon.ui.style.StyleDiff;
import haxeon.ui.style.StyleResolver;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleImpact;
import haxeon.ui.style.StyleSource;
import haxeon.ui.style.StyleDiff;
import haxeon.ui.style.StyleSelector;
import haxeon.ui.style.StyleSheet;
import haxeon.ui.style.StyleSource;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleStateUtil;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleValue;
import haxeon.ui.style.EffectChain;
import haxeon.ui.style.EffectKind;
import haxeon.ui.style.BlurEffect;
import haxeon.ui.style.BrightnessEffect;
import haxeon.ui.style.ContrastEffect;
import haxeon.ui.style.SaturateEffect;
import haxeon.ui.style.HueRotateEffect;
import haxeon.ui.style.ColorMatrixEffect;
import haxeon.ui.style.DropShadowEffect;
import haxeon.ui.style.CustomEffect;
import haxeon.ui.style.CustomEffectDefinition;
import haxeon.ui.style.EffectParameter;
import haxeon.ui.style.EffectParameterType;
import haxeon.ui.style.InkOverflow;
import haxeon.ui.style.Mask;
import haxeon.ui.style.Environment;
import haxeon.ui.style.EnvironmentColorScheme;
import haxeon.ui.style.StyleEnvironment;
import haxeon.ui.gestures.GestureEvent;
import haxeon.ui.gestures.TapRecognizer;
import haxeon.ui.gestures.DoubleTapRecognizer;
import haxeon.ui.gestures.LongPressRecognizer;
import haxeon.ui.gestures.DragRecognizer;
import haxeon.ui.widgets.GestureDetector;
import haxeon.ui.widgets.controls.RadioGroup;
import haxeon.ui.widgets.controls.RadioOption;
import haxeon.ui.widgets.controls.Tabs;
import haxeon.ui.widgets.controls.TabItem;
import haxeon.ui.animation.AnimationController;
import haxeon.ui.animation.AnimationScheduler;
import haxeon.ui.animation.SpringController;
import haxeon.ui.animation.LoopAnimation;
import haxeon.ui.animation.Easing;
import haxeon.ui.debug.UiInspector;
import haxeon.ui.debug.UiFrameMetrics;
import haxeon.ui.debug.AccessibilityAudit;
import AccessibilityContract;
import haxeon.ui.host.UiHostFrameState;
import haxeon.ui.host.UiHostSession;
import haxeon.ui.host.UiHostSession.UiHostLifecycle;
import haxeon.ui.host.UiHostContext;
import haxeon.ui.host.UiHostRuntime;
import haxeon.ui.host.UiApplication;
import haxeon.ui.host.UiHostPendingResources;

class FrameworkSmoke {
	static function newlineChunksValid(fonts:FontCollection):Bool {
		var value = new StringBuf();
		for (line in 0...220)
			value.add("é🙂 x " + line + "\n");
		var editor = new TextEditorState(fonts, value.toString());
		editor.paragraphStyle.lineHeight = 24.0;
		editor.updateLayout(400.0);
		var paintedRanges:Array<Int> = [];
		editor.layout.colorRangeProvider = function(start, end) {
			paintedRanges.push(start);
			paintedRanges.push(end);
			return [];
		};
		var canvas = new Canvas();
		editor.layout.paint(canvas, new Color(1.0, 1.0, 1.0), 0.0, editor.layout.measure().height);
		var originalRanges = paintedRanges;
		canvas.reset();
		for (step in 0...7) {
			var beforeRanges = paintedRanges;
			var offsets = new haxeon.editor.TextDocument(editor.text);
			var start = step == 0 ? 0 : offsets.paragraphRangeAtIndex(step >= 3 ? 190 : 63).start;
			var end = step == 2 ? offsets.paragraphRangeAtIndex(67).start : start;
			if (step == 5) {
				var many = new StringBuf();
				for (_ in 0...140) many.add("overflow α🙂\n");
				// Exercise local splitting above the hard 128-paragraph bound.
				if (!editor.replace(start, start, many.toString()))
					throw "chunk overflow insertion was ignored";
				offsets = new haxeon.editor.TextDocument(editor.text);
				start = offsets.paragraphRangeAtIndex(190).start;
				end = start;
			}
			var inserted = step == 0 ? "\n" : (step == 2 ? "α🙂 joined\n" :
				(step == 4 ? "ordinary é🙂" : "α\nβ\n"));
			if (step == 6) {
				start = 0;
				end = offsets.codepointCount;
				inserted = "";
			}
			if (!editor.replace(start, end, inserted))
				throw "newline chunk replacement was ignored";
			var expected = new TextEditorState(fonts, editor.text);
			expected.paragraphStyle.lineHeight = 24.0;
			expected.updateLayout(400.0);
			var actualSize = editor.layout.measure();
			var expectedSize = expected.layout.measure();
			if (Math.abs(actualSize.height - expectedSize.height) > 0.001 ||
				Math.abs(actualSize.width - expectedSize.width) > 0.001)
				throw "newline chunk metrics differ from fresh layout";
			var current = new haxeon.editor.TextDocument(editor.text);
			paintedRanges = [];
			editor.layout.paint(canvas, new Color(1.0, 1.0, 1.0), 0.0, actualSize.height);
			canvas.reset();
			if (step == 0) {
				if (paintedRanges.length != originalRanges.length)
					throw "one newline repartitioned unrelated chunks";
				for (index in 0...paintedRanges.length)
					if (paintedRanges[index] != originalRanges[index] + (index == 0 ? 0 : 1))
						throw "one newline moved an unrelated chunk boundary";
			}
			if (step == 4) {
				if (paintedRanges.length != beforeRanges.length)
					throw "ordinary typing repartitioned stable chunks";
				var delta = current.codepointCount - offsets.codepointCount;
				for (index in 0...paintedRanges.length) {
					var shifted = index % 2 == 0 ? beforeRanges[index] > start : beforeRanges[index] >= start;
					if (paintedRanges[index] != beforeRanges[index] + (shifted ? delta : 0))
						throw "ordinary typing changed an unrelated chunk boundary";
				}
			}
			var rangeIndex = 0;
			while (rangeIndex < paintedRanges.length) {
				if (current.paragraphIndexAtOffset(paintedRanges[rangeIndex + 1]) -
					current.paragraphIndexAtOffset(paintedRanges[rangeIndex]) + 1 > 128)
					throw "edited chunk exceeded the paragraph bound";
				rangeIndex += 2;
			}
			for (offset in 0...current.codepointCount + 1) {
				var actual = editor.layout.caret(new TextPosition(offset, 0));
				var fresh = expected.layout.caret(new TextPosition(offset, 0));
				if (Math.abs(actual.x - fresh.x) > 0.001 || Math.abs(actual.y - fresh.y) > 0.001)
					throw "newline chunk caret differs at step " + step + " offset " + offset;
			}
			for (paragraph in 0...current.paragraphCount()) {
				var start = current.paragraphRangeAtIndex(paragraph).start;
				var actual = editor.layout.paragraphCaret(paragraph);
				var fresh = expected.layout.caret(new TextPosition(start, 0));
				if (Math.abs(actual.y - fresh.y) > 0.001 || Math.abs(actual.x - fresh.x) > 0.001 ||
					editor.layout.paragraphIndexAtY(actual.y) != paragraph)
					throw "logical paragraph geometry differs after newline edit";
			}
			expected.dispose();
		}
		editor.dispose();
		return true;
	}

	static function foregroundRangesValid(fonts:FontCollection):Bool {
		var value = new StringBuf();
		for (_ in 0...150)
			value.add("é🙂x\n");
		var editor = new TextEditorState(fonts, value.toString());
		editor.updateLayout(200.0);
		var measured = editor.layout.measure();
		var calls = 0;
		var requestedEnd = 0;
		var tint = new Color(1.0, 0.0, 0.0);
		editor.layout.colorRangeProvider = function(start, end) {
			calls++;
			requestedEnd = end;
			return [new TextColorRange(0, 600, tint)];
		};
		var canvas = new Canvas();
		editor.layout.paint(canvas, new Color(1.0, 1.0, 1.0), 0.0, 20.0);
		if (calls != 1 || requestedEnd <= 0 || requestedEnd >= 600)
			return false;
		tint = new Color(0.0, 1.0, 0.0);
		editor.layout.paint(canvas, new Color(1.0, 1.0, 1.0), 0.0, 20.0);
		var afterColors = editor.layout.measure();
		if (calls != 2 || measured.width != afterColors.width || measured.height != afterColors.height)
			return false;
		editor.layout.colorRangeProvider = function(start, end) {
			return [new TextColorRange(0, 3, tint), new TextColorRange(2, 4, tint)];
		};
		var rejected = false;
		try {
			editor.layout.paint(canvas, new Color(1.0, 1.0, 1.0), 0.0, 20.0);
		} catch (_:String) {
			rejected = true;
		}
		editor.layout.colorRangeProvider = null;
		editor.layout.paint(canvas, new Color(1.0, 1.0, 1.0), 0.0, 20.0);
		editor.dispose();
		return rejected;
	}

	static function decorationRangesValid(fonts:FontCollection):Bool {
		var emojiPath = Sys.getEnv("NKUI_TEST_EMOJI_FONT_PATH");
		var textPath = Sys.getEnv("NKUI_TEST_FONT_PATH");
		if (emojiPath == null || textPath == null)
			throw "Decoration tests require text and emoji fonts";
		var decorationFonts = FontCollection.create();
		decorationFonts.add(textPath);
		decorationFonts.add(emojiPath, FontFamily.Emoji);
		var editor = new TextEditorState(decorationFonts, "abc🙂def\nxyz");
		editor.updateLayout(200.0);
		var before = editor.layout.measure();
		var color = new Color(0.85, 0.2, 0.2);
		var background = new TextDecoration(1, 5, color, Background);
		var rects = background.rectangles(editor.layout, 0.0, 100.0);
		if (rects.length == 0 || rects[0].x <= 0.0 || rects[0].width <= 0.0)
			throw "decoration range geometry: count=" + rects.length + (rects.length == 0 ? "" : " x=" + rects[0].x + " width=" + rects[0].width);
		var line = new TextDecoration(0, 0, color, WholeLineBackground);
		var lineRects = line.rectangles(editor.layout, 0.0, 100.0);
		if (lineRects.length != 1 || lineRects[0].x != 0.0 || lineRects[0].width != 200.0)
			throw "whole-line geometry";
		var rangedLine = new TextDecoration(0, 8, color, WholeLineBackground);
		var rangedRects = rangedLine.rectangles(editor.layout, 0.0, 100.0);
		if (rangedRects.length != 1 || rangedRects[0].width != 200.0 ||
			rangedLine.rectangles(editor.layout, rangedRects[0].y + rangedRects[0].height,
				100.0).length != 0)
			throw "visible whole-line range geometry";
		var underline = new TextDecoration(1, 5, color, Underline);
		var wavy = new TextDecoration(1, 5, color, WavyUnderline);
		var canvas = new Canvas();
		background.paint(canvas, rects, 0.0, 20.0);
		line.paint(canvas, lineRects, 0.0, 20.0);
		underline.paint(canvas, rects, 0.0, 20.0);
		wavy.paint(canvas, rects, 0.0, 20.0);
		var list = DisplayList.create();
		canvas.update(list);
		if (list.info().commandCount <= 0 || editor.layout.measure().height != before.height)
			throw "decoration transaction measurement";
		list.dispose();
		canvas.reset();
		var paintCalls = 0;
		var provider = function(start:Int, end:Int):Array<TextDecoration> {
			paintCalls++;
			return [wavy];
		};
		var measurementVersion = editor.renderContent.getVersion();
		editor.configurePresentation(null, provider, 1);
		var geometry = new ResolvedLayoutItem(1, 1, 0.0, 0.0, 200.0, 100.0,
			new Rect(0.0, 0.0, 200.0, 100.0), new Rect(0.0, 0.0, 200.0, 100.0), Transform2D.identity(), 0.0);
		var painted = editor.renderContent.paint(geometry);
		var decoratedCommands = painted.info().commandCount;
		editor.renderContent.paint(geometry);
		if (paintCalls != 1) throw "unchanged presentation did not retain its display list";
		editor.configurePresentation(null, provider, 2);
		editor.renderContent.paint(geometry);
		if (paintCalls != 2 || editor.renderContent.getVersion() != measurementVersion)
			throw "presentation revision did not repaint independently of measurement";
		editor.configurePresentation(null, provider, 2);
		editor.renderContent.paint(geometry);
		if (paintCalls != 2) throw "unchanged presentation revision repainted";
		editor.configurePresentation(null, null, 3);
		if (editor.renderContent.paint(geometry).info().commandCount >= decoratedCommands ||
			editor.renderContent.getVersion() != measurementVersion || editor.layout.measure().height != before.height)
			throw "cleared presentation retained decoration commands or changed measurement";
		if (!editor.replace(0, 0, "zz"))
			throw "decoration edit application";
		var moved = new TextDecoration(3, 7, color, Underline).rectangles(editor.layout, 0.0, 100.0);
		if (moved.length == 0 || moved[0].x <= rects[0].x)
			throw "decoration geometry after edit";
		editor.dispose();
		var value = new StringBuf();
		for (_ in 0...150)
			value.add("abc\n");
		var layered = new TextEditorState(decorationFonts, value.toString());
		layered.updateLayout(200.0);
		var calls = 0;
		layered.layout.decorationProvider = function(start, end) {
			calls++;
			layered.layout.decorationProvider = null;
			return [new TextDecoration(start, start, color, WholeLineBackground)];
		};
		layered.layout.paintDecorations(canvas, true, 0.0, layered.layout.measure().height,
			0.0, 200.0);
		canvas.reset();
		layered.dispose();
		decorationFonts.dispose();
		if (calls != 3) throw "provider snapshot calls: " + calls;
		return true;
	}

	static function clickEvent(time:Float, x:Float = 10.0, button:Int = 0):haxeon.ui.core.UiEvent
		return new haxeon.ui.core.UiEvent(UiEventKind.Click, new WidgetId(90502), x, 10.0, 0.0, 0.0, button, 0, 0, null, null, 0, 0, time);

	static function viewportSelectionGeometryValid(fonts:FontCollection):Bool {
		var lines = [for (index in 0...200) "line " + index + " abc אבג 🙂 é long wrapped content"];
		var document = new TextDocument(lines.join("\n"));
		var layout = new haxeon.ui.widgets.text.TextEditorLayout(fonts, document.text, 96.0,
			new TextStyle(16.0), new ParagraphStyle(TextWrap.WordCharacter));
		var valid = true;
		for (reverse in 0...2) {
			var start = new TextPosition(reverse == 0 ? 1 : document.codepointCount - 1, 0);
			var end = new TextPosition(reverse == 0 ? document.codepointCount - 1 : 1, 0);
			var full = layout.selectionRects(start, end);
			for (bounds in [[0.0, 0.0], [0.0, 80.0], [2500.5, 2670.25], [9000.0, 9100.0], [1.0e20, 1.0e21]]) {
				var expected = full.filter(function(rect) return rect.y < bounds[1] && rect.y + rect.height > bounds[0]);
				var actual = layout.selectionRects(start, end, bounds[0], bounds[1]);
				if (actual.length != expected.length) valid = false;
				else for (index in 0...actual.length) {
					var a = actual[index], b = expected[index];
					if (Math.abs(a.x - b.x) > 0.01 || Math.abs(a.y - b.y) > 0.01 ||
						Math.abs(a.width - b.width) > 0.01 || Math.abs(a.height - b.height) > 0.01) valid = false;
				}
			}
		}
		layout.dispose();
		if (valid) Sys.println("PASS: viewport selection paint geometry matches full bidi/wrapped selection");
		return valid;
	}

	static function cachedSelectionGeometryValid(fonts:FontCollection):Bool {
		var text = "abc אבג 🙂 é xyz\nsecond line";
		var layout = TextLayout.create(fonts, text, 96.0);
		var verify = function():Bool {
			var length = new TextDocument(layout.text).codepointCount;
			layout.selectionRangeRects(new TextPosition(0, 0), new TextPosition(length, 0));
			var fresh = TextLayout.create(fonts, layout.text, layout.width, layout.textStyle, layout.paragraphStyle);
			var valid = true;
			for (reverse in 0...2) {
				var start = new TextPosition(reverse == 0 ? 1 : length - 1, 0);
				var end = new TextPosition(reverse == 0 ? length - 1 : 1, 0);
				var actual = layout.selectionRangeRects(start, end);
				var expected = fresh.selectionRangeRects(start, end);
				if (actual.length != expected.length) valid = false;
				else for (index in 0...actual.length) {
					var a = actual[index], b = expected[index];
					if (a.start != b.start || a.end != b.end || a.visualLeftIsStart != b.visualLeftIsStart ||
						Math.abs(a.x - b.x) > 0.01 || Math.abs(a.y - b.y) > 0.01 ||
						Math.abs(a.width - b.width) > 0.01 || Math.abs(a.height - b.height) > 0.01) valid = false;
				}
			}
			fresh.dispose();
			return valid;
		};
		var valid = verify();
		layout.update(text, 48.0, new TextStyle(20.0), new ParagraphStyle(TextWrap.WordCharacter));
		valid = verify() && valid;
		layout.setText("new 🙂 content with wrapping");
		valid = verify() && valid;
		layout.edit(0, 3, "changed", "changed 🙂 content with wrapping");
		valid = verify() && valid;
		layout.dispose();
		return valid;
	}

	@:access(haxeon.ui.core.TextInputBridge)
	static function main():Int {
		var originalTypography = new haxeon.ui.core.ResolvedTextStyle(
			new TextStyle(16.0), new ParagraphStyle(TextWrap.WordCharacter), Color.fromBytes(0, 0, 0));
		var mergedTypography = originalTypography.merge(new TextStyleOverride(null, 20.0, null,
			TextWrap.None, null, 0.0));
		originalTypography.textStyle.fontSize = 30.0;
		originalTypography.paragraphStyle.wrap = TextWrap.Word;
		if (mergedTypography.textStyle.fontSize != 20.0 || mergedTypography.paragraphStyle.wrap != TextWrap.None ||
			mergedTypography.paragraphStyle.lineHeight != 0.0)
			throw "Merged typography must preserve overrides and own its style values";
		var copiedTypography = mergedTypography.merge(null);
		copiedTypography.textStyle.fontSize = 24.0;
		copiedTypography.paragraphStyle.wrap = TextWrap.Word;
		if (mergedTypography.textStyle.fontSize != 20.0 || mergedTypography.paragraphStyle.wrap != TextWrap.None)
			throw "Typography copies must remain independent";
		var clickSequence = new haxeon.ui.core.PointerClickSequence();
		if (clickSequence.register("a", clickEvent(1.0)) != 1 || clickSequence.register("a", clickEvent(1.1)) != 2
			|| clickSequence.register("a", clickEvent(1.2)) != 1 || clickSequence.register("b", clickEvent(1.3)) != 1
			|| clickSequence.register("b", clickEvent(2.0)) != 1 || clickSequence.register("b", clickEvent(2.1, 30.0)) != 1
			|| clickSequence.register("b", clickEvent(2.2, 30.0, 1)) != 1 || clickSequence.register("b", clickEvent(2.3, 30.0)) != 1)
			throw "pointer double-click boundaries failed";

		if (!hostFrameLifecycleValid())
			return 270;
		if (!hostSessionLifecycleValid())
			return 271;
		if (!hostPendingResourcesValid())
			return 273;
		if (!coordinateMathValid())
			return 240;
		var anchorIndex = new VirtualExtentIndex(100, 20.0, 40.0, 200.0, 0, 0,
			2400.0);
		if (anchorIndex.totalExtent != 2400.0 || anchorIndex.indexAtOffset(200.0) != 10)
			return 260;
		for (index in 0...10)
			anchorIndex.setExtent(index, 30.0);
		if (anchorIndex.startOffset(10) != 300.0 ||
			anchorIndex.startOffset(10) + (200.0 - 200.0) != 300.0)
			return 261;
		var fontPath = Sys.getEnv("NKUI_TEST_FONT_PATH");
		if (fontPath == null)
			return 2;
		var fonts = FontCollection.create();
		fonts.add(fontPath);
		if (!cachedSelectionGeometryValid(fonts)) return 1040;
		if (!viewportSelectionGeometryValid(fonts)) return 1041;
		// Visual affinity positions name a glyph; range tags name logical insertion offsets.
		var affinityLayout = TextLayout.create(fonts, "abc", 100.0);
		var affinityStart = new TextPosition(0, 2), affinityEnd = new TextPosition(2, 2);
		if (affinityLayout.offsetFromPosition(affinityStart) != 1 ||
			affinityLayout.offsetFromPosition(affinityEnd) != 3) return 1021;
		// Warm canonical entries before querying distinct visual-affinity endpoints.
		affinityLayout.selectionRangeRects(new TextPosition(0, 0), new TextPosition(3, 0));
		var affinityRects = affinityLayout.selectionRangeRects(affinityStart, affinityEnd);
		var reversedAffinityRects = affinityLayout.selectionRangeRects(affinityEnd, affinityStart);
		if (affinityRects.length != 2 || reversedAffinityRects.length != 2) return 1022;
		var affinityCaret = affinityLayout.caret(affinityStart);
		if (Math.abs(affinityRects[0].x - affinityCaret.x) > 0.1) return 1023;
		for (index in 0...affinityRects.length) {
			var rect = affinityRects[index], reverse = reversedAffinityRects[index];
			if (rect.start != index + 1 || rect.end != index + 2 ||
				reverse.start != rect.start || reverse.end != rect.end ||
				Math.abs(reverse.x - rect.x) > 0.1 || Math.abs(reverse.width - rect.width) > 0.1)
				return 1024;
		}
		affinityLayout.dispose();
		var affinityEditor = new TextEditorState(fonts, "abc\nabc");
		affinityEditor.updateLayout(100.0);
		affinityEditor.placeCaretAt(new TextPosition(0, 2), false);
		affinityEditor.placeCaretAt(new TextPosition(6, 2), true);
		for (pass in 0...2) {
			var rects = affinityEditor.layout.selectionRangeRects(affinityEditor.anchorPosition(),
				affinityEditor.focusPosition());
			if (rects.length == 0) return 1025;
			for (rect in rects) if (rect.start < affinityEditor.selectionStart ||
				rect.end > affinityEditor.selectionEnd) return 1026;
		}
		affinityEditor.dispose();
		var boundaryText = "";
		for (_ in 0...128) boundaryText += "abc\n";
		var boundaryEditor = new TextEditorState(fonts, boundaryText + "abc");
		boundaryEditor.updateLayout(100.0);
		boundaryEditor.placeCaretAt(new TextPosition(255, 2), false);
		boundaryEditor.placeCaretAt(new TextPosition(258, 2), true);
		var boundaryRects = boundaryEditor.layout.selectionRangeRects(boundaryEditor.anchorPosition(),
			boundaryEditor.focusPosition());
		// The model retains the preceding newline; only the three visible letters have rectangles.
		if (boundaryRects.length != 3 || boundaryEditor.selectionStart != 255 ||
			boundaryEditor.selectionEnd != 259) return 1027;
		for (rect in boundaryRects) if (rect.start < 256 || rect.end > 259) return 1028;
		boundaryEditor.dispose();

		Sys.println("PASS: logical affinity range tags, reversed endpoints and chunked cache");
		if (!newlineChunksValid(fonts))
			return 310;
		if (!foregroundRangesValid(fonts))
			return 308;
		if (!decorationRangesValid(fonts))
			return 309;
		if (!hostRuntimeLifecycleValid(fonts))
			return 272;
		var rtlLayout = TextLayout.create(fonts, "א", 80.0, null,
			new ParagraphStyle(TextWrap.Word, TextAlignment.Start, null, TextDirection.Rtl));
		var rtlGeometry = rtlLayout.selectionRangeRects(new TextPosition(0, 0), new TextPosition(1, 0));
		if (rtlGeometry.length != 1 || rtlGeometry[0].visualLeftIsStart) {
			rtlLayout.dispose();
			return 276;
		}
		rtlLayout.dispose();
		var longText = new StringBuf();
		for (_ in 0...1000)
			longText.add("x");
		var clippingEditor = new TextEditorState(fonts, longText.toString());
		clippingEditor.updateLayout(100.0);
		var visibleGeometry = clippingEditor.layout.selectionRangeRects(
			new TextPosition(0, 0), new TextPosition(1000, 0), 0.0, 24.0);
		if (visibleGeometry.length == 0 || visibleGeometry.length >= 1000) {
			clippingEditor.dispose();
			return 277;
		}
		clippingEditor.dispose();
		if (Sys.getEnv("NKUI_SELECTION_TEST_ONLY") == "1") {
			fonts.dispose();
			Sys.println("PASS: selection geometry, cache invalidation, affinity, bidi and clipping");
			return 0;
		}
		var session = LayoutSession.create();
		var context = new UiContext(session, fonts);
		if (Sys.getEnv("NKUI_DRAG_TEST_ONLY") == "1") {
			SelectionDragTests.run(fonts, context);
			context.dispose();
			fonts.dispose();
			return 0;
		}
		MenuInteractionTests.run(context);
		if (!retainedStateUsageValid())
			return 305;
		if (!themeSwapChangesStyleRevision())
			return 306;
		if (!stateRevisionsTrackOwnUpdates())
			return 307;
		if (!propertyInputContrastValid(fonts))
			return 301;
		if (!defaultTextFieldContrastValid(fonts))
			return 303;
		if (!tabHierarchyValid(fonts))
			return 302;
		if (context.buildContext.fonts != fonts)
			return 30;
		if (!commandHistoryValid(context))
			return 230;
		if (!selfUpdatingLifetimeValid(context)) throw "self-updating widget lifetime regression";
		if (!transientWidgetLifetimeValid(context)) throw "transient widget lifetime regression";
		if (!externalScrollbarValid(context)) throw "external scrollbar placement or input regression";
		if (!scrollbarVisibilityValid(context)) throw "scrollbar visibility regression";
		if (!smoothScrollValid(context)) throw "smooth scrolling motion or lifetime regression";
		if (Sys.getEnv("NKUI_SCROLL_TEST_ONLY") == "1") {
			context.dispose();
			fonts.dispose();
			Sys.println("PASS: scrollbar pane hover, fade timing, reduced motion and controller lifetime");
			return 0;
		}
		if (!sidebarValid(context)) throw "sidebar registry, persistence or lazy provider regression";
		if (!dockWorkspaceValid(context))
			return 231;
		var emptyEditor = new TextEditorState(fonts, "");
		if (Utf8Text.length(emptyEditor.text) != 0)
			return 38;
		emptyEditor.dispose();
		var editor = new TextEditorState(fonts, "á🙂");
		var surrounding = editor.surroundingText(2048, 2048);
		if (surrounding.text != "á🙂" || surrounding != editor.surroundingText(2048, 2048))
			throw "unchanged surrounding text did not retain its window";
		if (Utf8Text.length(editor.text) != 3)
			return 32;
		if (Utf8Text.slice(editor.text, 0, 2) != "á")
			return 34;
		if (!editor.moveCaret(-1, false) || editor.selectionFocus != 2)
			return 35;
		if (!editor.deleteForward() || editor.text != "á")
			return 36;
		if (editor.surroundingText(2048, 2048).text != "á")
			throw "surrounding text cache retained deleted Unicode text";
		if (!editor.deleteBackward() || editor.text != "")
			return 37;
		editor.insert("hi");
		var composition = new NativeKitTextEdit(TextEditAction.Compose, "á", 2, 2,
			4, 4, 2, 4, 1, 6);
		if (!editor.applyTextEdit(composition) || editor.text != "hiá" ||
			editor.selectionEnd != 4 || editor.selectionFocusAffinity != 1 ||
			editor.compositionStart != 2 || editor.compositionEnd != 4 ||
			editor.lastEditTransaction == null ||
			editor.lastEditTransaction.historyKind != TextEditorHistoryKind.Composition)
			return 33;
		var compositionGeometry = editor.compositionRangeRects();
		if (compositionGeometry.length != 1 || compositionGeometry[0].start != 2 ||
			compositionGeometry[0].end != 4)
			return 275;
		var publishedRects:Array<Float> = [];
		var inputRects = [new TextRangeRect(0, 1, 2.0, 3.0, 4.0, 5.0)];
		haxeon.ui.core.TextInputBridge.rememberRects(inputRects, publishedRects);
		if (!haxeon.ui.core.TextInputBridge.matchesRects(inputRects, publishedRects))
			throw "Unchanged input geometry should reuse its published snapshot";
		inputRects[0] = new TextRangeRect(0, 1, 3.0, 3.0, 4.0, 5.0);
		if (haxeon.ui.core.TextInputBridge.matchesRects(inputRects, publishedRects))
			throw "Moving input geometry must invalidate the published snapshot";
		inputRects[0] = new TextRangeRect(0, 1, 2.0, 3.0, 4.0, 5.0, false);
		if (haxeon.ui.core.TextInputBridge.matchesRects(inputRects, publishedRects) ||
			haxeon.ui.core.TextInputBridge.matchesRects([], publishedRects))
			throw "Direction changes and cleared selections must be published";
		haxeon.ui.core.TextInputBridge.rememberRects(null, publishedRects);
		if (!haxeon.ui.core.TextInputBridge.matchesRects([], publishedRects))
			throw "Empty input geometry should reuse its published snapshot";
		var nativeDeleteEditor = new TextEditorState(fonts, "ab");
		var nativeDelete = new NativeKitTextEdit(TextEditAction.Delete, null, 1, 2,
			1, 1, -1, -1, 1, 2);
		if (!nativeDeleteEditor.applyTextEdit(nativeDelete) || nativeDeleteEditor.text != "a" ||
			nativeDeleteEditor.selectionFocusAffinity != 1 ||
			nativeDeleteEditor.lastEditTransaction == null ||
			nativeDeleteEditor.lastEditTransaction.historyKind != TextEditorHistoryKind.DeleteBackward)
			return 274;
		nativeDeleteEditor.dispose();
		editor.dispose();
		var provisionalEditor = new TextEditorState(fonts, "abcdefghijklmnopqrstuv");
		var unconstrained = provisionalEditor.layout.measure();
		if (unconstrained.width < 100.0 || unconstrained.height > 50.0)
			return 501;
		provisionalEditor.updateLayout(25.0);
		if (provisionalEditor.layout.measure().height < unconstrained.height * 3.0 ||
			provisionalEditor.selectionFocus != 22)
			return 502;
		provisionalEditor.dispose();
		var blinkEditor = new TextEditorState(fonts, "caret");
		blinkEditor.focused = true;
		blinkEditor.resetCaretBlink(10.0);
		if (!blinkEditor.isCaretVisible(10.49) || blinkEditor.isCaretVisible(10.5) ||
			!blinkEditor.isCaretVisible(11.0))
			return 225;
		if (Math.abs(blinkEditor.nextCaretBlinkTime(10.49) - 10.5) > 0.0001 ||
			Math.abs(blinkEditor.nextCaretBlinkTime(10.5) - 11.0) > 0.0001)
			return 304;
		blinkEditor.focused = false;
		if (blinkEditor.isCaretVisible(11.1) || blinkEditor.nextCaretBlinkTime(11.1) >= 0.0)
			return 226;
		blinkEditor.dispose();
		var editedValue = "";
		var submittedValue = "";
		var emptyField = new TextField("empty-entry", "", function(_) {}, null,
			"Empty message");
		emptyField.placeholder = "Type a message…";
		var emptyRoot = context.submit(emptyField, new LayoutFrame(256.0, 192.0));
		if (emptyRoot.semantics == null || emptyRoot.semantics.value != "" ||
			emptyRoot.children[0].children[0].layout.text != "Type a message…")
			return 39;
		var searchChange = "unchanged";
		var search = new SearchField("search", "query", function(next) searchChange = next,
			null, "Search components…");
		var searchRoot = context.submit(search, new LayoutFrame(256.0, 38.0));
		var searchIcon = searchRoot.children[0].children[0];
		var searchInputSemantics:Semantics = cast searchRoot.children[1].semantics;
		var searchClearSemantics:Semantics = cast searchRoot.children[2].semantics;
		if (searchRoot.children.length != 3 ||
			searchRoot.children[0].layout.style.width.value != 18.0 ||
			searchIcon.layout.visualKind != LayoutVisualKind.Custom ||
			searchIcon.hitTestSelf ||
			searchInputSemantics.role != AccessibilityRole.TextField ||
			searchInputSemantics.label != "Search components…" ||
			searchClearSemantics.label != "Clear search")
			return 227;
		var searchInput:ResolvedLayoutItem = cast searchRoot.children[1].resolved;
		var searchIconBounds:ResolvedLayoutItem = cast searchIcon.resolved;
		var clearButton = searchRoot.children[2];
		var clearBounds:ResolvedLayoutItem = cast clearButton.resolved;
		var clearIconBounds:ResolvedLayoutItem = cast clearButton.children[0].resolved;
		if (clearButton.children.length != 1 ||
			!near(searchIconBounds.y + searchIconBounds.height / 2.0,
				searchInput.y + searchInput.height / 2.0) ||
			!near(searchInput.y + searchInput.height / 2.0,
				clearBounds.y + clearBounds.height / 2.0) ||
			!near(clearIconBounds.y + clearIconBounds.height / 2.0,
				clearBounds.y + clearBounds.height / 2.0) ||
			!near(clearIconBounds.x + clearIconBounds.width / 2.0,
				clearBounds.x + clearBounds.width / 2.0))
			return 227;
		if (!context.accessibilityAction(searchRoot.children[2].id.value,
			AccessibilityAction.Activate, null, -1, -1, 1) || search.value != "" ||
			searchChange != "")
			return 228;
		searchRoot = context.submit(search, new LayoutFrame(256.0, 38.0));
		if (searchRoot.children.length != 2 ||
			searchRoot.children[1].children[0].children[0].layout.text != "Search components…")
			return 229;
		var field = new TextField("entry", "hello", function(next) { editedValue = next; },
			null, "Message");
		field.onSubmit = function(next) { submittedValue = next; };
		var fieldDiagnostics:Null<TextEditorDiagnostics> = null;
		field.onDiagnostics = function(next) { fieldDiagnostics = next; };
		var fieldRoot = context.submit(field, new LayoutFrame(256.0, 192.0));
		if (fieldRoot.children.length != 1 ||
			fieldRoot.children[0].layout.visualKind != LayoutVisualKind.Box ||
			fieldRoot.children[0].children.length != 1 ||
			fieldRoot.children[0].children[0].layout.visualKind != LayoutVisualKind.Text ||
			fieldRoot.children[0].children[0].layout.text != "hello" ||
			fieldRoot.children[0].children[0].layout.style.zIndex != 1)
			return 201;
		if (fieldRoot.semantics == null || fieldRoot.semantics.role != AccessibilityRole.TextField ||
			fieldRoot.semantics.label != "Message" || !fieldRoot.focusable)
			return 40;
		var fieldState:State<TextEditorState> = context.buildContext.existingState(fieldRoot.id);
		var fieldEditor:TextEditorState = cast fieldState.value;
		if (!context.focusWidget(fieldRoot.id))
			return 41;
		if (fieldDiagnostics == null || !fieldDiagnostics.focused ||
			fieldDiagnostics.selectionStart != 5 || fieldDiagnostics.selectionEnd != 5 ||
			fieldDiagnostics.caretOffset != 5 || fieldDiagnostics.caretRect == null)
			return 209;
		var applicationArrows = 0;
		for (key in [UiKey.Left, UiKey.Right, UiKey.Up, UiKey.Down]) {
			for (extend in [false, true]) {
				var modifiers = UiModifier.Control | UiModifier.Alt | (extend ? UiModifier.Shift : 0);
				var id = "test.application-arrow-" + key + "-" + modifiers;
				context.commands.register(new Command(id, "Application navigation", function() applicationArrows++,
					new Shortcut(key, modifiers)));
				context.key(UiEventKind.KeyDown, key, modifiers);
				context.commands.unregister(id);
				if (fieldEditor.selectionStart != 5 || fieldEditor.selectionEnd != 5)
					throw "application arrow chord changed text selection";
			}
		}
		if (applicationArrows != 8) throw "text field swallowed application arrow shortcuts";
		var historyDocument = new TextDocument("");
		var historyField = TextField.withDocument("field-history", historyDocument);
		var historyRoot = context.submit(historyField, new LayoutFrame(256.0, 192.0));
		var historyState:State<TextEditorState> = context.buildContext.existingState(historyRoot.id);
		var historyEditor:TextEditorState = cast historyState.value;
		if (!context.focusWidget(historyRoot.id)) throw "history field did not focus";
		var historyModifier = #if (mac || ios) UiModifier.Super #else UiModifier.Control #end;
		var leakedUndo = 0;
		context.commands.register(new Command("field-history-global-undo", "Global undo", function() leakedUndo++,
			new Shortcut(UiKey.Z, historyModifier)));
		for (letter in ["a", "b", "c"]) context.text(UiEventKind.TextInput, letter);
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier);
		if (historyDocument.text != "" || leakedUndo != 0) throw "typing did not undo as a field-local group";
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier | UiModifier.Shift);
		if (historyDocument.text != "abc") throw "shift-Z redo failed";
		historyEditor.insert(" pasted", TextEditorHistoryKind.Paste);
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier);
		if (historyDocument.text != "abc") throw "paste merged with typing history";
		context.key(UiEventKind.KeyDown, UiKey.Y, historyModifier);
		if (historyDocument.text != "abc pasted") throw "Y redo failed";
		context.key(UiEventKind.KeyDown, UiKey.Backspace, #if (mac || ios) UiModifier.Alt #else UiModifier.Control #end);
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier);
		if (historyDocument.text != "abc pasted") throw "word deletion did not undo separately";
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier);
		context.text(UiEventKind.TextInput, "!");
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier | UiModifier.Shift);
		if (historyDocument.text != "abc!") throw "new typing did not clear redo";
		historyEditor.placeCaret(1, false);
		context.text(UiEventKind.TextInput, "X");
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier);
		if (historyDocument.text != "abc!" || historyEditor.selectionFocus != 1) throw "navigation did not split typing history";
		historyField.readOnly = true;
		context.submit(historyField, new LayoutFrame(256.0, 192.0));
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier);
		if (historyDocument.text != "abc!" || leakedUndo != 0) throw "read-only undo changed text or escaped to application";
		historyDocument.replace(0, historyDocument.codepointCount, "fresh");
		historyField.readOnly = false;
		context.submit(historyField, new LayoutFrame(256.0, 192.0));
		context.key(UiEventKind.KeyDown, UiKey.Z, historyModifier);
		if (historyDocument.text != "fresh") throw "external replacement retained stale field history";
		var selectionHistory = new TextEditorState(fonts, "a🙂bc");
		selectionHistory.setAnchoredSelection(new TextSelection(3, 1));
		selectionHistory.replace(1, 3, "X");
		if (!selectionHistory.undo() || selectionHistory.text != "a🙂bc" ||
			selectionHistory.selectionAnchor != 3 || selectionHistory.selectionFocus != 1)
			throw "undo did not restore a reversed Unicode selection";
		selectionHistory.dispose();
		var compositionHistory = new TextEditorState(fonts, "");
		compositionHistory.applyTransaction(new EditTransaction(0, 0, "a", 1, 1, true, 0, 1, 0, null, TextEditorHistoryKind.Composition));
		compositionHistory.applyTransaction(new EditTransaction(0, 1, "あ", 1, 1, true, 0, 1, 0, null, TextEditorHistoryKind.Composition));
		compositionHistory.applyTransaction(new EditTransaction(0, 1, "あい", 2, 2, false, -1, -1, 0, null, TextEditorHistoryKind.Composition));
		if (!compositionHistory.undo() || compositionHistory.text != "" || !compositionHistory.redo() || compositionHistory.text != "あい")
			throw "IME composition did not undo as one edit";
		compositionHistory.dispose();
		context.commands.unregister("field-history-global-undo");
		var wordDocument = new TextDocument("café hello");
		var wordField = TextField.withDocument("word-delete-field", wordDocument);
		var wordRoot = context.submit(wordField, new LayoutFrame(256.0, 192.0));
		var wordState:State<TextEditorState> = context.buildContext.existingState(wordRoot.id);
		var wordDeleteEditor:TextEditorState = cast wordState.value;
		if (!context.focusWidget(wordRoot.id)) throw "word deletion field did not focus";
		var wordModifier = #if (mac || ios) UiModifier.Alt #else UiModifier.Control #end;
		context.key(UiEventKind.KeyDown, UiKey.Backspace, wordModifier);
		if (wordDocument.text != "café ") throw "word backspace did not delete the preceding word";
		context.key(UiEventKind.KeyDown, UiKey.Backspace);
		if (wordDocument.text != "café") throw "plain backspace stopped deleting one grapheme";
		wordDeleteEditor.placeCaret(0, false);
		context.key(UiEventKind.KeyDown, UiKey.Delete, wordModifier);
		if (wordDocument.text != "") throw "word delete did not delete Unicode text ahead";
		context.key(UiEventKind.KeyDown, UiKey.Backspace, wordModifier);
		if (wordDocument.text != "") throw "word deletion at document boundary changed text";
		wordDocument.replace(0, 0, "first last");
		context.submit(wordField, new LayoutFrame(256.0, 192.0));
		wordDeleteEditor.setSelection(0, 5);
		context.key(UiEventKind.KeyDown, UiKey.Backspace, wordModifier);
		if (wordDocument.text != " last") throw "word deletion expanded an existing selection";
		wordField.readOnly = true;
		context.submit(wordField, new LayoutFrame(256.0, 192.0));
		context.key(UiEventKind.KeyDown, UiKey.Delete, wordModifier);
		if (wordDocument.text != " last") throw "word deletion changed a read-only field";
		var sharedDocument = new TextDocument("start");
		var sharedEdit:Null<EditTransaction> = null;
		var sharedField = TextField.withDocument("shared-document-field", sharedDocument,
			function(edit) sharedEdit = edit);
		var sharedRoot = context.submit(sharedField, new LayoutFrame(256.0, 192.0));
		var sharedEditorState:State<TextEditorState> =
			context.buildContext.existingState(sharedRoot.id);
		var sharedEditor:TextEditorState = cast sharedEditorState.value;
		if (sharedEditor.text != "start" || sharedEditor.layout.text != "start")
			return 298;
		if (!context.focusWidget(sharedRoot.id))
			return 292;
		context.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
		context.text(UiEventKind.TextInput, "á🙂");
		if (sharedDocument.text != "á🙂" || sharedField.value != "" || sharedEdit == null ||
			sharedEdit.replacementStart != 0 || sharedEdit.replacementEnd != 5 ||
			sharedEdit.replacementText != "á🙂" || sharedEdit.replacedText != "start" ||
			sharedEdit.selectionEnd != 3)
			return 293;
		sharedRoot = context.submit(sharedField, new LayoutFrame(256.0, 192.0));
		var sharedSemantics:Semantics = cast sharedRoot.semantics;
		if (sharedSemantics == null || sharedSemantics.value != "á🙂" ||
			sharedSemantics.documentLength != 3)
			return 294;
		context.text(UiEventKind.TextEdit, null,
			new NativeKitTextEdit(TextEditAction.Compose, "x", 2, 2, 3, 3, 2, 3));
		if (sharedDocument.text != "áx🙂" || sharedEdit == null ||
			sharedEdit.replacementStart != 2 || sharedEdit.replacementEnd != 2 ||
			sharedEdit.replacementText != "x" || sharedEdit.replacedText != "" ||
			!sharedEdit.hasComposition || sharedEdit.compositionStart != 2 ||
			sharedEdit.compositionEnd != 3)
			return 214;
		sharedRoot = context.submit(sharedField, new LayoutFrame(256.0, 192.0));
		if (sharedEditor.layout.text != sharedDocument.text ||
			sharedEditor.compositionStart != 2 || sharedEditor.compositionEnd != 3)
			return 215;
		context.text(UiEventKind.TextEdit, null,
			new NativeKitTextEdit(TextEditAction.Commit, "x", 2, 3, 3, 3, -1, -1));
		if (sharedDocument.text != "áx🙂" || sharedEditor.compositionStart != -1)
			return 216;
		sharedDocument.replace(0, sharedDocument.codepointCount, "external update");
		context.submit(sharedField, new LayoutFrame(256.0, 192.0));
		if (sharedEditor.text != "external update" || sharedEditor.selectionEnd >
			sharedDocument.codepointCount)
			return 295;
		var controlledDocument = new TextDocument("a🙂bc");
		var controlledSelection = new TextSelection(4, 1);
		var editDelivered = false;
		var callbackOrdered = true;
		var controlledField = TextField.withDocument("controlled-selection", controlledDocument,
			function(_) { editDelivered = true; });
		controlledField.selectionProvider = function() return controlledSelection;
		controlledField.onSelectionChange = function(next) {
			if (controlledDocument.text == "ax" && !editDelivered) callbackOrdered = false;
			controlledSelection = next;
		};
		var controlledRoot = context.submit(controlledField, new LayoutFrame(256.0, 192.0));
		var controlledState:State<TextEditorState> = context.buildContext.existingState(controlledRoot.id);
		var controlledEditor:TextEditorState = cast controlledState.value;
		if (controlledEditor.selectionAnchor != 4 || controlledEditor.selectionFocus != 1)
			return 340;
		context.focusWidget(controlledRoot.id);
		context.text(UiEventKind.TextInput, "x");
		if (controlledDocument.text != "ax" || !callbackOrdered || !editDelivered ||
			controlledSelection.anchor != 2 || controlledSelection.focus != 2)
			return 341;
		context.submit(controlledField, new LayoutFrame(256.0, 192.0));
		if (controlledEditor.selectionFocus != 2) return 342;
		controlledSelection = new TextSelection(0, 0);
		context.submit(controlledField, new LayoutFrame(256.0, 192.0));
		context.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Shift);
		if (controlledSelection.anchor != 0 || controlledSelection.focus != 1) return 343;
		editDelivered = false;
		controlledField.onEditIntent = function(intent, layout) {
			switch intent {
				case Insert(text):
					controlledDocument.replace(0, controlledDocument.codepointCount, text + "!");
					controlledSelection = new TextSelection(controlledDocument.codepointCount, controlledDocument.codepointCount);
					return true;
				case _: return false;
			}
		};
		context.submit(controlledField, new LayoutFrame(256.0, 192.0));
		context.text(UiEventKind.TextInput, "🙂");
		if (controlledDocument.text != "🙂!" || editDelivered || controlledEditor.selectionFocus != 2)
			return 344;
		context.key(UiEventKind.KeyDown, UiKey.Backspace);
		if (controlledDocument.text != "🙂" || !editDelivered || controlledSelection.focus != 1)
			return 345;
		var sharedArea = TextArea.withDocument("shared-document-area",
			new TextDocument("multiline"));
		if (!sharedArea.multiline)
			return 296;
		fieldRoot = context.submit(field, new LayoutFrame(256.0, 192.0));
		if (!context.focusWidget(fieldRoot.id))
			return 297;
		fieldRoot = context.submit(field, new LayoutFrame(256.0, 192.0));
		fieldState = context.buildContext.existingState(fieldRoot.id);
		fieldEditor = cast fieldState.value;
		if (fieldRoot.children[0].children.length != 2 ||
			fieldRoot.children[0].children[1].layout.visualKind != LayoutVisualKind.Custom ||
			fieldRoot.children[0].children[1].layout.style.zIndex != 2)
			return 230;
		context.key(UiEventKind.KeyDown, UiKey.A, UiModifier.Control);
		fieldRoot = context.submit(field, new LayoutFrame(256.0, 192.0));
		if (fieldRoot.children[0].children.length != 3 ||
			fieldRoot.children[0].children[0].layout.visualKind != LayoutVisualKind.Custom ||
			fieldRoot.children[0].children[0].layout.style.zIndex != 0)
			return 231;
		context.text(UiEventKind.TextInput, "á🙂");
		if (field.value != "á🙂" || editedValue != "á🙂" || fieldEditor.selectionEnd != 3)
			return 42;
		fieldRoot = context.submit(field, new LayoutFrame(256.0, 192.0));
		context.key(UiEventKind.KeyDown, UiKey.Left);
		context.key(UiEventKind.KeyDown, UiKey.Backspace);
		if (field.value != "🙂" || fieldEditor.selectionEnd != 0)
			return 43;
		var compositionEdit = new NativeKitTextEdit(TextEditAction.Compose, "x", 1, 1,
			2, 2, 1, 2);
		context.text(UiEventKind.TextEdit, null, compositionEdit);
		if (field.value != "🙂x" || fieldEditor.compositionStart != 1 ||
			fieldEditor.compositionEnd != 2)
			return 44;
		fieldRoot = context.submit(field, new LayoutFrame(256.0, 192.0));
		if (fieldDiagnostics == null || !fieldDiagnostics.focused ||
			fieldDiagnostics.compositionStart != 1 || fieldDiagnostics.compositionEnd != 2 ||
			fieldDiagnostics.compositionText != "x" || fieldDiagnostics.caretRect == null)
			return 213;
		var commitEdit = new NativeKitTextEdit(TextEditAction.Commit, "x", 1, 2,
			2, 2, -1, -1);
		context.text(UiEventKind.TextEdit, null, commitEdit);
		if (fieldEditor.compositionStart != -1 || field.value != "🙂x")
			return 45;
		var cancelEdit = new NativeKitTextEdit(TextEditAction.SetComposition, null, 0, 0,
			2, 2, 1, 2);
		if (!fieldEditor.applyTextEdit(cancelEdit) || fieldEditor.compositionStart != 1 ||
			fieldEditor.compositionRects().length == 0 ||
			!fieldEditor.applyTextEdit(new NativeKitTextEdit(TextEditAction.FinishComposition,
				null, 0, 0, 2, 2, -1, -1)) || fieldEditor.compositionStart != -1)
			return 210;
		if (!context.accessibilityAction(fieldRoot.id.value, AccessibilityRequest.SetSelection,
			null, 0, 1, 2) || fieldEditor.selectionStart != 0 || fieldEditor.selectionEnd != 1)
			return 46;
		if (!context.accessibilityAction(fieldRoot.id.value, AccessibilityRequest.SetValue,
			"done", -1, -1, 1) || field.value != "done")
			return 47;
		fieldRoot = context.submit(field, new LayoutFrame(256.0, 192.0));
		fieldEditor = cast fieldState.value;
		if (fieldEditor.layout.selectionRects(new TextPosition(0, 0), new TextPosition(4, 0)).length == 0)
			return 48;
		var fieldTextGeometry:ResolvedLayoutItem =
			cast fieldRoot.children[0].children[1].resolved;
		var fieldY = fieldTextGeometry.y + fieldTextGeometry.height * 0.5;
		var fieldLeft = fieldTextGeometry.x + 0.5;
		var fieldRight = fieldTextGeometry.x + fieldTextGeometry.width - 0.5;
		context.pointerDown(fieldLeft, fieldY, 0);
		context.pointerMove(fieldRight, fieldY);
		context.pointerUp(fieldRight, fieldY, 0);
		if (fieldEditor.selectionStart != 0 || fieldEditor.selectionEnd <= 0 ||
			fieldEditor.selectionEnd > 4)
			return 49;
		var endCaret = fieldEditor.layout.caret(new TextPosition(4, 0));
		var endX = fieldTextGeometry.x + endCaret.x + 3.0;
		context.pointerDown(endX, fieldY, 0);
		context.pointerUp(endX, fieldY, 0);
		if (fieldEditor.selectionStart != 4 || fieldEditor.selectionEnd != 4 ||
			fieldEditor.selectionFocus != 4)
			return 98;
		var placedCaret = fieldEditor.layout.caret(fieldEditor.focusPosition());
		var caretDelta = placedCaret.x - endCaret.x;
		if (caretDelta < -0.1 || caretDelta > 0.1)
			return 104;
		var clickFrame = new LayoutFrame(256.0, 192.0);
		clickFrame.deltaSeconds = 0.1;
		fieldRoot = context.submit(field, clickFrame);
		fieldTextGeometry = cast fieldRoot.children[0].children[1].resolved;
		var wordX = fieldTextGeometry.x + fieldEditor.layout.measure().width * 0.5;
		context.pointerDown(wordX, fieldY, 0);
		context.pointerUp(wordX, fieldY, 0);
		clickFrame = new LayoutFrame(256.0, 192.0);
		clickFrame.deltaSeconds = 0.1;
		fieldRoot = context.submit(field, clickFrame);
		context.pointerDown(wordX, fieldY, 0);
		context.pointerUp(wordX, fieldY, 0);
		if (fieldEditor.selectionStart != 0 || fieldEditor.selectionEnd != 4)
			return 99;
		context.key(UiEventKind.KeyDown, UiKey.Enter);
		if (submittedValue != "done")
			return 50;

		var arabicField = new TextField("multi-arabic", "مرحبا بالعالم", null, null, "Arabic");
		var hebrewField = new TextField("multi-hebrew", "שלום עולם", null, null, "Hebrew");
		var multiFields = new Column("multi-fields", [
			new KeyedView("arabic", arabicField),
			new KeyedView("hebrew", hebrewField)
		]);
		var multiRoot = context.submit(multiFields, new LayoutFrame(320.0, 240.0));
		var arabicRoot = multiRoot.children[0];
		var hebrewRoot = multiRoot.children[1];
		var arabicState:State<TextEditorState> = context.buildContext.existingState(arabicRoot.id);
		var hebrewState:State<TextEditorState> = context.buildContext.existingState(hebrewRoot.id);
		var arabicEditor:TextEditorState = cast arabicState.value;
		var hebrewEditor:TextEditorState = cast hebrewState.value;
		var arabicLength = Utf8Text.length(arabicEditor.text);
		var hebrewLength = Utf8Text.length(hebrewEditor.text);
		arabicEditor.setSelection(0, arabicLength);
		hebrewEditor.setSelection(0, hebrewLength);
		if (arabicEditor.layout.selectionRects(new TextPosition(0, 0),
			new TextPosition(arabicLength, 0)).length == 0 ||
			hebrewEditor.layout.selectionRects(new TextPosition(0, 0),
				new TextPosition(hebrewLength, 0)).length == 0)
			return 220;
		if (!context.focusWidget(arabicRoot.id) || !context.textInput.isOwner(arabicRoot.id) ||
			!arabicEditor.focused || hebrewEditor.focused)
			return 221;
		if (!context.focusWidget(hebrewRoot.id) || !context.textInput.isOwner(hebrewRoot.id) ||
			arabicEditor.focused || !hebrewEditor.focused ||
			arabicEditor.selectionStart != 0 || arabicEditor.selectionEnd != arabicLength ||
			hebrewEditor.selectionStart != 0 || hebrewEditor.selectionEnd != hebrewLength)
			return 222;
		context.textInput.deactivate(arabicRoot.id);
		if (!context.textInput.isOwner(hebrewRoot.id))
			return 223;
		context.text(UiEventKind.TextInput, "x");
		if (arabicEditor.text != "مرحبا بالعالم" || hebrewEditor.text != "x")
			return 224;

		SelectionDragTests.run(fonts, context);
		var wordArea = new TextArea("word-navigation", "one two\nthree four");
		var wordAreaRoot = context.submit(wordArea, new LayoutFrame(256.0, 192.0));
		var wordAreaState:State<TextEditorState> = context.buildContext.existingState(wordAreaRoot.id);
		var wordEditor:TextEditorState = cast wordAreaState.value;
		if (!context.focusWidget(wordAreaRoot.id))
			return 190;
		var wordRange = wordEditor.layout.wordRangeAt(5);
		if (wordRange.start != 4 || wordRange.end != 7)
			return 191;
		var wordTextGeometry:ResolvedLayoutItem =
			cast wordAreaRoot.children[0].children[0].resolved;
		var wordStartCaret = wordEditor.layout.caret(new TextPosition(4, 0));
		var wordStartX = wordStartCaret.x;
		var wordNextX = wordEditor.layout.caret(new TextPosition(5, 0)).x;
		var wordClickX = wordTextGeometry.x + (wordStartX + wordNextX) * 0.5;
		var wordClickY = wordTextGeometry.y + wordStartCaret.y +
			(wordStartCaret.ascender + wordStartCaret.descender) * 0.5;
		context.pointerDown(wordClickX, wordClickY, 0, 0, 0, null, 1.0);
		if (wordEditor.selectionStart != wordEditor.selectionEnd ||
			wordEditor.selectionFocus < 4 || wordEditor.selectionFocus > 5)
			return 202;
		context.pointerUp(wordClickX, wordClickY, 0);
		context.pointerDown(wordClickX, wordClickY, 0, 0, 0, null, 1.1);
		if (wordEditor.selectionStart != 4 || wordEditor.selectionEnd != 7)
			return 192;
		if (wordEditor.layout.selectionRects(new TextPosition(4, 0),
			new TextPosition(7, 0)).length == 0)
			return 200;
		context.pointerUp(wordClickX, wordClickY, 0);
		context.pointerDown(wordClickX, wordClickY, 0, 0, 0, null, 1.2);
		if (wordEditor.selectionStart != 0 || wordEditor.selectionEnd != 8)
			return 193;
		context.pointerUp(wordClickX, wordClickY, 0);
		#if (mac || ios)
		wordEditor.placeCaret(4, false);
		context.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Alt);
		if (wordEditor.selectionFocus != 7)
			return 196;
		wordEditor.placeCaret(4, false);
		context.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Alt | UiModifier.Shift);
		if (wordEditor.selectionFocus != 7 || wordEditor.selectionStart != 4 ||
			wordEditor.selectionEnd != 7)
			return 195;
		wordEditor.placeCaret(7, false);
		context.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Alt | UiModifier.Shift);
		if (wordEditor.selectionFocus != 4 || wordEditor.selectionStart != 4 ||
			wordEditor.selectionEnd != 7)
			return 199;
		wordEditor.placeCaret(10, false);
		context.key(UiEventKind.KeyDown, UiKey.Up, UiModifier.Alt);
		if (wordEditor.selectionFocus != 8)
			return 197;
		wordEditor.placeCaret(1, false);
		context.key(UiEventKind.KeyDown, UiKey.Down, UiModifier.Alt);
		if (wordEditor.selectionFocus != 7)
			return 198;
		#else
		wordEditor.placeCaret(0, false);
		context.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Control);
		if (wordEditor.selectionFocus != 4 || wordEditor.selectionStart != 4 ||
			wordEditor.selectionEnd != 4)
			return 194;
		context.key(UiEventKind.KeyDown, UiKey.Right,
			UiModifier.Control | UiModifier.Shift);
		if (wordEditor.selectionFocus != 7 || wordEditor.selectionStart != 4 ||
			wordEditor.selectionEnd != 7)
			return 195;
		wordEditor.placeCaret(7, false);
		context.key(UiEventKind.KeyDown, UiKey.Left,
			UiModifier.Control | UiModifier.Shift);
		if (wordEditor.selectionFocus != 4 || wordEditor.selectionStart != 4 ||
			wordEditor.selectionEnd != 7)
			return 199;
		wordEditor.placeCaret(8, false);
		context.key(UiEventKind.KeyDown, UiKey.Up, UiModifier.Control);
		if (wordEditor.selectionFocus != 0)
			return 197;
		wordEditor.placeCaret(0, false);
		context.key(UiEventKind.KeyDown, UiKey.Down, UiModifier.Control);
		if (wordEditor.selectionFocus != 8)
			return 198;
		#end
		for (readOnly in [false, true]) {
			var pageText = [for (_ in 0...100) "abcdefghij"].join("\n");
			var pageArea = new TextArea("page-navigation-" + readOnly, pageText);
			pageArea.readOnly = readOnly;
			pageArea.pageHeightProvider = function() return 80.0;
			var pageRoot = context.submit(pageArea, new LayoutFrame(256.0, 192.0));
			var pageState:State<TextEditorState> = context.buildContext.existingState(pageRoot.id);
			var pageEditor:TextEditorState = cast pageState.value;
			if (!context.focusWidget(pageRoot.id)) throw "page navigation field did not focus";
			pageEditor.placeCaret(3, false);
			context.key(UiEventKind.KeyDown, UiKey.PageDown, 0);
			var pageEnd = pageEditor.selectionFocus;
			if (pageEnd <= 14 || pageEnd >= pageText.length || pageEnd % 11 != 3)
				throw "PageDown did not move a page while preserving the column";
			context.key(UiEventKind.KeyDown, UiKey.PageUp, 0);
			if (pageEditor.selectionFocus != 3) throw "PageUp did not return to the original line";
			context.key(UiEventKind.KeyDown, UiKey.PageDown, UiModifier.Shift);
			if (pageEditor.selectionAnchor != 3 || pageEditor.selectionFocus != pageEnd)
				throw "Shift PageDown did not extend the selection";
			context.key(UiEventKind.KeyDown, UiKey.PageUp, UiModifier.Shift);
			if (pageEditor.selectionAnchor != 3 || pageEditor.selectionFocus != 3)
				throw "Shift PageUp did not contract the selection";
			if (pageEditor.text != pageText) throw "page navigation changed document text";
		}
		var lineArea = new TextArea("visual-line-navigation", "first line\nsecond\nthird line");
		var lineRoot = context.submit(lineArea, new LayoutFrame(256.0, 192.0));
		var lineState:State<TextEditorState> = context.buildContext.existingState(lineRoot.id);
		var lineEditor:TextEditorState = cast lineState.value;
		var lineTextGeometry:ResolvedLayoutItem =
			cast lineRoot.children[0].children[0].resolved;
		lineEditor.updateLayout(lineTextGeometry.width);
		lineEditor.placeCaret(15, false);
		if (!lineEditor.moveCaretToLineBoundary(false, false) || lineEditor.selectionFocus != 11)
			return 203;
		lineEditor.placeCaret(15, false);
		if (!lineEditor.moveCaretToLineBoundary(true, false) || lineEditor.selectionFocus != 17)
			return 204;
		lineEditor.placeCaret(15, false);
		if (!lineEditor.moveCaretVertically(-1, false) ||
			lineEditor.layout.lineRangeAt(lineEditor.selectionFocus).start != 0)
			return 205;
		if (!lineEditor.moveCaretVertically(1, false) ||
			lineEditor.layout.lineRangeAt(lineEditor.selectionFocus).start != 11)
			return 206;
		lineEditor.replace(0, Utf8Text.length(lineEditor.text),
			"one\ntwo\nthree\nfour\nfive\nsix\nseven\neight");
		lineEditor.updateLayout(lineTextGeometry.width);
		lineEditor.placeCaret(Utf8Text.length(lineEditor.text), false);
		if (!lineEditor.ensureCaretVisible(30.0) || lineEditor.scrollOffsetY <= 0.0)
			return 207;
		lineEditor.placeCaret(0, false);
		if (!lineEditor.ensureCaretVisible(30.0) || lineEditor.scrollOffsetY != 0.0)
			return 208;
		lineEditor.setSelection(0, Utf8Text.length(lineEditor.text));
		if (!lineEditor.ensureCaretVisible(30.0) || lineEditor.scrollOffsetY <= 0.0)
			return 211;
		lineEditor.placeCaret(0, false);
		if (!lineEditor.ensureCaretVisible(30.0) || lineEditor.scrollOffsetY != 0.0)
			return 212;
		var keyboardArea = new TextArea("keyboard-line-navigation",
			"one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\ntwelve");
		var keyboardRoot = context.submit(keyboardArea, new LayoutFrame(256.0, 192.0));
		var keyboardState:State<TextEditorState> = context.buildContext.existingState(keyboardRoot.id);
		var keyboardEditor:TextEditorState = cast keyboardState.value;
		if (!context.focusWidget(keyboardRoot.id))
			return 214;
		keyboardEditor.placeCaret(0, false);
		context.key(UiEventKind.KeyDown, UiKey.End);
		if (keyboardEditor.selectionFocus != 3)
			return 215;
		context.key(UiEventKind.KeyDown, UiKey.Down);
		context.key(UiEventKind.KeyDown, UiKey.Home);
		if (keyboardEditor.selectionFocus != 4)
			return 216;
		keyboardEditor.placeCaret(0, false);
		for (_ in 0...12)
			context.key(UiEventKind.KeyDown, UiKey.Down);
		if (keyboardEditor.scrollOffsetY <= 0.0)
			return 217;
		context.key(UiEventKind.KeyDown, UiKey.Home, UiModifier.Control);
		if (keyboardEditor.selectionFocus != 0 || keyboardEditor.scrollOffsetY != 0.0)
			return 218;
		var clickField = new TextField("single-double-click", "first last", null,
			null, "Click selection");
		var clickFieldRoot = context.submit(clickField, new LayoutFrame(256.0, 192.0));
		var clickFieldState:State<TextEditorState> = context.buildContext.existingState(clickFieldRoot.id);
		var clickEditor:TextEditorState = cast clickFieldState.value;
		var clickTextGeometry:ResolvedLayoutItem = cast clickFieldRoot.children[0].resolved;
		var clickY = clickTextGeometry.y + clickTextGeometry.height * 0.5;
		var clickX = clickTextGeometry.x + clickTextGeometry.width - 2.0;
		var clickPosition = clickEditor.hitTest(clickX - clickTextGeometry.x,
			clickY - clickTextGeometry.y);
		var clickOffset = clickEditor.layout.offsetFromPosition(clickPosition);
		if (clickOffset != 10)
			return 105;
		context.pointerDown(clickX, clickY, 0);
		context.pointerUp(clickX, clickY, 0);
		if (clickEditor.selectionStart != 10 || clickEditor.selectionEnd != 10)
			return 106;
		var doubleClickFrame = new LayoutFrame(256.0, 192.0);
		doubleClickFrame.deltaSeconds = 0.1;
		clickFieldRoot = context.submit(clickField, doubleClickFrame);
		context.pointerDown(clickX, clickY, 0);
		context.pointerUp(clickX, clickY, 0);
		if (clickEditor.selectionStart != 6 || clickEditor.selectionEnd != 10)
			return 107;
		var areaChanged = "";
		var area = new TextArea("area-smoke", "line", function(next) { areaChanged = next; });
		var areaRoot = context.submit(area, new LayoutFrame(256.0, 192.0));
		var areaSemantics:Semantics = cast areaRoot.semantics;
		var areaGeometry:ResolvedLayoutItem = cast areaRoot.resolved;
		if ((areaSemantics.states & AccessibilityState.Multiline) == 0 || areaGeometry.height < 100.0 ||
			!context.focusWidget(areaRoot.id))
			return 62;
		context.key(UiEventKind.KeyDown, UiKey.Enter);
		if (area.value != "line\n" || areaChanged != "line\n")
			return 63;
		var alignStyle = new LayoutStyle();
		alignStyle.width = LayoutAxis.fixed(160.0);
		alignStyle.height = LayoutAxis.fixed(80.0);
		var alignRoot = context.submit(new Align("align-smoke", new Text("Centered"),
			LayoutAlignmentX.Center, LayoutAlignmentY.Center, alignStyle),
			new LayoutFrame(256.0, 192.0));
		var alignParentGeometry:ResolvedLayoutItem = cast alignRoot.resolved;
		var alignChildGeometry:ResolvedLayoutItem = cast alignRoot.children[0].resolved;
		if (alignChildGeometry.x < alignParentGeometry.x +
			(alignParentGeometry.width - alignChildGeometry.width) * 0.5 - 0.1 ||
			alignChildGeometry.x > alignParentGeometry.x +
			(alignParentGeometry.width - alignChildGeometry.width) * 0.5 + 0.1 ||
			alignChildGeometry.y < alignParentGeometry.y +
			(alignParentGeometry.height - alignChildGeometry.height) * 0.5 - 0.1 ||
			alignChildGeometry.y > alignParentGeometry.y +
			(alignParentGeometry.height - alignChildGeometry.height) * 0.5 + 0.1)
			return 51;
		var paddingStyle = new LayoutStyle();
		paddingStyle.width = LayoutAxis.fixed(100.0);
		paddingStyle.height = LayoutAxis.fixed(60.0);
		var paddingRoot = context.submit(new Padding("padding-smoke", new Text("Inset"),
			new Insets(7.0, 9.0, 11.0, 13.0), paddingStyle),
			new LayoutFrame(256.0, 192.0));
		var paddingParentGeometry:ResolvedLayoutItem = cast paddingRoot.resolved;
		var paddingChildGeometry:ResolvedLayoutItem = cast paddingRoot.children[0].resolved;
		if (paddingChildGeometry.x != paddingParentGeometry.x + 7.0 ||
			paddingChildGeometry.y != paddingParentGeometry.y + 9.0)
			return 52;
		var spacerRowStyle = new LayoutStyle();
		spacerRowStyle.width = LayoutAxis.fixed(200.0);
		spacerRowStyle.height = LayoutAxis.fixed(36.0);
		var spacerRow = new Row("spacer-row", [
			new KeyedView("left", new Text("L")),
			new KeyedView("gap", new Spacer("gap", LayoutAxis.grow(), LayoutAxis.fit())),
			new KeyedView("right", new Text("R"))
		], spacerRowStyle);
		var spacerRoot = context.submit(spacerRow, new LayoutFrame(256.0, 192.0));
		var spacerGeometry:ResolvedLayoutItem = cast spacerRoot.children[1].resolved;
		var leftTextGeometry:ResolvedLayoutItem = cast spacerRoot.children[0].resolved;
		var rightTextGeometry:ResolvedLayoutItem = cast spacerRoot.children[2].resolved;
		if (spacerGeometry.width <= 0.0 || rightTextGeometry.x <= leftTextGeometry.x)
			return 53;
		var lowerLayerClicks = 0;
		var upperLayerClicks = 0;
		var stack = new Stack("stack-smoke", [
			new StackChild("lower", new Button("Lower", null,
				function() { lowerLayerClicks++; }), 20.0, 20.0, 1),
			new StackChild("upper", new Button("Upper", null,
				function() { upperLayerClicks++; }), 20.0, 20.0, 5)
		]);
		var stackRoot = context.submit(stack, new LayoutFrame(256.0, 192.0));
		var lowerGeometry:ResolvedLayoutItem = cast stackRoot.children[0].resolved;
		var upperGeometry:ResolvedLayoutItem = cast stackRoot.children[1].resolved;
		if (lowerGeometry.x != upperGeometry.x || lowerGeometry.y != upperGeometry.y)
			return 64;
		var stackX = upperGeometry.x + 1.0;
		var stackY = upperGeometry.y + 1.0;
		context.pointerDown(stackX, stackY, 0);
		context.pointerUp(stackX, stackY, 0);
		if (lowerLayerClicks != 0 || upperLayerClicks != 1)
			return 65;
		var checkboxChanged = false;
		var checkbox = new Checkbox("check-smoke", "Remember", false,
			function(next) { checkboxChanged = next; });
		var checkboxRoot = context.submit(checkbox, new LayoutFrame(256.0, 192.0));
		var checkboxSemantics:Semantics = cast checkboxRoot.semantics;
		if (checkboxSemantics == null || checkboxSemantics.role != AccessibilityRole.Checkbox ||
			(checkboxSemantics.states & AccessibilityState.Checked) != 0 ||
			!context.focusWidget(checkboxRoot.id))
			return 54;
		context.key(UiEventKind.KeyDown, UiKey.Space);
		if (!checkbox.checked || !checkboxChanged ||
			(checkboxSemantics.states & AccessibilityState.Checked) == 0)
			return 55;
		var narrowButtonStyle = new LayoutStyle();
		narrowButtonStyle.width = LayoutAxis.fixed(88.0);
		narrowButtonStyle.height = LayoutAxis.fixed(38.0);
		var defaultButton = new Button("Selected", narrowButtonStyle);
		if (defaultButton.variant != ButtonVariant.Secondary ||
			new CommandButton("default-command", "missing-command").variant != ButtonVariant.Secondary)
			return 303;
		var narrowButtonRoot = context.submit(defaultButton,
			new LayoutFrame(256.0, 192.0));
		if (narrowButtonRoot.children[0].layout.paragraphStyle.wrap != TextWrap.None)
			return 102;
		var labeledIconButton = new Button("Search", null, null, "labeled-icon-smoke");
		labeledIconButton.leadingIcon = IconName.Search;
		var labeledIconRoot = context.submit(labeledIconButton, new LayoutFrame(256.0, 192.0));
		var labeledIconSemantics:Semantics = cast labeledIconRoot.semantics;
		if (labeledIconRoot.children.length != 2 || labeledIconSemantics == null ||
			labeledIconSemantics.label != "Search")
			return 236;
		var toggleChanged = false;
		var toggle = new Toggle("toggle-smoke", "Enabled", false,
			function(next) { toggleChanged = next; });
		var toggleRoot = context.submit(toggle, new LayoutFrame(256.0, 192.0));
		var toggleSemantics:Semantics = cast toggleRoot.semantics;
		var toggleGeometry:ResolvedLayoutItem = cast toggleRoot.resolved;
		context.pointerDown(toggleGeometry.x + toggleGeometry.width * 0.5,
			toggleGeometry.y + toggleGeometry.height * 0.5, 0);
		context.pointerUp(toggleGeometry.x + toggleGeometry.width * 0.5,
			toggleGeometry.y + toggleGeometry.height * 0.5, 0);
		if (!toggle.checked || !toggleChanged || toggleSemantics.role != AccessibilityRole.Switch ||
			(toggleSemantics.actions & AccessibilityAction.Toggle) == 0)
			return 56;
		var sliderChanged = 0.0;
		var slider = new Slider("slider-smoke", "Level", 0.5, 0.0, 1.0, 0.1,
			function(next) { sliderChanged = next; });
		var sliderRoot = context.submit(slider, new LayoutFrame(256.0, 192.0));
		var sliderSemantics:Semantics = cast sliderRoot.semantics;
		if (sliderSemantics == null || sliderSemantics.role != AccessibilityRole.Slider ||
			!context.focusWidget(sliderRoot.id))
			return 57;
		context.key(UiEventKind.KeyDown, UiKey.Right);
		if (slider.value < 0.59 || slider.value > 0.61 || sliderChanged != slider.value)
			return 58;
		if (!context.accessibilityAction(sliderRoot.id.value, AccessibilityRequest.SetValue,
			"0.8", -1, -1, 1) || slider.value < 0.79 || slider.value > 0.81)
			return 59;
		sliderRoot = context.submit(slider, new LayoutFrame(256.0, 192.0));
		var sliderGeometry:ResolvedLayoutItem = cast sliderRoot.resolved;
		var sliderY = sliderGeometry.y + sliderGeometry.height * 0.5;
		var pointerValue = 0.25;
		var sliderX = sliderGeometry.x + 10.0 + (sliderGeometry.width - 20.0) * pointerValue;
		context.pointerDown(sliderX, sliderY, 0);
		context.pointerUp(sliderX, sliderY, 0);
		if (slider.value < 0.29 || slider.value > 0.31)
			return 60;
		sliderX = sliderGeometry.x + 10.0 + (sliderGeometry.width - 20.0) * 0.25;
		context.pointerDown(sliderX, sliderY, 0);
		sliderRoot = context.submit(slider, new LayoutFrame(256.0, 192.0));
		sliderGeometry = cast sliderRoot.resolved;
		var dragX = sliderGeometry.x + 10.0 + (sliderGeometry.width - 20.0) * 0.85;
		context.pointerMove(dragX, sliderY);
		if (slider.value < 0.89 || slider.value > 0.91)
			return 100;
		context.pointerUp(dragX, sliderY, 0);
		var progressRoot = context.submit(new ProgressBar("progress-smoke", 0.75,
			0.0, 1.0, "Transfer"), new LayoutFrame(256.0, 192.0));
		var progressSemantics:Semantics = cast progressRoot.semantics;
		if (progressSemantics == null || progressSemantics.role != AccessibilityRole.ProgressBar ||
			(progressSemantics.states & AccessibilityState.ReadOnly) == 0 ||
			progressSemantics.numericValue != 0.75)
			return 61;
		var indeterminateProgress = new ProgressBar("indeterminate-progress-smoke", 0.0,
			0.0, 1.0, "Loading");
		indeterminateProgress.mode = haxeon.ui.widgets.controls.ProgressMode.Indeterminate;
		var indeterminateRoot = context.submit(indeterminateProgress,
			new LayoutFrame(256.0, 192.0));
		var indeterminateSemantics:Semantics = cast indeterminateRoot.semantics;
		if (indeterminateSemantics == null ||
			(indeterminateSemantics.states & AccessibilityState.Busy) == 0 ||
			(indeterminateSemantics.states & AccessibilityState.ReadOnly) != 0 ||
			context.animations.activeCount == 0)
			return 232;
		var imageBytes = haxe.io.Bytes.alloc(16);
		for (index in 0...16)
			imageBytes.set(index, 255);
		var image = Image.create(2, 2, ImageFormat.RGBA8, imageBytes);
		var loadedImage = Image.loadFile(Sys.getEnv("NKUI_TEST_IMAGE_PATH"), ImageFilter.Nearest);
		if (loadedImage.width != 22 || loadedImage.height != 22 ||
			loadedImage.filter != ImageFilter.Nearest)
			return 239;
		loadedImage.dispose();
		var imageRoot = context.submit(new ImageView("image-smoke", image, "Picture"),
			new LayoutFrame(256.0, 192.0));
		var imageSemantics:Semantics = cast imageRoot.semantics;
		var imageGeometry:ResolvedLayoutItem = cast imageRoot.resolved;
		if (imageSemantics.role != AccessibilityRole.Image || imageSemantics.label != "Picture" ||
			imageGeometry.width != 2.0 || imageGeometry.height != 2.0)
			return 64;
		var layeredRoot = context.submit(new LayeredImageView("layers-smoke", [
			new ImageLayer(image, 0.0, 0.0, 1.0, 1.0),
			new ImageLayer(image, 0.25, 0.25, 0.5, 0.5, 0.5)
		], "Layered picture"), new LayoutFrame(256.0, 192.0));
		var layeredSemantics:Semantics = cast layeredRoot.semantics;
		if (layeredSemantics == null || layeredSemantics.role != AccessibilityRole.Image ||
			layeredSemantics.label != "Layered picture")
			return 237;
		var nineSliceRoot = context.submit(new NineSliceView("nine-slice-smoke", image,
			1.0, 1.0, 1.0, 1.0, "Scalable frame"), new LayoutFrame(256.0, 192.0));
		var nineSliceSemantics:Semantics = cast nineSliceRoot.semantics;
		var nineSliceDecorations:DecorationChain = nineSliceRoot.computedStyle == null ? null :
			nineSliceRoot.computedStyle.get(StyleProperty.Decorations);
		var nineSliceDecorationSource:Null<StyleSource> = nineSliceRoot.computedStyle == null ? null :
			nineSliceRoot.computedStyle.source(StyleProperty.Decorations);
		if (nineSliceSemantics == null || nineSliceSemantics.role != AccessibilityRole.Image ||
			nineSliceSemantics.label != "Scalable frame" || nineSliceDecorations == null ||
			nineSliceDecorations.decorations.length != 1 || nineSliceDecorationSource == null ||
			nineSliceDecorationSource.layer != "default")
			return 238;
		var imageCanvas = new Canvas();
		var imageList = DisplayList.create();
		imageCanvas.drawImage(image, new Rect(1.0, 2.0, 20.0, 12.0));
		imageCanvas.update(imageList);
		if (imageList.info().commandCount != 1)
			return 65;
		imageList.clear();
		imageList.dispose();
		image.dispose();
		var shadowStyle = new ComputedStyle();
		shadowStyle.set(StyleProperty.ShadowColor, Color.rgba(0.05, 0.08, 0.12, 0.7), null);
		shadowStyle.set(StyleProperty.ShadowOffsetX, 2.0, null);
		shadowStyle.set(StyleProperty.ShadowOffsetY, 3.0, null);
		shadowStyle.set(StyleProperty.ShadowBlur, 9.0, null);
		shadowStyle.set(StyleProperty.ShadowSpread, 2.0, null);
		shadowStyle.set(StyleProperty.RadiusTopLeft, 3.0, null);
		shadowStyle.set(StyleProperty.RadiusTopRight, 5.0, null);
		shadowStyle.set(StyleProperty.RadiusBottomRight, 7.0, null);
		shadowStyle.set(StyleProperty.RadiusBottomLeft, 9.0, null);
		var shadowGeometry = new ResolvedLayoutItem(501, 1, 0.0, 0.0, 80.0, 40.0,
			new Rect(0.0, 0.0, 80.0, 40.0), new Rect(0.0, 0.0, 80.0, 40.0),
			Transform2D.identity(), 0.0);
		var shadowCanvas = new Canvas();
		var shadowList = DisplayList.create();
		new ShadowDecoration().paint(shadowCanvas, shadowGeometry, shadowStyle);
		shadowCanvas.update(shadowList);
		var shadowInfo = shadowList.info();
		if (shadowInfo.commandCount != 1 || shadowInfo.commandBytes != 72)
			return 240;
		shadowList.dispose();
		var canvasEvents = 0;
		var canvasView = new CanvasView("canvas-smoke", function(canvas, geometry) {
			canvas.fillRect(new Rect(0.0, 0.0, geometry.width, geometry.height),
				Color.rgba(0.3, 0.4, 0.5, 1.0));
		}, null, "Drawing region", true, CachePolicy.Raster, "canvas-static");
		canvasView.on(UiEventKind.PointerDown, function(_) { canvasEvents++; });
		var canvasRoot = context.submit(canvasView, new LayoutFrame(256.0, 192.0));
		var canvasGeometry:ResolvedLayoutItem = cast canvasRoot.resolved;
		var canvasSemantics:Semantics = cast canvasRoot.semantics;
		context.pointerDown(canvasGeometry.x + 10.0, canvasGeometry.y + 10.0, 0);
		if (canvasEvents != 1 || canvasSemantics.role != AccessibilityRole.Group ||
			canvasRoot.cachePolicy != CachePolicy.Raster)
			return 66;
		var simpleCanvas = CanvasView.simple("simple-canvas", function(canvas) {
			canvas.fillRect(new Rect(0.0, 0.0, 12.0, 12.0), Color.rgba(0.8, 0.2, 0.2, 1.0));
		}, null, "Simple drawing", true, CachePolicy.Raster, "simple-static");
		var simpleCanvasRoot = context.submit(simpleCanvas, new LayoutFrame(64.0, 64.0));
		if (simpleCanvasRoot.cachePolicy != CachePolicy.Raster)
			return 241;
		var shapePath = new PathBuilder().roundRect(0.0, 0.0, 32.0, 20.0, 4.0).build();
		var shapePaint = SolidPaint.create(Color.rgba(0.2, 0.7, 0.4, 1.0));
		var shape = Shape.fill("shape-smoke", shapePath, shapePaint, null, "Filled shape",
			true, CachePolicy.Raster, "shape-static");
		var shapeRoot = context.submit(shape, new LayoutFrame(64.0, 64.0));
		var shapeSemantics:Semantics = cast shapeRoot.semantics;
		if (shapeSemantics == null || shapeSemantics.role != AccessibilityRole.Group ||
			shapeSemantics.label != "Filled shape" || shapeRoot.cachePolicy != CachePolicy.Raster)
			return 242;
		shapePath.dispose();
		shapePaint.dispose();
		var responsiveCanvasStyle = new LayoutStyle();
		responsiveCanvasStyle.width = LayoutAxis.stretch();
		responsiveCanvasStyle.height = LayoutAxis.fixed(48.0);
		var responsiveCanvas = new CanvasView("responsive-canvas", function(canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height),
				Color.rgba(0.2, 0.4, 0.8, 1.0));
		}, responsiveCanvasStyle, "Responsive drawing");
		var responsiveCanvasRoot = context.submit(responsiveCanvas, new LayoutFrame(256.0, 80.0));
		var responsiveCanvasGeometry:ResolvedLayoutItem = cast responsiveCanvasRoot.resolved;
		if (responsiveCanvasGeometry.width != 256.0 || responsiveCanvasGeometry.height != 48.0)
			return 231;
		if (!NativeKitEventDecoderTests.run())
			return 27;
		var frame = new LayoutFrame(256.0, 192.0);
		var cycleRoot = new RenderNode(new WidgetId(0x7fffff00));
		var cycleChild = new RenderNode(new WidgetId(0x7fffff01));
		// Leaves share one empty children array, so give each node its own before writing to it directly.
		cycleRoot.add(new RenderNode(new WidgetId(0x7fffff03)));
		cycleChild.add(new RenderNode(new WidgetId(0x7fffff04)));
		cycleRoot.children.push(cycleChild);
		cycleChild.children.push(cycleRoot);
		if (cycleRoot.find(new WidgetId(0x7fffff02)) != null)
			return 105;
		var rejectedBoxPaint = false;
		try {
			new RenderNode(new WidgetId(0x7fffff03), LayoutVisualKind.Box)
				.onPaint(function(_, _) {});
		} catch (_:Dynamic) {
			rejectedBoxPaint = true;
		}
		if (!rejectedBoxPaint)
			return 228;
		var clicks = 0;
		var suppressNextClick = false;
		var bubbled = 0;
		var captured = 0;
		var scrollEvents = 0;
		var keyEvents = 0;
		var repeatEvents = 0;
		var hoverEnters = 0;
		var hoverLeaves = 0;
		var cancelEvents = 0;
		var focusLostEvents = 0;
		var blurEvents = 0;
		var touchPressure = 0.0;
		var committedText = "";
		var editSeen = false;

		function makeView(buttonEnabled:Bool = true):Column {
			var style = new LayoutStyle();
			style.width = LayoutAxis.fixed(256.0);
			style.height = LayoutAxis.fixed(192.0);
			var button = new Button("Increment", null, function() {
				clicks++;
			});
			button.enabled = buttonEnabled;
			return new Column("main", [
				new KeyedView("increment", button),
				new KeyedView("next", new Button("Next")),
				new KeyedView("status", new Text("Ready", null, Color.rgba(1.0, 1.0, 1.0, 1.0)))
			], style);
		}

		var root = context.submit(makeView(true), frame);
		if (context.isDirty())
			root = context.submit(makeView(true), frame);
		root.on(UiEventKind.Click, function(_) {
			bubbled++;
		});
		root.on(UiEventKind.Click, function(_) {
			captured++;
		}, "capture");
		root.on(UiEventKind.PointerDown, function(event) {
			if (suppressNextClick) {
				event.preventDefault();
				event.stopPropagation();
			}
		}, "capture");
		var buttonNode = root.children[0];
		var initialId = buttonNode.id;
		root.hitTestBehavior = HitTestBehavior.ChildrenOnly;
		if (HitTest.path(root, 4.0, 4.0).length < 2)
			return 241;
		root.hitTestBehavior = HitTestBehavior.SelfOnly;
		if (HitTest.path(root, 4.0, 4.0).length != 1)
			return 242;
		root.hitTestBehavior = HitTestBehavior.None;
		if (HitTest.path(root, 4.0, 4.0).length != 0)
			return 243;
		root.hitTestBehavior = HitTestBehavior.Auto;
		var state:State<Int> = context.buildContext.state(buttonNode.id, 0);
		if (root.children.length != 3 || buttonNode.resolved == null ||
			!buttonNode.focusable || !buttonNode.resolved.hitTest(4.0, 4.0) || context.isDirty())
			return 3;
		if (context.dirtyFlags != UiDirtyFlag.None)
			return 221;
		var rootLocalX = -1.0;
		var buttonLocalX = -1.0;
		root.on(UiEventKind.PointerDown, function(event) {
			if (event.data == "coordinate-test")
				rootLocalX = event.localX;
		}, "capture");
		buttonNode.on(UiEventKind.PointerDown, function(event) {
			if (event.data == "coordinate-test") {
				buttonLocalX = event.localX;
				event.preventDefault();
			}
		});
		var coordinatePoint = new Point(6.0, 7.0);
		var coordinateGlobal = buttonNode.localToGlobal(coordinatePoint);
		context.pointerDown(coordinateGlobal.x, coordinateGlobal.y, 0, 0, 0, "coordinate-test");
		context.pointerUp(coordinateGlobal.x, coordinateGlobal.y, 0, 0, 0, "coordinate-test");
		var expectedRootPoint = root.globalToLocal(coordinateGlobal);
		if (!near(rootLocalX, expectedRootPoint.x) || !near(buttonLocalX, coordinatePoint.x) ||
			!near(coordinateGlobal.x, buttonNode.localToGlobal(coordinatePoint).x))
			return 244;
		var semanticTree = AccessibilityBridge.project(root, buttonNode.id);
		if (semanticTree.length != 3 || semanticTree[0].id != buttonNode.id.value ||
			semanticTree[0].parentId != 0 || semanticTree[0].role != AccessibilityRole.Button ||
			(semanticTree[0].states & (AccessibilityState.Focusable | AccessibilityState.Focused)) !=
			(AccessibilityState.Focusable | AccessibilityState.Focused) ||
			(semanticTree[0].actions & AccessibilityAction.Activate) == 0 ||
			semanticTree[0].semantics.label != "Increment")
			return 25;

		context.pointerDown(4.0, 4.0, 0);
		context.pointerUp(4.0, 4.0, 0);
		if (clicks != 1 || bubbled != 1 || captured != 1 || context.focus.focusedId == null ||
			!context.focus.focusedId.equals(initialId))
			return 4;
		suppressNextClick = true;
		context.pointerDown(4.0, 4.0, 0);
		context.pointerUp(4.0, 4.0, 0);
		if (clicks != 1 || bubbled != 1 || captured != 1)
			return 254;
		state.update(7);
		if (!context.isDirty() || !UiDirtyFlag.contains(context.dirtyFlags, UiDirtyFlag.NeedsBuild) ||
			!UiDirtyFlag.contains(context.dirtyFlags, UiDirtyFlag.NeedsLayout))
			return 5;

		root = context.submit(makeView(true), frame);
		buttonNode = root.children[0];
		var restored = context.buildContext.state(buttonNode.id, 99);
		if (!buttonNode.id.equals(initialId) || restored.value != 7 ||
			context.focus.focusedId == null || !context.focus.focusedId.equals(initialId))
			return 6;

		buttonNode.on(UiEventKind.Scroll, function(_) {
			scrollEvents++;
		});
		buttonNode.on(UiEventKind.KeyDown, function(event) {
			if (event.key == UiKey.Enter && event.scancode == 28)
				keyEvents++;
		});
		buttonNode.on(UiEventKind.KeyRepeat, function(_) {
			repeatEvents++;
		});
		buttonNode.on(UiEventKind.HoverEnter, function(_) {
			hoverEnters++;
		});
		buttonNode.on(UiEventKind.HoverLeave, function(_) {
			hoverLeaves++;
		});
		buttonNode.on(UiEventKind.PointerDown, function(event) {
			if (event.pointerId != 0 && event.data != null) {
				var touchData:UiTouchData = cast event.data;
				touchPressure = touchData.pressure;
			}
		});
		buttonNode.on(UiEventKind.PointerCancel, function(_) {
			cancelEvents++;
		});
		buttonNode.on(UiEventKind.FocusLost, function(_) {
			focusLostEvents++;
		});
		buttonNode.on(UiEventKind.Blur, function(_) {
			blurEvents++;
		});
		buttonNode.on(UiEventKind.TextInput, function(event) {
			committedText = event.text;
		});
		buttonNode.on(UiEventKind.TextEdit, function(event) {
			editSeen = event.data != null && event.text == "compose";
		});
		var source = new Handle(17);
		var surface = new Handle(19);
		var input = new NativeInputAdapter(context, source, surface);
		var eventRuntime = NativeKitRuntime.start();
		var eventPump = eventRuntime.events;
		var pumpEvents = 0;
		var pumpSubscription = eventPump.listen(function(_) { pumpEvents++; });
		input.attach(eventPump);
		input.attach(eventPump);
		eventPump.dispatch(PointerMove(source, 4.0, 4.0));
		if (pumpEvents != 1 || hoverEnters != 0 || context.events.hoveredId() == null ||
			!context.events.hoveredId().equals(initialId))
			return 101;
		input.detach();
		eventPump.dispatch(PointerEnter(source, false));
		if (pumpEvents != 2 || hoverLeaves != 0)
			return 102;
		pumpSubscription.dispose();
		eventPump.dispatch(PointerMove(source, 5.0, 5.0));
		if (pumpEvents != 2 || !pumpSubscription.isDisposed())
			return 103;
		eventRuntime.dispose();
		if (!eventPump.isDisposed())
			return 104;
		var pastedText = "";
		var clipboardRequestInt = 49;
		var clipboardRequest:haxe.Int64 = clipboardRequestInt;
		context.clipboard.trackRead(clipboardRequest, function(text) {
			pastedText = text;
		});
		if (!input.consume(ClipboardText(clipboardRequest, Result.Ok, "from clipboard")) ||
			pastedText != "from clipboard" ||
			input.consume(ClipboardText(clipboardRequest, Result.Ok, "duplicate")))
			return 39;
		if (input.consume(PointerMove(new Handle(18), 4.0, 4.0)))
			return 12;
		if (!input.consume(PointerMove(source, 4.0, 4.0)) || hoverEnters != 0 ||
			!input.consume(PointerScroll(source, 1.5, -24.0)) || scrollEvents != 1)
			return 13;
		input.coordinateScale = 2;
		var scaledBounds = buttonNode.globalBounds();
		var scaledX = (scaledBounds.x + scaledBounds.width * 0.75) * 2;
		var scaledY = (scaledBounds.y + scaledBounds.height * 0.75) * 2;
		if (!input.consume(PointerButton(source, 0, InputAction.Press, 0, scaledX, scaledY)) ||
			!input.consume(PointerButton(source, 0, InputAction.Release, 0, scaledX, scaledY)) || clicks != 2)
			return 14;
		input.coordinateScale = 1;
		if (!input.consume(Key(source, UiKey.Enter, 28, InputAction.Press, 0)) ||
			!input.consume(Key(source, UiKey.Enter, 28, InputAction.Repeat, 0)) ||
			keyEvents != 1 || repeatEvents != 1 || clicks != 3)
			return 15;
		var nextId = root.children[1].id;
		if (!input.consume(Key(source, UiKey.Tab, 15, InputAction.Press, 0)) ||
			context.focus.focusedId == null || !context.focus.focusedId.equals(nextId) ||
			!input.consume(Key(source, UiKey.Tab, 15, InputAction.Repeat, 0)) ||
			context.focus.focusedId == null || !context.focus.focusedId.equals(initialId) ||
			!input.consume(Key(source, UiKey.Tab, 15, InputAction.Repeat, 0)) ||
			context.focus.focusedId == null || !context.focus.focusedId.equals(nextId) ||
			!input.consume(Key(source, UiKey.Tab, 15, InputAction.Press, UiModifier.Shift)) ||
			context.focus.focusedId == null || !context.focus.focusedId.equals(initialId) ||
			!input.consume(Key(source, UiKey.Tab, 15, InputAction.Repeat, UiModifier.Shift)) ||
			context.focus.focusedId == null || !context.focus.focusedId.equals(nextId) ||
			!input.consume(Key(source, UiKey.Tab, 15, InputAction.Repeat, UiModifier.Shift)) ||
			context.focus.focusedId == null || !context.focus.focusedId.equals(initialId))
			return 24;
		if (!input.consume(TextInput(source, 0x1f642)) || committedText != "🙂")
			return 16;
		var edit = new NativeKitTextEdit(TextEditAction.Compose, "compose", 0, 0,
			0, 0, 0, 7);
		if (input.consume(TextEdit(new Handle(20), edit)) || editSeen ||
			!input.consume(TextEdit(source, edit)) || !editSeen)
			return 17;
		editSeen = false;
		if (!input.consume(TextEdit(surface, edit)) || !editSeen)
			return 17;
		if (!input.consume(PointerEnter(source, false)) || hoverLeaves == 0)
			return 18;
		if (!input.consume(Touch(source, 3, TouchAction.Begin, TouchTool.Finger,
			0, 4.0, 4.0, 0.75, 0.0, 0.0)) ||
			!input.consume(Touch(source, 3, TouchAction.End, TouchTool.Finger,
			0, 4.0, 4.0, 0.0, 0.0, 0.0)) || clicks != 4 || touchPressure != 0.75)
			return 19;
		input.consume(Touch(source, 4, TouchAction.Begin, TouchTool.Finger,
			0, 4.0, 4.0, 0.5, 0.0, 0.0));
		input.consume(Touch(source, 4, TouchAction.Cancel, TouchTool.Finger,
			0, 4.0, 4.0, 0.0, 0.0, 0.0));
		if (cancelEvents != 1 || clicks != 4)
			return 20;
		input.consume(WindowStateChanged(source, 0));
		if (focusLostEvents != 1 || blurEvents != 4 || context.focus.focusedId != null)
			return 21;

		context.clearFocus();
		context.focusNext();
		if (context.focus.focusedId == null || !context.focus.focusedId.equals(initialId))
			return 7;
		context.focusNext();
		if (context.focus.focusedId == null || !context.focus.focusedId.equals(nextId))
			return 22;
		context.focusPrevious();
		if (context.focus.focusedId == null || !context.focus.focusedId.equals(initialId))
			return 23;
		context.pointerDown(4.0, 4.0, 0);
		context.pointerUp(500.0, 500.0, 0);
		if (clicks != 4)
			return 8;
		if (!context.accessibilityAction(initialId.value, 1, null, -1, -1, 1) || clicks != 5)
			return 28;
		if (!context.accessibilityAction(initialId.value, 2, null, -1, -1, 1) ||
			context.focus.focusedId == null || !context.focus.focusedId.equals(initialId) ||
			!context.accessibilityAction(initialId.value, 3, null, -1, -1, 1) ||
			context.focus.focusedId != null)
			return 29;
		var moveModifiers = -1;
		var wheelModifiers = -1;
		buttonNode.on(UiEventKind.PointerMove, function(event) moveModifiers = event.modifiers);
		buttonNode.on(UiEventKind.Scroll, function(event) wheelModifiers = event.modifiers);
		input.consume(Key(source, 340, 0, InputAction.Press, 0));
		input.consume(PointerMove(source, 4.0, 4.0));
		input.consume(PointerScroll(source, 0, -40));
		if (moveModifiers != UiModifier.Shift || wheelModifiers != UiModifier.Shift)
			throw "modifier press must affect subsequent move and wheel events";
		input.consume(Key(source, 344, 0, InputAction.Press, UiModifier.Shift));
		input.consume(Key(source, 340, 0, InputAction.Release, UiModifier.Shift));
		input.consume(PointerScroll(source, 0, -40));
		if (wheelModifiers != UiModifier.Shift)
			throw "releasing one Shift must preserve the other Shift";
		input.consume(Key(source, 344, 0, InputAction.Release, UiModifier.Shift));
		input.consume(PointerScroll(source, 0, -40));
		if (wheelModifiers != 0) throw "modifier release snapshot must not leave Shift stuck";
		input.consume(Key(source, UiKey.A, 0, InputAction.Press, UiModifier.Control | UiModifier.Alt));
		input.consume(Key(new Handle(18), UiKey.A, 0, InputAction.Press, 0));
		input.consume(PointerMove(source, 4.0, 4.0));
		if (moveModifiers != (UiModifier.Control | UiModifier.Alt))
			throw "foreign window must not change pointer modifiers";
		input.consume(WindowStateChanged(source, 0));
		input.consume(PointerScroll(source, 0, -40));
		if (wheelModifiers != 0) throw "focus loss must clear pointer modifiers";
		input.consume(Key(source, 341, 0, InputAction.Press, 0));
		input.detach();
		input.consume(PointerScroll(source, 0, -40));
		if (wheelModifiers != 0) throw "detach must clear pointer modifiers";
		var sameTargetHandlers = 0;
		var immediateTargetHandlers = 0;
		var parentHandlers = 0;
		var eventStyle = new LayoutStyle();
		eventStyle.width = LayoutAxis.fixed(256.0);
		eventStyle.height = LayoutAxis.fixed(192.0);
		var eventRootView = new Column("event-semantics", [
			new KeyedView("stop", new Button("Stop propagation")),
			new KeyedView("immediate", new Button("Stop immediate"))
		], eventStyle);
		var eventRoot = context.submit(eventRootView, frame);
		var stopNode = eventRoot.children[0];
		var immediateNode = eventRoot.children[1];
		stopNode.on(UiEventKind.Click, function(event) {
			event.stopPropagation();
		}, "target");
		stopNode.on(UiEventKind.Click, function(_) {
			sameTargetHandlers++;
		}, "target");
		immediateNode.on(UiEventKind.Click, function(event) {
			event.stopImmediatePropagation();
		}, "target");
		immediateNode.on(UiEventKind.Click, function(_) {
			immediateTargetHandlers++;
		}, "target");
		eventRoot.on(UiEventKind.Click, function(_) {
			parentHandlers++;
		});
		var stopGeometry:ResolvedLayoutItem = cast stopNode.resolved;
		context.pointerDown(stopGeometry.x + 2.0, stopGeometry.y + 2.0, 0);
		context.pointerUp(stopGeometry.x + 2.0, stopGeometry.y + 2.0, 0);
		var immediateGeometry:ResolvedLayoutItem = cast immediateNode.resolved;
		context.pointerDown(immediateGeometry.x + 2.0, immediateGeometry.y + 2.0, 0);
		context.pointerUp(immediateGeometry.x + 2.0, immediateGeometry.y + 2.0, 0);
		if (sameTargetHandlers != 1 || immediateTargetHandlers != 0 || parentHandlers != 0)
			return 223;

		var sharedStyle = new LayoutStyle();
		new Row("style-copy", [], sharedStyle);
		if (sharedStyle.direction != LayoutDirection.TopToBottom)
			return 9;

		root = context.submit(makeView(false), frame);
		buttonNode = root.children[0];
		semanticTree = AccessibilityBridge.project(root, null);
		if ((semanticTree[0].states & AccessibilityState.Disabled) == 0)
			return 26;
		if (context.focus.focusedId != null || context.focusWidget(buttonNode.id))
			return 10;
		context.pointerDown(4.0, 4.0, 0);
		context.pointerUp(4.0, 4.0, 0);
		if (clicks != 5 || context.accessibilityAction(buttonNode.id.value, 1, null, -1, -1, 1))
			return 11;

		var viewportStyle = new LayoutStyle();
		viewportStyle.width = LayoutAxis.fixed(256.0);
		viewportStyle.height = LayoutAxis.fixed(80.0);
		var longContentStyle = new LayoutStyle();
		longContentStyle.width = LayoutAxis.fixed(256.0);
		longContentStyle.height = LayoutAxis.fixed(400.0);
		var scrollView = new ScrollView("demo-scroll", new Column("long-content", [
			new KeyedView("message", new Button("Scrollable content"))
		], longContentStyle), viewportStyle, ScrollAxis.Vertical);
		var scrollFrame = new LayoutFrame(256.0, 80.0);
		var scrollRoot = context.submit(scrollView, scrollFrame);
		var contentGeometry:ResolvedLayoutItem = cast scrollRoot.children[0].resolved;
		if (scrollView.controller.maxScrollY != 320.0 || contentGeometry == null ||
			contentGeometry.clipBounds.height != 80.0)
			return 25;
		// Scrollbar geometry must match the new viewport on the first resize frame.
		scrollRoot = context.submit(scrollView, scrollFrame);
		scrollView.style.height = LayoutAxis.fixed(160.0);
		scrollRoot = context.submit(scrollView, new LayoutFrame(256.0, 160.0));
		var resizedTrack:ResolvedLayoutItem = cast scrollRoot.children[1].resolved;
		if (scrollView.controller.viewportHeight != 160.0 || resizedTrack.height != 156.0)
			return 249;
		// A changed window frame must also invalidate native layout without a style edit.
		scrollView.style.height = LayoutAxis.grow();
		scrollRoot = context.submit(scrollView, scrollFrame);
		scrollRoot = context.submit(scrollView, new LayoutFrame(256.0, 160.0));
		resizedTrack = cast scrollRoot.children[1].resolved;
		if (scrollView.controller.viewportHeight != 160.0 || resizedTrack.height != 156.0)
			return 250;
		scrollView.style.height = LayoutAxis.fixed(80.0);
		scrollRoot = context.submit(scrollView, scrollFrame);
		context.scroll(4.0, 4.0, 0.0, 50.0);
		if (scrollView.controller.offsetY != 50.0 || !context.isDirty())
			return 26;
		scrollRoot = context.submit(scrollView, scrollFrame);
		contentGeometry = cast scrollRoot.children[0].resolved;
		if (contentGeometry.transform.ty != -50.0)
			return 27;
		var nestedScrollControl = scrollRoot.children[0].children[0].children[0];
		nestedScrollControl.on(UiEventKind.KeyDown, function(event) {
			if (event.key == UiKey.Down)
				event.preventDefault();
		});
		if (!context.focusWidget(nestedScrollControl.id))
			return 229;
		context.key(UiEventKind.KeyDown, UiKey.Down);
		if (scrollView.controller.offsetY != 50.0)
			return 230;
		scrollView.controller.jumpTo(0.0, 500.0);
		if (scrollView.controller.offsetY != 320.0 || !context.isDirty())
			return 28;
		scrollRoot = context.submit(scrollView, scrollFrame);
		if (scrollRoot.children.length != 2 || scrollRoot.children[1].children.length != 1)
			return 242;
		var scrollbarThumb = scrollRoot.children[1].children[0];
		var scrollbarSemantics:Semantics = cast scrollbarThumb.semantics;
		if (scrollbarSemantics.role != AccessibilityRole.Slider ||
			scrollbarSemantics.numericValue != 320.0 ||
			scrollbarSemantics.numericMaximum != 320.0 ||
			!context.accessibilityAction(scrollbarThumb.id.value,
				AccessibilityRequest.Decrement, null, -1, -1, 1) ||
			scrollView.controller.offsetY >= 320.0)
			return 243;
		var scrollbarTrack:ResolvedLayoutItem = cast scrollRoot.children[1].resolved;
		context.pointerDown(scrollbarTrack.x + scrollbarTrack.width * 0.5,
			scrollbarTrack.y + 4.0, 0);
		context.pointerUp(scrollbarTrack.x + scrollbarTrack.width * 0.5,
			scrollbarTrack.y + 4.0, 0);
		if (scrollView.controller.offsetY != 0.0)
			return 246;
		// Keep a captured thumb responsive when a resize clamps the old offset.
		scrollView.controller.jumpTo(0.0, 320.0);
		scrollRoot = context.submit(scrollView, scrollFrame);
		var heldThumb:ResolvedLayoutItem = cast scrollRoot.children[1].children[0].resolved;
		var heldX = heldThumb.x + heldThumb.width * 0.5;
		var heldY = heldThumb.y + heldThumb.height * 0.5;
		context.pointerDown(heldX, heldY, 0);
		scrollView.style.height = LayoutAxis.fixed(160.0);
		scrollRoot = context.submit(scrollView, new LayoutFrame(256.0, 160.0));
		context.pointerMove(heldX, heldY - 2.0);
		if (scrollView.controller.offsetY >= 240.0 || scrollView.controller.offsetY < 230.0)
			return 270;
		context.pointerUp(heldX, heldY - 2.0, 0);
		scrollView.style.height = LayoutAxis.fixed(80.0);
		scrollRoot = context.submit(scrollView, scrollFrame);
		scrollView.controller.jumpTo(0.0, 160.0);
		if (!context.focusWidget(scrollRoot.id))
			return 244;
		context.key(UiEventKind.KeyDown, UiKey.Home);
		if (scrollView.controller.offsetY != 0.0)
			return 245;
		var shortViewportStyle = new LayoutStyle();
		shortViewportStyle.width = LayoutAxis.fixed(256.0);
		shortViewportStyle.height = LayoutAxis.fixed(300.0);
		var shortContentStyle = new LayoutStyle();
		shortContentStyle.width = LayoutAxis.fixed(256.0);
		shortContentStyle.height = LayoutAxis.fixed(100.0);
		var shortScroll = new ScrollView("short-scroll", new Column("short-content", [
			new KeyedView("message", new Text("Short content"))
		], shortContentStyle), shortViewportStyle);
		context.submit(shortScroll, new LayoutFrame(256.0, 300.0));
		shortScroll.style.height = LayoutAxis.fixed(200.0);
		var shortRoot = context.submit(shortScroll, new LayoutFrame(256.0, 200.0));
		var shortTrack:ResolvedLayoutItem = cast shortRoot.children[1].resolved;
		if (shortScroll.controller.maxScrollY != 0.0 || shortTrack.visible)
			return 269;
		var ownedFirst = new ScrollController(0.0, 40.0);
		var ownedFirstView = new ScrollView("owned-scroll", new Column("owned-content", [], longContentStyle),
			viewportStyle, ScrollAxis.Vertical, ownedFirst);
		context.submit(ownedFirstView, scrollFrame);
		var ownedReplacement = new ScrollController(0.0, 90.0);
		var ownedReplacementView = new ScrollView("owned-scroll", new Column("owned-content", [], longContentStyle),
			viewportStyle, ScrollAxis.Vertical, ownedReplacement);
		context.submit(ownedReplacementView, scrollFrame);
		if (ownedFirstView.controller != ownedFirst || ownedReplacementView.controller != ownedReplacement ||
			ownedFirst.offsetY != 40.0 || ownedReplacement.offsetY != 90.0) return 1101;
		var emptyViewport = new VirtualViewport(0, 32.0, 350.0, 0.0);
		var topViewport = new VirtualViewport(100000, 32.0, 350.0, 0.0);
		var middleViewport = new VirtualViewport(100000, 32.0, 350.0, 414.0 * 32.0);
		var bottomViewport = new VirtualViewport(100000, 32.0, 350.0, 100000.0 * 32.0);
		if (emptyViewport.count != 0 || topViewport.first != 0 || topViewport.last != 12 ||
			!topViewport.contains(0) || topViewport.contains(12) ||
			middleViewport.first != 413 || middleViewport.last != 426 ||
			bottomViewport.first != 99988 || bottomViewport.last != 100000 ||
			!bottomViewport.contains(99999) || bottomViewport.contains(99987))
			return 247;
		var extentViewport = new VirtualExtentViewport([40.0, 80.0, 120.0, 60.0],
			120.0, 120.0);
		var extentAtEnd = new VirtualExtentViewport([40.0, 80.0, 120.0, 60.0],
			120.0, 1000.0);
		var policy = new VirtualizationPolicy(2, 3);
		var policyFixed = policy.fixed(100000, 32.0, 350.0, 414.0 * 32.0);
		var policyVariable = policy.variable([40.0, 80.0, 120.0, 60.0], 120.0, 120.0);
		if (extentViewport.totalExtent != 300.0 || extentViewport.first != 1 ||
			extentViewport.last != 4 || extentViewport.startOffset(2) != 120.0 ||
			extentViewport.count != 3 || extentAtEnd.offset != 180.0 ||
			!extentAtEnd.contains(3) || policyFixed.first != 412 || policyFixed.last != 428 ||
			policyVariable.first != 0 || policyVariable.last != 4 || !policy.recycleSlots)
			return 253;
		var gridController = new ScrollController();
		var gridStyle = new LayoutStyle();
		gridStyle.width = LayoutAxis.fixed(240.0);
		gridStyle.height = LayoutAxis.fixed(160.0);
		var builtCells:Array<String> = [];
		var virtualGrid = new VirtualGrid("grid-smoke", 1000, 100, 24.0, 80.0,
			function(row, column) {
				builtCells.push('$row:$column');
				return new Text('Cell $row,$column');
			}, gridStyle, null, gridController, 240.0, 160.0);
		var gridRoot = context.submit(virtualGrid, new LayoutFrame(240.0, 160.0));
		var gridSemantics:Semantics = cast gridRoot.semantics;
		if (gridSemantics.role != AccessibilityRole.Grid || gridSemantics.rowCount != 1000 ||
			gridSemantics.columnCount != 100 || builtCells.length == 0 || builtCells.length > 64)
			return 248;
		gridController.jumpTo(40.0 * 80.0, 500.0 * 24.0);
		builtCells.resize(0);
		gridRoot = context.submit(virtualGrid, new LayoutFrame(240.0, 160.0));
		if (builtCells.length == 0 || builtCells.length > 64)
			return 249;
		if (builtCells[0] != "499:39")
			return 250;
		var tableColumns:Array<TableColumn> = [
			new TableColumn("id", "ID", 60.0),
			new TableColumn("name", "Name", 100.0),
			new TableColumn("state", "State", 80.0)
		];
		var tableStyle = new LayoutStyle();
		tableStyle.width = LayoutAxis.fixed(240.0);
		tableStyle.height = LayoutAxis.fixed(184.0);
		var tableBuiltCells:Array<String> = [];
		var tableSelection = -1;
		var tableCellSelection = -1;
		var tableSortColumn = -1;
		var tableSortAscending = false;
		var tableResizeColumn = -1;
		var tableResizeWidth = 0.0;
		var table = new TableView("table-smoke", 100000, tableColumns, 24.0, function(row, column) {
			tableBuiltCells.push('$row:${column.key}');
			return new Text('$row ${column.label}');
		}, tableStyle, null, null, 240.0, 184.0, 24.0, 2, function(row:Int) {
			tableSelection = row;
		}, 0, function(row:Int, column:Int) {
			tableCellSelection = row * 10 + column;
		}, function(column:Int, ascending:Bool) {
			tableSortColumn = column;
			tableSortAscending = ascending;
		}, function(column:Int, width:Float) {
			tableResizeColumn = column;
			tableResizeWidth = width;
		});
		var tableRoot = context.submit(table, new LayoutFrame(240.0, 184.0));
		var tableSemantics:Semantics = cast tableRoot.semantics;
		var headerViewport = tableRoot.children[0];
		var headerContent = headerViewport.children[0];
		var firstHeaderSemantics:Null<Semantics> = headerContent.children[0].semantics;
		if (tableSemantics.role != AccessibilityRole.Grid || tableSemantics.rowCount != 100000 ||
			tableSemantics.columnCount != 3 || table.selectedRow != 2 || tableBuiltCells.length == 0 ||
			tableBuiltCells.length > 64 || firstHeaderSemantics == null ||
			firstHeaderSemantics.role != AccessibilityRole.ColumnHeader)
			return 251;
		context.pointerDown(12.0, 24.0 + 3.0 * 24.0 + 12.0, 0);
		context.pointerUp(12.0, 24.0 + 3.0 * 24.0 + 12.0, 0);
		if (table.selectedRow != 3 || tableSelection != 3)
			return 252;
		var selectedCell:Null<RenderNode> = null;
		tableRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.Cell &&
				node.semantics.rowIndex == 3 && node.semantics.columnIndex == 0)
				selectedCell = node;
		});
		if (selectedCell == null || !context.focusWidget(selectedCell.id))
			return 254;
		context.key(UiEventKind.KeyDown, UiKey.Down);
		if (table.selectedRow != 4 || table.selectedColumn != 0 || tableCellSelection != 40)
			return 255;
		context.key(UiEventKind.KeyDown, UiKey.Right);
		if (table.selectedRow != 4 || table.selectedColumn != 1 || tableCellSelection != 41)
			return 256;
		context.pointerDown(12.0, 12.0, 0);
		context.pointerUp(12.0, 12.0, 0);
		if (table.sortColumn != 0 || !table.sortAscending || tableSortColumn != 0 ||
			!tableSortAscending)
			return 257;
		context.pointerDown(58.0, 12.0, 0);
		context.pointerMove(78.0, 12.0);
		context.pointerUp(78.0, 12.0, 0);
		if (table.columns[0].width != 80.0 || tableResizeColumn != 0 || tableResizeWidth != 80.0)
			return 258;
		tableRoot = context.submit(table, new LayoutFrame(240.0, 184.0));
		var resizedHeader = tableRoot.children[0].children[0].children[0].resolved;
		if (resizedHeader == null || resizedHeader.width != 80.0 || table.controller.maxScrollX != 20.0)
			return 259;
		var builtRows:Array<Int> = [];
		var listController = new ScrollController();
		var virtualStyle = new LayoutStyle();
		virtualStyle.width = LayoutAxis.fixed(256.0);
		virtualStyle.height = LayoutAxis.fixed(80.0);
		var virtualList = new VirtualList("virtual-smoke", 100, 20.0, function(index) {
			builtRows.push(index);
			return new Text('Row $index');
		}, virtualStyle, null, listController, 80.0);
		var virtualRoot = context.submit(virtualList, new LayoutFrame(256.0, 80.0));
		var virtualSemantics:Semantics = cast virtualRoot.semantics;
		var firstVirtualRowId = 0;
		virtualRoot.walk(function(node) {
			var semantics:Null<Semantics> = node.semantics;
			if (semantics != null && semantics.role == AccessibilityRole.CollectionItem &&
				semantics.positionInSet == 1)
				firstVirtualRowId = node.id.value;
		});
		if (virtualSemantics.role != AccessibilityRole.Collection || virtualSemantics.setSize != 100 ||
			builtRows.length >= 12 ||
			listController.maxScrollY != 1920.0 || virtualList.materializedFirst != 0 ||
			virtualList.materializedLast != 6 || firstVirtualRowId == 0)
			return 67;
		listController.jumpTo(0.0, 500.0);
		builtRows.resize(0);
		virtualRoot = context.submit(virtualList, new LayoutFrame(256.0, 80.0));
		var recycledVirtualRowId = 0;
		virtualRoot.walk(function(node) {
			var semantics:Null<Semantics> = node.semantics;
			if (semantics != null && semantics.role == AccessibilityRole.CollectionItem &&
				semantics.positionInSet == 25)
				recycledVirtualRowId = node.id.value;
		});
		if (builtRows.length >= 12 || builtRows.length == 0 || builtRows[0] < 24 ||
			builtRows[0] > 25 || listController.offsetY != 500.0 ||
			virtualList.materializedFirst != 24 || virtualList.materializedLast != 31 ||
			recycledVirtualRowId != firstVirtualRowId)
			return 68;
		var largeListController = new ScrollController();
		var largeVirtualStyle = new LayoutStyle();
		largeVirtualStyle.width = LayoutAxis.fixed(256.0);
		largeVirtualStyle.height = LayoutAxis.fixed(350.0);
		var largeBuiltRows:Array<Int> = [];
		var largeVirtualList = new VirtualList("large-virtual-smoke", 100000, 32.0, function(index) {
			largeBuiltRows.push(index);
			return new Text('Row ${index + 1}');
		}, largeVirtualStyle, null, largeListController, 350.0);
		context.submit(largeVirtualList, new LayoutFrame(256.0, 350.0));
		if (largeBuiltRows.length == 0 || largeBuiltRows.length > 16)
			return 104;
		largeListController.jumpTo(0.0, 414.0 * 32.0);
		largeBuiltRows.resize(0);
		var largeVirtualRoot = context.submit(largeVirtualList, new LayoutFrame(256.0, 350.0));
		if (largeBuiltRows.length == 0 || largeBuiltRows.length > 16 || largeBuiltRows[0] != 413 ||
			largeListController.offsetY != 13248.0)
			return 103;
		var modelBuiltRows:Array<Int> = [];
		var modelSelection = -1;
		var model = new SmokeListModel(100000, modelBuiltRows);
		var modelController = new ScrollController();
		var modelStyle = new LayoutStyle();
		modelStyle.width = LayoutAxis.fixed(256.0);
		modelStyle.height = LayoutAxis.fixed(120.0);
		var modelList = new ListView("model-list-smoke", model, modelStyle,
			modelController, 120.0, -1, function(index) { modelSelection = index; });
		var modelRoot = context.submit(modelList, new LayoutFrame(256.0, 120.0));
		var modelSemantics:Semantics = cast modelRoot.semantics;
		var firstModelRowId = 0;
		modelRoot.walk(function(node) {
			var semantics:Null<Semantics> = node.semantics;
			if (semantics != null && semantics.role == AccessibilityRole.CollectionItem &&
				semantics.positionInSet == 1)
				firstModelRowId = node.id.value;
		});
		var firstModelExtentCalls = model.extentCalls;
		if (modelSemantics.role != AccessibilityRole.Collection || modelSemantics.setSize != 100000 ||
			modelBuiltRows.length == 0 || modelBuiltRows.length > 16 || firstModelExtentCalls <= 0 ||
			firstModelExtentCalls >= 100000 ||
			modelBuiltRows[0] != 0 || modelController.maxScrollY <= 0.0)
			return 160;
		modelController.jumpTo(0.0, model.offsetBefore(50000));
		modelBuiltRows.resize(0);
		modelRoot = context.submit(modelList, new LayoutFrame(256.0, 120.0));
		var recycledModelRowId = 0;
		modelRoot.walk(function(node) {
			var semantics:Null<Semantics> = node.semantics;
			if (semantics != null && semantics.role == AccessibilityRole.CollectionItem &&
				semantics.positionInSet == 50000)
				recycledModelRowId = node.id.value;
		});
		if (modelBuiltRows.length == 0 || modelBuiltRows.length > 16 || modelBuiltRows[0] != 49999 ||
			model.extentCalls <= firstModelExtentCalls || model.extentCalls >= 100000 ||
			recycledModelRowId != firstModelRowId ||
			modelList.materializedFirst != 49999)
			return 161;
		var incrementalExtentCalls = model.extentCalls;
		model.bumpExtent(50000);
		modelBuiltRows.resize(0);
		modelRoot = context.submit(modelList, new LayoutFrame(256.0, 120.0));
		if (model.extentCalls <= incrementalExtentCalls ||
			modelList.extentMeasurements != model.extentCalls ||
			modelList.extentReuses <= 0)
			return 174;
		if (!modelList.select(50000) || modelList.selectedIndex != 50000 || modelSelection != 50000)
			return 162;
		modelRoot = context.submit(modelList, new LayoutFrame(256.0, 120.0));
		var selectedModelItem:Null<RenderNode> = null;
		modelRoot.walk(function(node) {
			var nodeSemantics:Null<Semantics> = node.semantics;
			if (nodeSemantics != null && nodeSemantics.role == AccessibilityRole.CollectionItem &&
				nodeSemantics.positionInSet == 50001)
				selectedModelItem = node;
		});
		if (selectedModelItem == null)
			return 163;
		var selectedModelSemantics:Null<Semantics> = selectedModelItem.semantics;
		if (selectedModelSemantics == null ||
			(selectedModelSemantics.states & AccessibilityState.Selected) == 0)
			return 164;
		if (!context.focusWidget(selectedModelItem.id))
			return 166;
		context.key(UiEventKind.KeyDown, UiKey.Down);
		if (modelList.selectedIndex != 50001 || modelSelection != 50001)
			return 167;
		if (!modelList.scrollTo(0) || modelController.offsetY != 0.0)
			return 165;
		var treeBuiltKeys:Array<String> = [];
		var treeSelection:String = "";
		var treeExpansionKey:String = "";
		var treeExpansionValue = false;
		var treeModel = new SmokeTreeModel(treeBuiltKeys);
		var treeController = new ScrollController();
		var treeStyle = new LayoutStyle();
		treeStyle.width = LayoutAxis.fixed(256.0);
		treeStyle.height = LayoutAxis.fixed(120.0);
		var tree = new TreeView("tree-smoke", treeModel, treeStyle, treeController, 120.0,
			null, null, function(nodeKey) { treeSelection = nodeKey; }, null,
			function(nodeKey, expanded) {
				treeExpansionKey = nodeKey;
				treeExpansionValue = expanded;
			});
		var treeRoot = context.submit(tree, new LayoutFrame(256.0, 120.0));
		var treeSemantics:Semantics = cast treeRoot.semantics;
		if (treeSemantics.role != AccessibilityRole.Tree || treeSemantics.setSize <= 100000 ||
			treeBuiltKeys.length == 0 || treeBuiltKeys.length > 16 ||
			treeBuiltKeys[0] != "root:0" || !tree.isExpanded("root:0") ||
			treeModel.extentCalls > 16 || treeModel.childCalls >= 100000)
			return 168;
		if (!tree.select("root:0:child:2") || treeSelection != "root:0:child:2")
			return 169;
		if (!tree.scrollTo("root:0:child:2") || treeController.offsetY <= 0.0)
			return 170;
		if (!tree.setExpanded("root:0", false) || treeExpansionKey != "root:0" || treeExpansionValue)
			return 171;
		// Toggling immediately after a tree revision must find the visible row
		// even before a new viewport build materializes its entry.
		if (!tree.toggleExpanded("root:0") || !tree.isExpanded("root:0") ||
			!tree.toggleExpanded("root:0") || tree.isExpanded("root:0"))
			return 175;
		tree.scrollTo("root:0");
		treeBuiltKeys.resize(0);
		treeRoot = context.submit(tree, new LayoutFrame(256.0, 120.0));
		if (treeBuiltKeys.length == 0 || treeBuiltKeys[0] != "root:0" ||
			tree.isExpanded("root:0"))
			return 172;
		if (!tree.toggleExpanded("root:0") || !tree.isExpanded("root:0"))
			return 173;
		if (tree.toggleExpanded("no-longer-visible") ||
			tree.setExpanded("no-longer-visible", true))
			return 174;
		// A directory hint keeps an empty folder expandable with no child rows.
		var emptyFolderTree = new TreeView("empty-folder-tree-smoke", treeModel, treeStyle,
			new ScrollController(), 120.0);
		emptyFolderTree.hasChildrenHint = function(key) return key == "root:0" || key == "root:0:child:2";
		context.submit(emptyFolderTree, new LayoutFrame(256.0, 120.0));
		if (!emptyFolderTree.toggleExpanded("root:0:child:2") || !emptyFolderTree.isExpanded("root:0:child:2"))
			return 176;
		context.submit(emptyFolderTree, new LayoutFrame(256.0, 120.0));
		if (!emptyFolderTree.isExpanded("root:0:child:2") || !emptyFolderTree.toggleExpanded("root:0:child:2") ||
			emptyFolderTree.isExpanded("root:0:child:2"))
			return 177;
		// Exercise the session capacity and the framework as one realistic,
		// nested settings tree. The custom painter sits between ordinary text
		// siblings inside the clipped, scrollable content.
		var pressureCanvasStyle = new LayoutStyle();
		pressureCanvasStyle.width = LayoutAxis.grow();
		pressureCanvasStyle.height = LayoutAxis.fixed(24.0);
		var pressureChildren:Array<KeyedView> = [
			new KeyedView("before-custom", new Text("Before custom canvas")),
			new KeyedView("custom-canvas", new CanvasView("custom-canvas-view",
				function(canvas, geometry) {
					canvas.fillRect(new Rect(0.0, 0.0, geometry.width, geometry.height),
						Color.rgba(0.2, 0.4, 0.7, 1.0));
				}, pressureCanvasStyle, "Custom settings illustration")),
			new KeyedView("after-custom", new Text("After custom canvas"))
		];
		for (index in 0...2000) {
			var row = new SizedBox("row", new Text('Setting $index'), LayoutAxis.grow(),
				LayoutAxis.fixed(24.0));
			pressureChildren.push(new KeyedView('setting:$index', row));
		}
		var pressureContentStyle = new LayoutStyle();
		pressureContentStyle.width = LayoutAxis.grow();
		var pressureContent = new Column("pressure-settings", pressureChildren,
			pressureContentStyle);
		var innerViewportStyle = new LayoutStyle();
		innerViewportStyle.width = LayoutAxis.fixed(256.0);
		innerViewportStyle.height = LayoutAxis.fixed(128.0);
		var innerController = new ScrollController();
		var innerScroll = new ScrollView("pressure-inner-scroll", pressureContent,
			innerViewportStyle, ScrollAxis.Vertical, innerController);
		var outerContentStyle = new LayoutStyle();
		outerContentStyle.width = LayoutAxis.fixed(256.0);
		outerContentStyle.height = LayoutAxis.fit();
		var outerContent = new Column("pressure-outer-content", [
			new KeyedView("pressure-heading", new Text("Settings")),
			new KeyedView("pressure-inner", innerScroll),
			new KeyedView("pressure-tail", new SizedBox("tail", new Text("End of section"),
				LayoutAxis.grow(), LayoutAxis.fixed(500.0)))
		], outerContentStyle);
		var outerViewportStyle = new LayoutStyle();
		outerViewportStyle.width = LayoutAxis.fixed(256.0);
		outerViewportStyle.height = LayoutAxis.fixed(192.0);
		var outerController = new ScrollController();
		var pressureView = new ScrollView("pressure-outer-scroll", outerContent,
			outerViewportStyle, ScrollAxis.Vertical, outerController);
		var pressureRoot = context.submit(pressureView, new LayoutFrame(256.0, 192.0));
		var pressureNodeCount = 0;
		pressureRoot.walk(function(_) { pressureNodeCount++; });
		var innerNode = pressureRoot.children[0].children[0].children[1];
		var innerGeometry:ResolvedLayoutItem = cast innerNode.resolved;
		var customNode = innerNode.children[0].children[0].children[1];
		var customParent:RenderNode = cast customNode.parent;
		if (pressureNodeCount < 4000 || innerGeometry.height != 128.0 ||
			innerController.maxScrollY < 47000.0 || outerController.maxScrollY < 300.0 ||
			customParent == null || customNode.layout.visualKind != LayoutVisualKind.Custom ||
			customParent.children[0].layout.visualKind != LayoutVisualKind.Text ||
			customParent.children[2].layout.visualKind != LayoutVisualKind.Text)
			return 101;
		context.scroll(innerGeometry.x + 4.0, innerGeometry.y + 4.0, 0.0, 60.0);
		if (innerController.offsetY != 60.0 || outerController.offsetY != 0.0)
			return 102;
		context.scroll(4.0, 180.0, 0.0, 50.0);
		if (outerController.offsetY != 50.0)
			return 103;

		var returnFocusView = new Button("Return focus");
		var returnFocusRoot = context.submit(returnFocusView, new LayoutFrame(256.0, 192.0));
		if (!context.focusWidget(returnFocusRoot.id))
			return 69;
		var dialogDismissals = 0;
		var dialog = new Dialog("dialog-smoke", "Settings", new Button("Apply"),
			function() { dialogDismissals++; }, 240.0);
		var dialogFrame = new LayoutFrame(256.0, 192.0);
		var modalStack = new Stack("modal-stack", [
			new StackChild("background", new Text("Background"), 0.0, 0.0, 0,
				LayoutAxis.grow(), LayoutAxis.grow()),
			new StackChild("dialog-layer", dialog, 0.0, 0.0, 10,
				LayoutAxis.grow(), LayoutAxis.grow())
		]);
		var dialogRoot = context.submit(modalStack, dialogFrame);
		var dialogFocus:Null<WidgetId> = null;
		dialogRoot.walk(function(node) {
			if (node.focusable)
				dialogFocus = node.id;
		});
		var dialogLayer = dialogRoot.children[1];
		var dialogPanelGeometry:ResolvedLayoutItem = cast dialogLayer.children[1].children[0].resolved;
		var centeredDialogX = 128.0 - dialogPanelGeometry.width * 0.5;
		var centeredDialogY = 96.0 - dialogPanelGeometry.height * 0.5;
		if (dialogFocus == null || context.focus.focusedId == null ||
			!context.focus.focusedId.equals(dialogFocus) ||
			dialogPanelGeometry.x < centeredDialogX - 0.1 ||
			dialogPanelGeometry.x > centeredDialogX + 0.1 ||
			dialogPanelGeometry.y < centeredDialogY - 0.1 ||
			dialogPanelGeometry.y > centeredDialogY + 0.1)
			return 70;
		var modalSemantics = AccessibilityBridge.project(dialogRoot, dialogFocus);
		for (semanticNode in modalSemantics)
			if (semanticNode.semantics.label == "Background")
				return 79;
		context.key(UiEventKind.KeyDown, UiKey.Escape);
		if (dialogDismissals != 1)
			return 71;
		returnFocusRoot = context.submit(returnFocusView, dialogFrame);
		if (context.focus.focusedId == null || !context.focus.focusedId.equals(returnFocusRoot.id))
			return 72;

		var popupDismissals = 0;
		var popup = new Popup("popup-smoke", new Button("Popup action"), 100.0, 60.0,
			null, function() { popupDismissals++; });
		var popupRoot = context.submit(popup, dialogFrame);
		context.pointerDown(5.0, 5.0, 0);
		context.pointerUp(5.0, 5.0, 0);
		if (popupDismissals != 1 || popupRoot.children[0].resolved == null)
			return 73;

		var selectedMenuItem = "";
		var menuDismissals = 0;
		var menu = new Menu("menu-smoke", [
			new MenuItem("open", "Open", function() { selectedMenuItem = "open"; }),
			new MenuItem("disabled", "Unavailable", null, false)
		], 32.0, 24.0, function() { menuDismissals++; });
		menu.selectFirstOnOpen = true;
		var menuRoot = context.submit(menu, dialogFrame);
		var menuGeometry:ResolvedLayoutItem = cast menuRoot.children[2].resolved;
		if (context.focus.focusedId == null ||
			menuRoot.children[0].layout.style.background.alpha != 0.0 ||
			Math.abs(menuGeometry.x - Math.max(8.0, Math.min(32.0, dialogFrame.width - menuGeometry.width - 8.0))) > 0.1 ||
			menuGeometry.y != 24.0 ||
			menuRoot.children[2].layout.style.radiusTopLeft != 0.0)
			return 74;
		context.key(UiEventKind.KeyDown, UiKey.Enter);
		var disabledMenuPresent = false;
		menuRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.MenuItem &&
				node.semantics.label == "Unavailable" && !node.enabled) disabledMenuPresent = true;
		});
		if (selectedMenuItem != "open" || menuDismissals != 1 || !disabledMenuPresent)
			return 75;

		var unavailableMenuDismissals = 0;
		var unavailableMenu = new Menu("unavailable-menu-smoke", [
			new MenuItem("disabled-only", "Unavailable", null, false)
		], 4.0, 4.0, function() { unavailableMenuDismissals++; });
		var unavailableMenuRoot = context.submit(unavailableMenu, dialogFrame);
		if (context.focus.focusedId == null) return 1016;
		// A menu that fits to the right of its anchor opens there.
		var unavailableMenuBounds = unavailableMenuRoot.children[2].resolved;
		if (unavailableMenuBounds == null || Math.abs(unavailableMenuBounds.x - 8.0) > 0.1 ||
			Math.abs(unavailableMenuBounds.y - 8.0) > 0.1) return 1019;
		context.key(UiEventKind.KeyDown, UiKey.Escape);
		if (unavailableMenuDismissals != 1) return 1017;

		var overflowChoice = -1;
		var overflowMenuItems:Array<MenuItem> = [];
		for (index in 0...18) {
			var choice = index;
			overflowMenuItems.push(new MenuItem("choice-" + index, "Choice " + index,
				function() { overflowChoice = choice; }));
		}
		var overflowMenu = new Menu("overflow-menu-smoke", overflowMenuItems, 250.0, 115.0);
		overflowMenu.selectFirstOnOpen = true;
		var overflowMenuFrame = new LayoutFrame(256.0, 120.0);
		var overflowMenuRoot = context.submit(overflowMenu, overflowMenuFrame);
		var overflowMenuBounds = overflowMenuRoot.children[2].resolved;
		if (overflowMenuBounds == null || overflowMenuBounds.x < 0 || overflowMenuBounds.y < 0 ||
			overflowMenuBounds.x + overflowMenuBounds.width > 256.1 ||
			overflowMenuBounds.y + overflowMenuBounds.height > 120.1) return 1008;
		// Without room to the right, the menu opens to the left of its anchor.
		if (Math.abs(overflowMenuBounds.x + overflowMenuBounds.width - 248.0) > 0.1) return 1020;
		// The menu surface must follow the panel after edge placement moves it.
		var overflowSurfaceBounds = overflowMenuRoot.children[2].children[0].resolved;
		if (overflowSurfaceBounds == null ||
			Math.abs(overflowSurfaceBounds.x - overflowMenuBounds.x) > 0.1 ||
			Math.abs(overflowSurfaceBounds.y - overflowMenuBounds.y) > 0.1) return 1018;
		for (overflowIndex in 0...17) {
			context.key(UiEventKind.KeyDown, UiKey.Down);
			overflowMenuRoot = context.submit(overflowMenu, overflowMenuFrame);
			var stepFocus = context.focus.focusedId;
			if (stepFocus == null) return 1013;
			var stepItem = overflowMenuRoot.find(stepFocus);
			if (stepItem == null || stepItem.semantics == null ||
				stepItem.semantics.label != "Choice " + (overflowIndex + 1)) return 1014;
		}
		var focusedOverflowItem = context.focus.focusedId;
		if (focusedOverflowItem == null) return 1009;
		var lastOverflowItem = overflowMenuRoot.find(focusedOverflowItem);
		if (lastOverflowItem == null || lastOverflowItem.semantics == null ||
			lastOverflowItem.semantics.label != "Choice 17") return 1010;
		var lastOverflowGeometry = lastOverflowItem.resolved;
		if (lastOverflowGeometry == null || !lastOverflowGeometry.visible) return 1011;
		var lastOverflowBounds = lastOverflowGeometry.viewportBounds();
		if (lastOverflowBounds.y < 0 || lastOverflowBounds.y + lastOverflowBounds.height > 120.1) return 1015;
		context.key(UiEventKind.KeyDown, UiKey.Enter);
		if (overflowChoice != 17) return 1012;

		var longMenuLabel = "Attach existing Codex thread with a very long descriptive name…";
		var boundedMenu = new Menu("bounded-menu-smoke", [new MenuItem("long-action", longMenuLabel)], 799.0, 399.0);
		var boundedMenuFrame = new LayoutFrame(800.0, 400.0);
		var boundedMenuRoot = context.submit(boundedMenu, boundedMenuFrame);
		boundedMenuRoot = context.submit(boundedMenu, boundedMenuFrame);
		var boundedMenuBounds = boundedMenuRoot.children[2].resolved;
		if (boundedMenuBounds == null || boundedMenuBounds.width > 360.1 ||
			boundedMenuBounds.x < 7.9 || boundedMenuBounds.x + boundedMenuBounds.width > 792.1) return 1021;
		var hasEllipsis = false, hasFullActionName = false;
		boundedMenuRoot.walk(function(node) {
			if (node.layout.text != null && node.layout.text != longMenuLabel && StringTools.endsWith(node.layout.text, "…")) hasEllipsis = true;
			if (node.semantics != null && node.semantics.role == AccessibilityRole.MenuItem && node.semantics.label == longMenuLabel) hasFullActionName = true;
		});
		if (!hasEllipsis || !hasFullActionName) return 1022;
		var narrowMenuRoot = context.submit(boundedMenu, new LayoutFrame(180.0, 200.0));
		narrowMenuRoot = context.submit(boundedMenu, new LayoutFrame(180.0, 200.0));
		var narrowMenuBounds = narrowMenuRoot.children[2].resolved;
		if (narrowMenuBounds == null || narrowMenuBounds.x < 7.9 ||
			narrowMenuBounds.x + narrowMenuBounds.width > 172.1) return 1023;

		var tooltip = new Tooltip("tooltip-smoke", new Button("Anchor"), new Text("Hint"));
		var tooltipFrame = new LayoutFrame(256.0, 192.0);
		var tooltipRoot = context.submit(tooltip, tooltipFrame);
		var tooltipGeometry:ResolvedLayoutItem = cast tooltipRoot.children[1].resolved;
		var tooltipRootGeometry:ResolvedLayoutItem = cast tooltipRoot.resolved;
		var anchorGeometry:ResolvedLayoutItem = cast tooltipRoot.children[0].resolved;
		if (tooltipRootGeometry.height < anchorGeometry.height)
			return 101;
		if (tooltipGeometry.visible)
			return 76;
		context.pointerMove(anchorGeometry.x + 4.0, anchorGeometry.y + 4.0);
		tooltipRoot = context.submit(tooltip, tooltipFrame);
		tooltipGeometry = cast tooltipRoot.children[1].resolved;
		if (!tooltipGeometry.visible)
			return 77;
		context.pointerMove(250.0, 190.0);
		tooltipRoot = context.submit(tooltip, tooltipFrame);
		tooltipGeometry = cast tooltipRoot.children[1].resolved;
		if (tooltipGeometry.visible)
			return 78;
		var tooltipCardStyle = new LayoutStyle();
		tooltipCardStyle.width = LayoutAxis.fixed(220.0);
		tooltipCardStyle.height = LayoutAxis.fit();
		tooltipCardStyle.padding = new Insets(12.0, 12.0, 12.0, 12.0);
		tooltipCardStyle.childGap = 6.0;
		var tooltipCard = new Column("tooltip-card", [
			new KeyedView("heading", new Text("Open an overlay")),
			new KeyedView("anchor", new Tooltip("tooltip-in-card",
				new Button("Hover for tooltip"), new Text("Hint")))
		], tooltipCardStyle);
		var tooltipCardRoot = context.submit(tooltipCard, tooltipFrame);
		var tooltipCardGeometry:ResolvedLayoutItem = cast tooltipCardRoot.resolved;
		var tooltipCardAnchor:ResolvedLayoutItem = cast tooltipCardRoot.children[1].children[0].resolved;
		if (tooltipCardAnchor.y + tooltipCardAnchor.height >
			tooltipCardGeometry.y + tooltipCardGeometry.height - 12.0 + 0.1)
			return 103;

		var radioChanges = 0;
		var radioValue = "";
		var radioGroup = new RadioGroup("radio-smoke", [
			new RadioOption("red", "Red", "red"),
			new RadioOption("blocked", "Blocked", "blocked", false),
			new RadioOption("green", "Green", "green")
		], "red", function(next) { radioChanges++; radioValue = next; });
		var radioFrame = new LayoutFrame(256.0, 192.0);
		var radioRoot = context.submit(radioGroup, radioFrame);
		if (radioRoot.children.length != 3 ||
			(cast(radioRoot.children[0].semantics, Semantics).states & AccessibilityState.Selected) == 0 ||
			!context.focusWidget(radioRoot.children[0].id))
			return 92;
		var radioIndicator:ResolvedLayoutItem = cast radioRoot.children[0].children[0].resolved;
		var radioDot:ResolvedLayoutItem = cast radioRoot.children[0].children[0].children[0].resolved;
		if (Math.abs((radioIndicator.x + radioIndicator.width * 0.5) -
			(radioDot.x + radioDot.width * 0.5)) > 0.01 ||
			Math.abs((radioIndicator.y + radioIndicator.height * 0.5) -
			(radioDot.y + radioDot.height * 0.5)) > 0.01)
			return 253;
		context.key(UiEventKind.KeyDown, UiKey.Right);
		if (radioGroup.value != "green" || radioValue != "green" || radioChanges != 1 ||
			context.focus.focusedId == null ||
			!context.focus.focusedId.equals(radioRoot.children[2].id))
			return 93;
		radioRoot = context.submit(radioGroup, radioFrame);
		if ((cast(radioRoot.children[2].semantics, Semantics).states & AccessibilityState.Selected) == 0)
			return 94;

		var tabChanges = 0;
		var retainedHeaderBuilds = 0;
		var retainedHeaderRevision = "initial";
		var retainedTabOptions = new haxeon.ui.widgets.controls.TabsOptions();
		retainedTabOptions.selectionMode = haxeon.ui.widgets.controls.TabsSelectionMode.Controlled;
		var retainedTabs = Tabs.withOptions("retained-tabs-smoke", [
			new TabItem("first", "First", new Text("first page")),
			new TabItem("second", "Second", new Text("second page"))
		], "first", null, retainedTabOptions);
		retainedTabs.headerRevision = function() return retainedHeaderRevision;
		retainedTabs.onTabHeaderBuilt = function(_, _) { retainedHeaderBuilds++; };
		context.submit(retainedTabs, new LayoutFrame(320, 192));
		context.submit(retainedTabs, new LayoutFrame(320, 192));
		if (retainedHeaderBuilds != 2) throw "Unchanged tab headers must be retained";
		retainedTabs.selectedKey = "second";
		context.submit(retainedTabs, new LayoutFrame(320, 192));
		if (retainedHeaderBuilds != 4) throw "Selection changes must update retained tab headers";
		retainedTabs.items[0] = new TabItem("first", "First *", new Text("edited page"));
		retainedHeaderRevision = "edited";
		context.submit(retainedTabs, new LayoutFrame(320, 192));
		if (retainedHeaderBuilds != 6) throw "Label changes must update retained tab headers";
		var tabs = new Tabs("tabs-smoke", [
			new TabItem("first", "First", new Text("First page")),
			new TabItem("second", "Second", new Text("Second page")),
			new TabItem("locked", "Locked", new Text("Locked page"), false)
		], "first", function(_) { tabChanges++; });
		var tabsFrame = new LayoutFrame(256.0, 192.0);
		var tabsRoot = context.submit(tabs, tabsFrame);
		var secondTab = tabStrip(tabsRoot).children[1].children[0];
		var secondTabGeometry:ResolvedLayoutItem = cast secondTab.resolved;
		context.pointerDown(secondTabGeometry.x + 2.0, secondTabGeometry.y + 2.0, 0);
		context.pointerUp(secondTabGeometry.x + 2.0, secondTabGeometry.y + 2.0, 0);
		if (tabs.selectedKey != "second" || tabChanges != 1)
			return 95;
		tabsRoot = context.submit(tabs, tabsFrame);
		var secondPage:Semantics = cast tabsRoot.children[1].semantics;
		if (secondPage.role != AccessibilityRole.TabPanel || secondPage.label != "Second" ||
			(cast(tabStrip(tabsRoot).children[1].children[0].semantics, Semantics).states &
			AccessibilityState.Selected) == 0)
			return 96;
		if (!context.focusWidget(tabStrip(tabsRoot).children[1].children[0].id))
			return 97;
		context.key(UiEventKind.KeyDown, UiKey.Left);
		if (tabs.selectedKey != "first" || context.focus.focusedId == null ||
			!context.focus.focusedId.equals(tabStrip(tabsRoot).children[0].children[0].id))
			return 98;

		var tabMenus = 0;
		var menuTab = "";
		tabs.onTabContextMenu = function(key, event) { tabMenus++; menuTab = key; };
		tabsRoot = context.submit(tabs, tabsFrame);
		var tabContextGeometry = tabStrip(tabsRoot).children[1].children[0].resolved;
		if (tabContextGeometry == null) return 1001;
		context.pointerDown(tabContextGeometry.x + 2.0, tabContextGeometry.y + 2.0, 1);
		context.pointerUp(tabContextGeometry.x + 2.0, tabContextGeometry.y + 2.0, 1);
		if (tabMenus != 1 || menuTab != "second" || tabs.selectedKey != "first" || tabChanges != 2)
			return 1002;
		if (!context.focusWidget(tabStrip(tabsRoot).children[0].children[0].id)) return 1003;
		context.key(UiEventKind.KeyDown, UiKey.F10);
		if (tabMenus != 1) return 1004;
		context.key(UiEventKind.KeyDown, UiKey.F10, UiModifier.Shift);
		if (tabMenus != 2 || menuTab != "first" || tabs.selectedKey != "first") return 1005;
		context.key(UiEventKind.KeyDown, UiKey.Menu);
		if (tabMenus != 3 || menuTab != "first") return 1018;
		var lockedTabContextGeometry = tabStrip(tabsRoot).children[2].children[0].resolved;
		if (lockedTabContextGeometry == null) return 1006;
		context.pointerDown(lockedTabContextGeometry.x + 2.0, lockedTabContextGeometry.y + 2.0, 1);
		context.pointerUp(lockedTabContextGeometry.x + 2.0, lockedTabContextGeometry.y + 2.0, 1);
		if (tabMenus != 3 || tabs.selectedKey != "first") return 1007;

		var closes = 0, closeSelections = 0, closeDrags = 0;
		var closable = new TabItem("closable", "Close me", new Text("close page"));
		closable.onClose = function() closes++;
		var closeTabs = new Tabs("close-tabs", [new TabItem("keep", "Keep", new Text("keep page")), closable],
			"keep", function(_) closeSelections++, null, function(_, _) closeDrags++);
		closeTabs.headerRevision = function() return "stable";
		context.pointerMove(0, 180);
		var closeRoot = context.submit(closeTabs, tabsFrame);
		var closeRow = tabStrip(closeRoot).children[1].children[0];
		var closeNode = closeRow.children[1].children[0];
		var closeWidth = closeRow.globalBounds().width;
		if (closeNode.layout.style.visible || cast(closeNode.semantics, Semantics).label != "Close Close me") throw "Close buttons must start hidden and expose an accessible name";
		var closeBounds = closeRow.globalBounds();
		context.pointerMove(closeBounds.x + 2, closeBounds.y + 2);
		closeRoot = context.submit(closeTabs, tabsFrame);
		closeRow = tabStrip(closeRoot).children[1].children[0];
		closeNode = closeRow.children[1].children[0];
		if (!closeNode.layout.style.visible || closeRow.globalBounds().width != closeWidth) throw "Hover must reveal the close target without changing tab width";
		closeBounds = closeNode.globalBounds();
		context.pointerMove(closeBounds.x + 12, closeBounds.y + 12);
		context.pointerDown(closeBounds.x + 12, closeBounds.y + 12, 0);
		context.pointerUp(closeBounds.x + 12, closeBounds.y + 12, 0);
		if (closes != 1 || closeSelections != 0 || closeDrags != 0 || closeTabs.selectedKey != "keep") throw "Closing an inactive tab must not select it or start a drag";
		var tabBody = closeRow.children[0].globalBounds();
		context.pointerDown(tabBody.x + 2, tabBody.y + 2, 2);
		closeRoot = context.submit(closeTabs, tabsFrame);
		context.pointerUp(tabBody.x + 2, tabBody.y + 2, 2);
		if (closes != 2 || closeSelections != 0 || closeDrags != 0 || closeTabs.selectedKey != "keep")
			throw "Middle-click must close an inactive tab without selecting or dragging it";
		closeRow = tabStrip(closeRoot).children[1].children[0];
		closeNode = closeRow.children[1].children[0];
		context.focusWidget(tabStrip(closeRoot).children[0].children[0].id);
		context.pointerMove(0, 180);
		closeRoot = context.submit(closeTabs, tabsFrame);
		closeRow = tabStrip(closeRoot).children[1].children[0];
		closeNode = closeRow.children[1].children[0];
		if (closeNode.layout.style.visible) throw "Leaving a tab must hide its close target";
		context.focusWidget(closeRow.children[0].id);
		context.submit(closeTabs, tabsFrame);
		if (!closeNode.layout.style.visible) throw "Keyboard focus must reveal the close action";

		for (value in ["🙂🙂🙂🙂🙂🙂🙂🙂-a-very-long-filename.txt", "日本語の長いファイル名-a-very-long-filename.hx"]) {
			var ellipsisStyle = new LayoutStyle();
			ellipsisStyle.width = LayoutAxis.fixed(31);
			var ellipsis = new haxeon.ui.widgets.text.MiddleEllipsisText("unicode-ellipsis", value);
			context.submit(new Row("unicode-ellipsis-row", [new KeyedView("label", ellipsis)], ellipsisStyle), tabsFrame);
			context.submit(new Row("unicode-ellipsis-row", [new KeyedView("label", ellipsis)], ellipsisStyle), tabsFrame);
			if (!ellipsis.truncated) throw "Unicode ellipsis fixture did not exercise truncation";
		}

		var theme = new Theme();
		if (theme.tokens.textPrimary != theme.text || theme.tokens.textSecondary != theme.mutedText ||
			theme.tokens.surface != theme.panelBackground || theme.tokens.focusRing != theme.buttonFocused ||
			theme.tokens.radiusMedium != 6.0 || theme.tokens.spacingMedium != 8.0)
			return 225;
		var originalButton = theme.tokens.buttonBackground;
		var originalControl = theme.tokens.controlUnselected;
		theme.tokens.surfaceRaised = Color.rgba(0.31, 0.32, 0.33, 1.0);
		theme.tokens.border = Color.rgba(0.41, 0.42, 0.43, 1.0);
		if (theme.tokens.buttonBackground != originalButton ||
			theme.tokens.controlUnselected != originalControl)
			return 225;
		theme.tokens.deriveComponents();
		if (theme.tokens.navigationBackground != theme.tokens.surfaceRaised ||
			theme.tokens.selectionBorder != theme.tokens.border)
			return 225;
		theme.body.color = Color.rgba(0.10, 0.14, 0.21, 1.0);
		theme.button.color = Color.rgba(1.0, 1.0, 1.0, 1.0);
		var styleTheme = new StyleSheet("StyleTheme");
		styleTheme.rule(StyleSelector.widget("button"),
			[StyleValue.background(Color.rgba(0.1, 0.1, 0.1, 1.0))]);
		styleTheme.rule(StyleSelector.widget("button").state(StyleState.Hovered),
			[StyleValue.background(Color.rgba(0.2, 0.2, 0.2, 1.0))]);
		var styleApplication = new StyleSheet("StyleApplication");
		styleApplication.rule(StyleSelector.widget("button"),
			[StyleValue.background(Color.rgba(0.3, 0.3, 0.3, 1.0))]);
		styleApplication.rule(StyleSelector.widget("button").state(StyleState.Hovered),
			[StyleValue.background(Color.rgba(0.4, 0.4, 0.4, 1.0))]);
		var localStyle = new LayoutStyle();
		localStyle.width = LayoutAxis.fixed(88.0);
		var computed = new StyleResolver().resolve(
			new StyleTarget("button", "style-key", "style-id", ["primary"], ["button"],
				StyleStateUtil.withState(0, StyleState.Hovered, true)),
			null, styleTheme, styleApplication, localStyle);
		var computedSource:Null<StyleSource> = computed.source(StyleProperty.Background);
		var computedSourceStylesheet = computedSource == null ? "" : computedSource.stylesheet;
		var computedSourceSelector = computedSource == null ? "" : computedSource.selector;
		if (computed.get(StyleProperty.Background).red != 0.4 ||
			computed.get(StyleProperty.Width).sizing != LayoutSizing.Fixed ||
			computed.get(StyleProperty.Width).value != 88.0 || computedSource == null ||
			computedSourceStylesheet != "StyleApplication" ||
			computedSourceSelector != "button:hovered")
			return 214;
		var cacheSheet = new StyleSheet("CacheStyles");
		cacheSheet.rule(StyleSelector.widget("button"),
			[StyleValue.background(Color.rgba(0.3, 0.3, 0.3, 1.0)),
				StyleValue.width(LayoutAxis.grow(100.0, 500.0, 3.0))]);
		var cacheResolver = new StyleResolver();
		var cacheTarget = new StyleTarget("button", "cache-key");
		var cachedFirst = cacheResolver.resolve(cacheTarget, null, null, cacheSheet);
		var cachedSecond = cacheResolver.resolve(cacheTarget, null, null, cacheSheet);
		if (cacheResolver.cacheMisses != 1 || cacheResolver.cacheHits != 1 ||
			cacheResolver.cachedStyleCount != 1 || cachedSecond.get(StyleProperty.Background).red != 0.3)
			return 230;
		var cachedAxisLayout = cachedSecond.copy().toLayoutStyle();
		if (cachedAxisLayout.width.sizing != LayoutSizing.Grow || cachedAxisLayout.width.min != 100.0 ||
			cachedAxisLayout.width.max != 500.0 || cachedAxisLayout.width.growWeight != 3.0)
			return 236;
		cachedFirst.set(StyleProperty.Background, Color.rgba(1.0, 0.0, 0.0, 1.0), null);
		var cachedThird = cacheResolver.resolve(cacheTarget, null, null, cacheSheet);
		if (cacheResolver.cacheHits != 2 || cachedThird.get(StyleProperty.Background).red != 0.3 ||
			cachedThird.get(StyleProperty.Width).value != 0.0)
			return 231;
		var colorResolver = new StyleResolver();
		var colorTarget = new StyleTarget("text");
		var red = Color.rgba(1, 0, 0), blue = Color.rgba(0, 0, 1);
		var colored = colorResolver.resolve(colorTarget, null, null, null, null, null, red);
		var sameColor = colorResolver.resolve(colorTarget, null, null, null, null, null, Color.rgba(1, 0, 0));
		var coloredSource = colored.source(StyleProperty.TextColor);
		if (coloredSource == null) throw "Missing local text provenance";
		if (!colored.sharesValuesWith(sameColor) || colorResolver.cacheHits != 1 ||
			coloredSource.selector != "text" ||
			coloredSource.layer != "local")
			throw "Local text color must retain cache sharing and provenance";
		var blueStyle = colorResolver.resolve(colorTarget, null, null, null, null, null, blue);
		var noColor = colorResolver.resolve(colorTarget);
		var noColorSource = noColor.source(StyleProperty.TextColor);
		if (noColorSource == null) throw "Missing framework text provenance";
		if (blueStyle.get(StyleProperty.TextColor).blue != 1 ||
			noColorSource.layer != "framework")
			throw "Text color variants and absent overrides must resolve independently";
		colored.set(StyleProperty.TextColor, blue, null);
		var redAgain = colorResolver.resolve(colorTarget, null, null, null, null, null, red);
		if (redAgain.get(StyleProperty.TextColor).red != 1)
			throw "Mutating a returned colored style must preserve the cache";
		var localAxis = new LayoutStyle();
		localAxis.width = LayoutAxis.fit(100.0, 500.0);
		var localAxisResolver = new StyleResolver();
		var localAxisTarget = new StyleTarget("box", "local-axis");
		var localAxisFirst = localAxisResolver.resolve(localAxisTarget, null, null, null, localAxis);
		var localAxisFirstValue = localAxisFirst.get(StyleProperty.Width);
		if (localAxisResolver.cacheMisses != 1 || !localAxisFirst.has(StyleProperty.Width) ||
			localAxisFirstValue.min != 100.0 || localAxisFirstValue.max != 500.0)
			return 237;
		localAxis.width = LayoutAxis.grow(100.0, 500.0, 3.0);
		var localAxisSecond = localAxisResolver.resolve(localAxisTarget, null, null, null, localAxis);
		var localAxisSecondValue = localAxisSecond.get(StyleProperty.Width);
		if (localAxisResolver.cacheMisses != 2 || localAxisResolver.cacheHits != 0 ||
			localAxisSecondValue.sizing != LayoutSizing.Grow || localAxisSecondValue.growWeight != 3.0)
			return 238;
		localAxis.width = LayoutAxis.grow(100.0, 500.0, 4.0);
		var localAxisThird = localAxisResolver.resolve(localAxisTarget, null, null, null, localAxis);
		if (localAxisResolver.cacheMisses != 3 || localAxisThird.get(StyleProperty.Width).growWeight != 4.0)
			return 239;
		var axisBefore = new ComputedStyle();
		axisBefore.set(StyleProperty.Width, LayoutAxis.grow(100.0, 500.0, 3.0), null);
		var axisAfter = new ComputedStyle();
		axisAfter.set(StyleProperty.Width, LayoutAxis.grow(100.0, 500.0, 4.0), null);
		if (!StyleDiff.compare(axisBefore, axisAfter).changed)
			return 240;
		cacheSheet.rule(StyleSelector.widget("button"),
			[StyleValue.background(Color.rgba(0.6, 0.6, 0.6, 1.0))]);
		var revised = cacheResolver.resolve(cacheTarget, null, null, cacheSheet);
		if (cacheResolver.cacheMisses != 2 || revised.get(StyleProperty.Background).red != 0.6)
			return 232;
		cacheTarget = new StyleTarget("button", "cache-key", null, null, null, StyleState.Hovered);
		var stateChanged = cacheResolver.resolve(cacheTarget, null, null, cacheSheet);
		if (cacheResolver.cacheMisses != 3 || stateChanged.get(StyleProperty.Background).red != 0.6)
			return 233;
		var cacheEnvironment = new StyleEnvironment(500.0, 800.0);
		var environmentSheet = new StyleSheet("CacheEnvironment");
		environmentSheet.rule(StyleSelector.widget("button"),
			[StyleValue.paddingSymmetric(12.0, 8.0)]);
		environmentSheet.when(Environment.widthLessThan(600.0), StyleSelector.widget("button"),
			[StyleValue.paddingSymmetric(6.0, 4.0)]);
		var environmentResolver = new StyleResolver();
		environmentResolver.resolve(cacheTarget, null, null, environmentSheet, null, cacheEnvironment);
		environmentResolver.resolve(cacheTarget, null, null, environmentSheet, null, cacheEnvironment);
		cacheEnvironment.setViewport(800.0, 500.0);
		var environmentChanged = environmentResolver.resolve(cacheTarget, null, null,
			environmentSheet, null, cacheEnvironment);
		if (environmentResolver.cacheHits != 1 || environmentResolver.cacheMisses != 2 ||
			environmentChanged.get(StyleProperty.Padding).left != 12.0)
			return 234;
		var replacementEnvironment = new StyleEnvironment(800.0, 500.0);
		var replacementEnvironmentStyle = environmentResolver.resolve(cacheTarget, null, null,
			environmentSheet, null, replacementEnvironment);
		if (environmentResolver.cacheMisses != 3 ||
			replacementEnvironmentStyle.get(StyleProperty.Padding).left != 12.0)
			return 235;
		var inherited = new ComputedStyle();
		inherited.set(StyleProperty.TextColor, Color.rgba(0.7, 0.7, 0.7, 1.0), null);
		var inheritedChild = new StyleResolver().resolve(new StyleTarget("label"), inherited);
		if (inheritedChild.get(StyleProperty.TextColor).red != 0.7)
			return 215;
		var inheritedResolver = new StyleResolver();
		var inheritedTarget = new StyleTarget("label", "inherited-cache-key");
		var inheritedFork = inherited.fork();
		var unchangedFork = inheritedFork.fork();
		inheritedResolver.resolve(inheritedTarget, inheritedFork);
		inheritedFork.set(StyleProperty.TextColor, Color.rgba(0.2, 0.2, 0.2, 1.0), null);
		var changedInherited = inheritedResolver.resolve(inheritedTarget, inheritedFork);
		var unchangedInherited = inheritedResolver.resolve(inheritedTarget, unchangedFork);
		if (changedInherited.get(StyleProperty.TextColor).red != 0.2 ||
			unchangedInherited.get(StyleProperty.TextColor).red != 0.7 ||
			inheritedResolver.cacheMisses != 2 || inheritedResolver.cacheHits != 1)
			return 268;
		var transitionSheet = new StyleSheet("TransitionSheet");
		transitionSheet.rule(StyleSelector.widget("button"),
			[StyleValue.background(Color.rgba(0.0, 0.0, 0.0, 1.0))]);
		transitionSheet.rule(StyleSelector.widget("button").state(StyleState.Hovered),
			[StyleValue.background(Color.rgba(1.0, 1.0, 1.0, 1.0))]);
		transitionSheet.transition(StyleProperty.Background, 0.1, Easing.Linear);
		var transitionScheduler = new AnimationScheduler();
		var transitionResolver = new StyleResolver(transitionScheduler);
		var transitionTarget = new StyleTarget("button", "transition-key", "transition-id",
			null, null, 0);
		var normalComputed = transitionResolver.resolve(transitionTarget, null, transitionSheet);
		transitionTarget = new StyleTarget("button", "transition-key", "transition-id",
			null, null, StyleState.Hovered);
		var animatedComputed = transitionResolver.resolve(transitionTarget, null, transitionSheet);
		if (animatedComputed.get(StyleProperty.Background).red != 0.0 ||
			transitionScheduler.activeCount != 1)
			return 216;
		transitionScheduler.advance(0.05);
		animatedComputed = transitionResolver.resolve(transitionTarget, null, transitionSheet);
		if (animatedComputed.get(StyleProperty.Background).red <= 0.0 ||
			animatedComputed.get(StyleProperty.Background).red >= 1.0)
			return 217;
		transitionScheduler.advance(0.05);
		animatedComputed = transitionResolver.resolve(transitionTarget, null, transitionSheet);
		if (animatedComputed.get(StyleProperty.Background).red != 1.0 ||
			transitionScheduler.activeCount != 0 || normalComputed.get(StyleProperty.Background).red != 0.0 ||
			transitionResolver.cacheHits != 0 || transitionResolver.cacheMisses != 0)
			return 218;
		var effectChain = EffectChain.of([
			BlurEffect.withSigma(12.0), new SaturateEffect(1.15)
		]);
		var effectOverflow = effectChain.inkOverflow();
		if (effectChain.effects.length != 2 || effectOverflow.left != 36.0 ||
			effectOverflow.top != 36.0 || effectOverflow.right != 36.0 ||
			effectOverflow.bottom != 36.0 || !effectChain.isEqual(effectChain.copy()))
			return 240;
		var normalizedEffects = EffectChain.of([
			new BrightnessEffect(1.2), new ContrastEffect(0.8), BlurEffect.withSigma(3.0),
			new SaturateEffect(1.1)
		]).normalized();
		if (normalizedEffects.effects.length != 3 ||
			normalizedEffects.effects[0].kind != EffectKind.ColorMatrix ||
			normalizedEffects.effects[1].kind != EffectKind.Blur ||
			normalizedEffects.effects[2].kind != EffectKind.ColorMatrix)
			return 242;
		var blurThenMatrix = EffectChain.of([
			BlurEffect.withSigma(2.0), new BrightnessEffect(1.2)
		]).normalized();
		var multipleBlurs = EffectChain.of([
			BlurEffect.withSigma(2.0), BlurEffect.withSigma(4.0)
		]).normalized();
		if (blurThenMatrix.effects.length != 2 ||
			blurThenMatrix.effects[0].kind != EffectKind.Blur ||
			blurThenMatrix.effects[1].kind != EffectKind.ColorMatrix ||
			multipleBlurs.effects.length != 2)
			return 246;
		var customDefinition = new CustomEffectDefinition(7, "wave", [
			EffectParameterType.Float, EffectParameterType.Color
		], new InkOverflow(2.0, 3.0, 4.0, 5.0));
		var custom = new CustomEffect(customDefinition, [
			EffectParameter.scalar(0.25),
			EffectParameter.color(Color.rgba(0.1, 0.2, 0.3, 0.4))
		]);
		var customCopy:CustomEffect = cast custom.copy();
		var customMid:CustomEffect = cast custom.interpolate(new CustomEffect(customDefinition, [
			EffectParameter.scalar(0.75),
			EffectParameter.color(Color.rgba(0.5, 0.6, 0.7, 0.8))
		]), 0.5);
		if (custom.components.length != 5 || custom.components[0] != 0.25 ||
			custom.components[4] != 0.4 || !custom.isEqual(customCopy) ||
			custom.inkOverflow().right != 4.0 || Math.abs(customMid.components[0] - 0.5) > 0.00001 ||
			Math.abs(customMid.components[1] - 0.3) > 0.00001)
			return 250;
		var customRuntime = new CustomEffect(new CustomEffectDefinition(8, "multiply", [
			EffectParameterType.Float
		], new InkOverflow(1.0, 1.0, 1.0, 1.0)), [EffectParameter.scalar(0.75)]);
		var mixedCustom = EffectChain.of([
			new BrightnessEffect(1.2), customRuntime, BlurEffect.withSigma(3.0)
		]).normalized();
		if (mixedCustom.effects.length != 3 ||
			mixedCustom.effects[0].kind != EffectKind.ColorMatrix ||
			mixedCustom.effects[1].kind != EffectKind.Custom ||
			mixedCustom.effects[2].kind != EffectKind.Blur)
			return 246;
		var interpolatedEffects = EffectChain.interpolate(
			EffectChain.of([BlurEffect.withSigma(4.0), new BrightnessEffect(1.0)]),
			EffectChain.of([BlurEffect.withSigma(12.0), new BrightnessEffect(2.0)]), 0.5);
		var interpolatedBlur:BlurEffect = cast interpolatedEffects.effects[0];
		var interpolatedBrightness:BrightnessEffect = cast interpolatedEffects.effects[1];
		if (interpolatedBlur == null || interpolatedBlur.sigma != 8.0 ||
			interpolatedBrightness == null || interpolatedBrightness.factor != 1.5)
			return 241;
		var effectTransitionSheet = new StyleSheet("EffectTransitionSheet");
		effectTransitionSheet.rule(StyleSelector.widget("panel"),
			[StyleValue.effects(EffectChain.of([BlurEffect.withSigma(4.0)]))]);
		effectTransitionSheet.rule(StyleSelector.widget("panel").state(StyleState.Hovered),
			[StyleValue.effects(EffectChain.of([BlurEffect.withSigma(12.0)]))]);
		effectTransitionSheet.transition(StyleProperty.Effects, 0.1, Easing.Linear);
		var effectTransitionScheduler = new AnimationScheduler();
		var effectTransitionResolver = new StyleResolver(effectTransitionScheduler);
		var effectTransitionTarget = new StyleTarget("panel", "effect-transition-key", "effect-transition-id",
			null, null, 0);
		effectTransitionResolver.resolve(effectTransitionTarget, null, effectTransitionSheet);
		effectTransitionTarget = new StyleTarget("panel", "effect-transition-key", "effect-transition-id",
			null, null, StyleState.Hovered);
		effectTransitionResolver.resolve(effectTransitionTarget, null, effectTransitionSheet);
		if (effectTransitionScheduler.activeCount != 1)
			return 245;
		effectTransitionScheduler.advance(0.05);
		var effectTransitionComputed = effectTransitionResolver.resolve(effectTransitionTarget, null,
			effectTransitionSheet);
		var effectTransitionBlur:BlurEffect = cast effectTransitionComputed.get(StyleProperty.Effects).effects[0];
		if (effectTransitionBlur == null || effectTransitionBlur.sigma != 8.0)
			return 246;
		var dropShadow = new DropShadowEffect(0.0, 6.0, 12.0,
			Color.rgba(0.0, 0.0, 0.0, 0.35));
		var matrixDropMatrix = EffectChain.of([
			new BrightnessEffect(1.2), dropShadow, new ContrastEffect(0.8)
		]).normalized();
		if (matrixDropMatrix.effects.length != 3 ||
			matrixDropMatrix.effects[0].kind != EffectKind.ColorMatrix ||
			matrixDropMatrix.effects[1].kind != EffectKind.DropShadow ||
			matrixDropMatrix.effects[2].kind != EffectKind.ColorMatrix)
			return 246;
		var dropOverflow = dropShadow.inkOverflow();
		if (dropOverflow.left != 36.0 || dropOverflow.top != 30.0 ||
			dropOverflow.right != 36.0 || dropOverflow.bottom != 42.0)
			return 242;
		var effectSheet = new StyleSheet("EffectSheet");
		effectSheet.rule(StyleSelector.widget("panel"), [
			StyleValue.effects(effectChain),
			StyleValue.backdropEffects(EffectChain.of([
				BlurEffect.withSigma(8.0), new ContrastEffect(1.1), HueRotateEffect.withDegrees(12.0),
				ColorMatrixEffect.identity(), dropShadow
			]))
		]);
		var effectTarget = new StyleTarget("panel", "effect-key");
		var effectComputed = new StyleResolver().resolve(effectTarget, null, null, effectSheet);
		var effectsSource = effectComputed.source(StyleProperty.Effects);
		var backdropSource = effectComputed.source(StyleProperty.BackdropEffects);
		if (!effectComputed.get(StyleProperty.Effects).isEqual(effectChain) ||
			effectsSource == null || effectsSource.stylesheet != "EffectSheet" ||
			backdropSource == null || !effectComputed.has(StyleProperty.BackdropEffects))
			return 243;
		var emptyEffects = new ComputedStyle();
		emptyEffects.set(StyleProperty.Effects, EffectChain.empty(), null);
		var changedEffects = new ComputedStyle();
		changedEffects.set(StyleProperty.Effects, effectChain, null);
		var effectsDiff = StyleDiff.compare(emptyEffects, changedEffects);
		var effectDescription = "";
		for (entry in effectComputed.entries())
			if (entry.name == "effects")
				effectDescription = entry.describe();
		if (!effectsDiff.changed || effectsDiff.impact != StyleImpact.Composite ||
			effectComputed.entries().length < StyleProperty.all().length ||
			effectDescription.indexOf("[blur(12") != 0)
			return 244;
		var decorationContractResult = decorationStyleContract();
		if (decorationContractResult != 0)
			return decorationContractResult;
		var colorAdjustments = EffectChain.of([
			new BrightnessEffect(2.0), new ContrastEffect(0.5)
		]);
		var colorMatrix = colorAdjustments.colorMatrix();
		if (colorMatrix.length != ColorMatrixEffect.ComponentCount ||
			colorMatrix[0] != 1.0 || colorMatrix[6] != 1.0 ||
			colorMatrix[12] != 1.0 || colorMatrix[18] != 1.0 ||
			colorMatrix[4] != 0.25 || colorMatrix[9] != 0.25 ||
			colorMatrix[14] != 0.25)
			return 247;
		var effectCanvas = new Canvas();
		var effectList = DisplayList.create();
		effectCanvas.withLayer(1.0, function(canvas) {
			canvas.fillRect(new Rect(4.0, 6.0, 24.0, 18.0), Color.rgba(0.2, 0.4, 0.8, 1.0));
		}, CompositeMode.SourceOver, new Rect(4.0, 6.0, 24.0, 18.0), colorAdjustments);
		effectCanvas.update(effectList);
		if (effectList.info().commandCount != 4)
			return 248;
		effectList.dispose();
		effectCanvas.reset();
		var boundedEmptyList = DisplayList.create();
		effectCanvas.withLayer(1.0, function(_) {}, CompositeMode.SourceOver,
			new Rect(4.0, 6.0, 24.0, 18.0));
		effectCanvas.update(boundedEmptyList);
		var boundedEmptyInfo = boundedEmptyList.info();
		if (boundedEmptyInfo.commandCount != 2 || boundedEmptyInfo.commandBytes >= 3220)
			return 256;
		boundedEmptyList.dispose();
		effectCanvas.reset();
		var customList = DisplayList.create();
		effectCanvas.withLayer(1.0, function(canvas) {
			canvas.fillRect(new Rect(4.0, 6.0, 24.0, 18.0), Color.rgba(0.2, 0.4, 0.8, 1.0));
		}, CompositeMode.SourceOver, new Rect(4.0, 6.0, 24.0, 18.0),
			EffectChain.of([customRuntime]));
		effectCanvas.update(customList);
		if (customList.info().commandCount != 4)
			return 251;
		customList.dispose();
		effectCanvas.reset();
		var blurList = DisplayList.create();
		effectCanvas.withLayer(1.0, function(canvas) {
			canvas.fillRect(new Rect(4.0, 6.0, 24.0, 18.0), Color.rgba(0.2, 0.4, 0.8, 1.0));
		}, CompositeMode.SourceOver, new Rect(4.0, 6.0, 24.0, 18.0),
			EffectChain.of([BlurEffect.withSigma(4.0)]));
		effectCanvas.update(blurList);
		if (blurList.info().commandCount != 4)
			return 249;
		blurList.dispose();
		effectCanvas.reset();
		var dropShadowList = DisplayList.create();
		effectCanvas.withLayer(1.0, function(canvas) {
			canvas.fillRect(new Rect(4.0, 6.0, 24.0, 18.0), Color.rgba(0.2, 0.4, 0.8, 1.0));
		}, CompositeMode.SourceOver, new Rect(4.0, 6.0, 24.0, 18.0),
			EffectChain.of([dropShadow]));
		effectCanvas.update(dropShadowList);
		if (dropShadowList.info().commandCount != 4)
			return 250;
		dropShadowList.dispose();
		effectCanvas.reset();
		var roundedMask = Mask.roundedRect(10.0);
		if (!roundedMask.isEqual(roundedMask.copy()))
			return 251;
		var maskSheet = new StyleSheet("MaskSheet");
		maskSheet.rule(StyleSelector.widget("panel"), [StyleValue.mask(roundedMask)]);
		var noMaskParent:Null<ComputedStyle> = null;
		var noMaskTheme:Null<StyleSheet> = null;
		var maskComputed = new StyleResolver().resolve(new StyleTarget("panel", "mask-key"),
			noMaskParent, noMaskTheme, maskSheet);
		var maskSource = maskComputed.source(StyleProperty.Mask);
		if (maskComputed.get(StyleProperty.Mask) == null ||
			!maskComputed.get(StyleProperty.Mask).isEqual(roundedMask) || maskSource == null ||
			maskSource.stylesheet != "MaskSheet")
			return 252;
		var emptyMask = new ComputedStyle();
		var noMask:Mask = null;
		var noMaskSource:Null<StyleSource> = null;
		emptyMask.set(StyleProperty.Mask, noMask, noMaskSource);
		var changedMask = new ComputedStyle();
		var typedMask:Mask = roundedMask;
		changedMask.set(StyleProperty.Mask, typedMask, noMaskSource);
		var maskDiff = StyleDiff.compare(emptyMask, changedMask);
		if (!maskDiff.changed || maskDiff.impact != StyleImpact.Composite)
			return 253;
		var maskList = DisplayList.create();
		var noMaskEffects:EffectChain = null;
		effectCanvas.withLayer(1.0, function(canvas) {
			canvas.fillRect(new Rect(4.0, 6.0, 24.0, 18.0), Color.rgba(0.2, 0.4, 0.8, 1.0));
		}, CompositeMode.SourceOver, new Rect(4.0, 6.0, 24.0, 18.0),
			noMaskEffects, roundedMask);
		effectCanvas.update(maskList);
		if (maskList.info().commandCount != 4)
			return 254;
		maskList.dispose();
		effectCanvas.reset();
		var backdropList = DisplayList.create();
		effectCanvas.withLayer(1.0, function(canvas) {
			canvas.fillRect(new Rect(4.0, 6.0, 24.0, 18.0), Color.rgba(0.2, 0.4, 0.8, 1.0));
		}, CompositeMode.SourceOver, new Rect(4.0, 6.0, 24.0, 18.0), null, null,
			EffectChain.of([new BrightnessEffect(1.1)]));
		effectCanvas.update(backdropList);
		if (backdropList.info().commandCount != 4)
			return 255;
		backdropList.dispose();
		effectCanvas.reset();
		var eightOperations = EffectChain.of([
			BlurEffect.withSigma(1.0), BlurEffect.withSigma(2.0), BlurEffect.withSigma(3.0),
			BlurEffect.withSigma(4.0), BlurEffect.withSigma(5.0), BlurEffect.withSigma(6.0),
			BlurEffect.withSigma(7.0), BlurEffect.withSigma(8.0)
		]);
		var eightOperationCanvas = new Canvas();
		var eightOperationList = DisplayList.create();
		eightOperationCanvas.beginLayer(1.0, CompositeMode.SourceOver, null, eightOperations);
		eightOperationCanvas.endLayer();
		eightOperationCanvas.update(eightOperationList);
		eightOperationList.dispose();
		var rejectedNineOperations = false;
		try {
			new Canvas().beginLayer(1.0, CompositeMode.SourceOver, null, EffectChain.of([
				BlurEffect.withSigma(1.0), BlurEffect.withSigma(2.0), BlurEffect.withSigma(3.0),
				BlurEffect.withSigma(4.0), BlurEffect.withSigma(5.0), BlurEffect.withSigma(6.0),
				BlurEffect.withSigma(7.0), BlurEffect.withSigma(8.0), BlurEffect.withSigma(9.0)
			]));
		} catch (_:Dynamic) {
			rejectedNineOperations = true;
		}
		if (!rejectedNineOperations)
			return 257;
		var responsiveSheet = new StyleSheet("ResponsiveSheet");
		responsiveSheet.rule(StyleSelector.widget("button"),
			[StyleValue.paddingSymmetric(12.0, 8.0)]);
		responsiveSheet.when(Environment.widthLessThan(600.0), StyleSelector.widget("button"),
			[StyleValue.paddingSymmetric(6.0, 4.0)]);
		responsiveSheet.when(Environment.colorScheme(EnvironmentColorScheme.Dark),
			StyleSelector.widget("button"),
			[StyleValue.background(Color.rgba(0.05, 0.05, 0.05, 1.0))]);
		var responsiveEnvironment = new StyleEnvironment(500.0, 800.0);
		var responsive = new StyleResolver().resolve(transitionTarget, null, null,
			responsiveSheet, null, responsiveEnvironment);
		if (responsive.get(StyleProperty.Padding).left != 6.0)
			return 219;
		responsiveEnvironment.setViewport(800.0, 500.0);
		responsiveEnvironment.colorScheme = EnvironmentColorScheme.Dark;
		responsive = new StyleResolver().resolve(transitionTarget, null, null,
			responsiveSheet, null, responsiveEnvironment);
		if (responsive.get(StyleProperty.Padding).left != 12.0 ||
			responsive.get(StyleProperty.Background).red != 0.05)
			return 220;
		var inheritanceSheet = new StyleSheet("InheritanceSheet");
		inheritanceSheet.rule(StyleSelector.key("inherit-parent"), [
			StyleValue.textColor(Color.rgba(0.75, 0.25, 0.15, 1.0)), StyleValue.fontSize(22.0)]);
		context.setStyleSheet(inheritanceSheet);
		var inheritanceRoot = context.submit(new Column("inherit-parent", [
			new KeyedView("inherited-label", new Text("Inherited"))
		]), new LayoutFrame(256.0, 192.0));
		var inheritedTextNode = inheritanceRoot.children[0];
		var inheritedTextSource:Null<StyleSource> = inheritedTextNode.computedStyle == null ? null :
			inheritedTextNode.computedStyle.source(StyleProperty.TextColor);
		if (inheritedTextNode.computedStyle == null ||
			inheritedTextNode.computedStyle.get(StyleProperty.TextColor).red != 0.75 ||
			inheritedTextNode.computedStyle.get(StyleProperty.FontSize) != 22.0 ||
			inheritedTextSource == null || inheritedTextSource.stylesheet != "InheritanceSheet")
			return 224;
		context.setStyleSheet(new StyleSheet("Application"));
		var lightNeutral = Color.rgba(0.87, 0.90, 0.95, 1.0);
		var accentButton = Color.rgba(0.18, 0.39, 0.70, 1.0);
		if (theme.buttonLabelColor(true, lightNeutral) != theme.body.color ||
			theme.buttonLabelColor(true, accentButton) != theme.button.color ||
			theme.buttonLabelColor(false, accentButton) != theme.disabledButtonText)
			return 101;
		theme.buttonHover = Color.rgba(0.8, 0.1, 0.1, 1.0);
		theme.buttonPressed = Color.rgba(0.7, 0.05, 0.05, 1.0);
		theme.buttonFocused = Color.rgba(0.4, 0.2, 0.8, 1.0);
		theme.buttonDisabled = Color.rgba(0.2, 0.2, 0.2, 1.0);
		theme.body.textStyle = new TextStyle(17.0, FontFamily.Default, -0.25);
		theme.body.paragraphStyle = new ParagraphStyle(TextWrap.Word, TextAlignment.Start, 21.0,
			TextDirection.Ltr);
		theme.heading.textStyle = new TextStyle(26.0);
		theme.label.textStyle = new TextStyle(13.0);
		theme.label.color = Color.rgba(0.32, 0.58, 0.76, 1.0);
		theme.caption.textStyle = new TextStyle(11.0);
		theme.button.textStyle = new TextStyle(15.0);
		context.setTheme(theme);
		if (!UiDirtyFlag.contains(context.dirtyFlags, UiDirtyFlag.NeedsStyle) ||
			!UiDirtyFlag.contains(context.dirtyFlags, UiDirtyFlag.NeedsPaint))
			return 222;
		var themedTextRoot = context.submit(new Text("Theme typography"),
			new LayoutFrame(256.0, 192.0));
		if (themedTextRoot.layout.textStyle.fontSize != 17.0 ||
			themedTextRoot.layout.textStyle.letterSpacing != -0.25 ||
			themedTextRoot.layout.paragraphStyle.wrap != TextWrap.Word ||
			themedTextRoot.layout.paragraphStyle.lineHeight != 21.0 ||
			themedTextRoot.layout.paragraphStyle.direction != TextDirection.Ltr ||
			themedTextRoot.layout.textColor != theme.body.color)
			return 214;
		var roleRoot = context.submit(new Column("text-roles", [
			new KeyedView("body", new Text("Body")),
			new KeyedView("heading", new Text("Heading", null, null, null, TextRole.Heading)),
			new KeyedView("label", new Text("Label", null, null, null, TextRole.Label)),
			new KeyedView("caption", new Text("Caption", null, null, null, TextRole.Caption)),
			new KeyedView("button", new Text("Button", null, null, null, TextRole.Button))
		]), new LayoutFrame(320.0, 320.0));
		if (roleRoot.children[0].layout.textStyle.fontSize != 17.0)
			return 218;
		if (roleRoot.children[1].layout.textStyle.fontSize != 26.0)
			return 219;
		if (roleRoot.children[2].layout.textStyle.fontSize != 13.0 ||
			roleRoot.children[2].layout.textColor != theme.label.color)
			return 220;
		if (roleRoot.children[2].layout.paragraphStyle.wrap != TextWrap.None)
			return 223;
		if (roleRoot.children[3].layout.textStyle.fontSize != 11.0 ||
			roleRoot.children[3].layout.textColor != theme.caption.color)
			return 221;
		if (roleRoot.children[4].layout.textStyle.fontSize != 15.0 ||
			roleRoot.children[4].layout.paragraphStyle.wrap != TextWrap.None)
			return 222;
		var appShell = new AppShell("app-shell-smoke", new Text("Content"),
			new Text("Top bar"), new Text("Sidebar"), new Text("Inspector"));
		var appShellRoot = context.submit(appShell, new LayoutFrame(320.0, 192.0));
		if (appShellRoot.children.length != 2 ||
			appShellRoot.children[0].layout.visualKind != LayoutVisualKind.Text ||
			appShellRoot.children[1].layout.style.direction != LayoutDirection.LeftToRight ||
			appShellRoot.children[1].children.length != 3)
			return 224;
		var appShellBody = appShellRoot.children[1];
		var appShellContentSlot = appShellBody.children[1];
		if (appShellBody.children[0].layout.visualKind != LayoutVisualKind.Text ||
			appShellContentSlot.children.length != 1 ||
			appShellContentSlot.children[0].layout.visualKind != LayoutVisualKind.Text ||
			appShellBody.children[2].layout.visualKind != LayoutVisualKind.Text ||
			appShellContentSlot.resolved == null ||
			appShellContentSlot.resolved.width <= 0.0 ||
			appShellContentSlot.resolved.height <= 0.0)
			return 225;
		var shellWithBottom = new AppShell("app-shell-bottom-smoke", new Text("Content"),
			new Text("Top bar"), null, null, null, null, new Text("Bottom bar"));
		var bottomRoot = context.submit(shellWithBottom, new LayoutFrame(320.0, 192.0));
		var bottomBody = bottomRoot.children[1].resolved;
		var bottomBar = bottomRoot.children[2].resolved;
		if (bottomRoot.children.length != 3 ||
			bottomRoot.children[2].layout.text != "Bottom bar" ||
			bottomBody == null || bottomBar == null ||
			bottomBody.y + bottomBody.height > bottomBar.y)
			return 228;
		for (mask in 0...8) {
			var hasTopBar = (mask & 1) != 0;
			var hasSidebar = (mask & 2) != 0;
			var hasInspector = (mask & 4) != 0;
			var permutation = new AppShell('app-shell-permutation-$mask', new Text("Content"),
				hasTopBar ? new Text("Top bar") : null,
				hasSidebar ? new Text("Sidebar") : null,
				hasInspector ? new Text("Inspector") : null);
			var permutationRoot = context.submit(permutation, new LayoutFrame(320.0, 192.0));
			var bodyIndex = hasTopBar ? 1 : 0;
			var expectedBodyChildren = 1 + (hasSidebar ? 1 : 0) + (hasInspector ? 1 : 0);
			if (permutationRoot.children.length != (hasTopBar ? 2 : 1) ||
				permutationRoot.children[bodyIndex].children.length != expectedBodyChildren)
				return 226;
			var permutationBody = permutationRoot.children[bodyIndex];
			var contentIndex = hasSidebar ? 1 : 0;
			var permutationContent = permutationBody.children[contentIndex];
			if (permutationContent.children.length != 1 || permutationContent.resolved == null ||
				permutationContent.resolved.width <= 0.0 || permutationContent.resolved.height <= 0.0)
				return 227;
			var rebuiltRoot = context.submit(permutation, new LayoutFrame(320.0, 192.0));
			var rebuiltBody = rebuiltRoot.children[bodyIndex];
			if (!permutationRoot.id.equals(rebuiltRoot.id) ||
				!permutationContent.id.equals(rebuiltBody.children[contentIndex].id))
				return 228;
		}
		var sourceStyle = new LayoutStyle();
		sourceStyle.width = LayoutAxis.fixed(280.0);
		sourceStyle.height = LayoutAxis.fixed(120.0);
		sourceStyle.padding = new Insets(11.0, 12.0, 13.0, 14.0);
		var sourceBodyStyle = new LayoutStyle();
		sourceBodyStyle.direction = LayoutDirection.TopToBottom;
		sourceBodyStyle.childGap = 17.0;
		var copiedAppShell = new AppShell("app-shell-style-copy", new Text("Content"),
			null, null, null, sourceStyle, sourceBodyStyle);
		sourceStyle.width = LayoutAxis.fixed(1.0);
		// Insets are immutable, so a later change to the source is a replacement, and the copy must keep the old value.
		sourceStyle.padding = new Insets(1.0, 12.0, 13.0, 14.0);
		sourceBodyStyle.childGap = 1.0;
		if (copiedAppShell.style.width.value != 280.0 ||
			copiedAppShell.style.padding.left != 11.0 ||
			copiedAppShell.bodyStyle.childGap != 17.0 ||
			copiedAppShell.bodyStyle.direction != LayoutDirection.LeftToRight ||
			sourceBodyStyle.direction != LayoutDirection.TopToBottom)
			return 229;
		var resizedExtent = 0.0;
		var splitOptions = new SplitViewOptions();
		splitOptions.resizableSide = SplitSide.Trailing;
		splitOptions.extent = 96.0;
		splitOptions.minimumExtent = 64.0;
		splitOptions.maximumExtent = 144.0;
		splitOptions.onResize = function(value) { resizedExtent = value; };
		var split = new SplitView("split-smoke", new Text("Primary"),
			new Text("Secondary"), splitOptions);
		var splitRoot = context.submit(split, new LayoutFrame(320.0, 192.0));
		if (splitRoot.children.length != 3 ||
			splitRoot.children[0].children.length != 1 ||
			splitRoot.children[2].children.length != 1)
			return 230;
		var splitDividerSemantics:Semantics = cast splitRoot.children[1].semantics;
		if (splitDividerSemantics == null ||
			splitDividerSemantics.role != AccessibilityRole.Separator ||
			!splitRoot.children[1].focusable ||
			(splitDividerSemantics.actions & AccessibilityAction.Increment) == 0 ||
			(splitDividerSemantics.actions & AccessibilityAction.Decrement) == 0)
			return 230;
		var splitDividerGeometry:ResolvedLayoutItem = cast splitRoot.children[1].resolved;
		var splitPointerX = splitDividerGeometry.x + splitDividerGeometry.width * 0.5;
		var splitPointerY = splitDividerGeometry.y + splitDividerGeometry.height * 0.5;
		context.pointerMove(splitPointerX, splitPointerY);
		if (context.events.cursorShape() != UiCursorShape.HorizontalResize)
			return 236;
		context.pointerDown(splitPointerX, splitPointerY, 0);
		// The native showcase rebuilds its view tree between input events. The
		// divider must retain the active drag across that frame boundary.
		splitRoot = context.submit(split, new LayoutFrame(320.0, 192.0));
		context.pointerMove(splitPointerX + 20.0, splitPointerY);
		if (context.events.cursorShape() != UiCursorShape.HorizontalResize)
			return 237;
		context.pointerUp(splitPointerX + 20.0, splitPointerY, 0);
		if (resizedExtent != 76.0 || split.extent != 76.0)
			return 231;
		context.pointerMove(splitPointerX, splitPointerY);
		context.pointerDown(splitPointerX, splitPointerY, 0);
		context.pointerCancel(0, splitPointerX + 40.0, splitPointerY);
		if (context.events.cursorShape() != UiCursorShape.Arrow)
			return 238;
		split.collapsed = true;
		splitRoot = context.submit(split, new LayoutFrame(320.0, 192.0));
		var collapsedSecondaryGeometry:ResolvedLayoutItem = cast splitRoot.children[2].resolved;
		if (splitRoot.children[2].layout.style.visible ||
			collapsedSecondaryGeometry.width != 0.0)
			return 232;
		split.collapsed = false;
		var expandedSplitRoot = context.submit(split, new LayoutFrame(320.0, 192.0));
		if (!expandedSplitRoot.children[2].layout.style.visible ||
			!splitRoot.children[2].id.equals(expandedSplitRoot.children[2].id))
			return 233;
		var verticalOptions = new SplitViewOptions();
		verticalOptions.orientation = SplitOrientation.Vertical;
		verticalOptions.resizableSide = SplitSide.Trailing;
		verticalOptions.extent = 72.0;
		verticalOptions.minimumExtent = 48.0;
		verticalOptions.maximumExtent = 120.0;
		verticalOptions.onResize = function(value) { resizedExtent = value; };
		var verticalSplit = new SplitView("vertical-split-smoke", new Text("Top"),
			new Text("Bottom"), verticalOptions);
		var verticalRoot = context.submit(verticalSplit, new LayoutFrame(320.0, 192.0));
		if (verticalRoot.children.length != 3 ||
			verticalRoot.layout.style.direction != LayoutDirection.TopToBottom)
			return 234;
		var verticalDividerGeometry:ResolvedLayoutItem = cast verticalRoot.children[1].resolved;
		var verticalPointerX = verticalDividerGeometry.x + verticalDividerGeometry.width * 0.5;
		var verticalPointerY = verticalDividerGeometry.y + verticalDividerGeometry.height * 0.5;
		context.pointerMove(verticalPointerX, verticalPointerY);
		if (context.events.cursorShape() != UiCursorShape.VerticalResize)
			return 239;
		context.pointerDown(verticalPointerX, verticalPointerY, 0);
		context.pointerMove(verticalPointerX, verticalPointerY + 20.0);
		if (context.events.cursorShape() != UiCursorShape.VerticalResize)
			return 240;
		context.pointerUp(verticalPointerX, verticalPointerY + 20.0, 0);
		if (resizedExtent != 52.0 || verticalSplit.extent != 52.0)
			return 235;
		var captureClicks = 0;
		var captureOptions = new SplitViewOptions();
		captureOptions.resizableSide = SplitSide.Trailing;
		captureOptions.extent = 120.0;
		var captureSplit = new SplitView("pointer-capture-split", new Text("Leading"),
			new Button("Drag target", null, function() { captureClicks++; }), captureOptions);
		var captureRoot = context.submit(captureSplit, new LayoutFrame(320.0, 192.0));
		var platformCaptureStates:Array<Bool> = [];
		context.setPointerCaptureHandler(function(captured) platformCaptureStates.push(captured));
		var captureDivider = captureRoot.children[1];
		var captureButton = captureRoot.children[2].children[0];
		var captureHoverEnters = 0;
		var capturePointerDowns = 0;
		captureButton.on(UiEventKind.HoverEnter, function(_) { captureHoverEnters++; });
		captureButton.on(UiEventKind.PointerDown, function(_) { capturePointerDowns++; });
		var captureDividerGeometry:ResolvedLayoutItem = cast captureDivider.resolved;
		var captureButtonGeometry:ResolvedLayoutItem = cast captureButton.resolved;
		var captureDividerX = captureDividerGeometry.x + captureDividerGeometry.width * 0.5;
		var captureDividerY = captureDividerGeometry.y + captureDividerGeometry.height * 0.5;
		var captureButtonX = captureButtonGeometry.x + 2.0;
		var captureButtonY = captureButtonGeometry.y + 2.0;
		context.pointerMove(captureDividerX, captureDividerY);
		context.pointerDown(captureDividerX, captureDividerY, 0);
		if (!context.events.hasPointerCapture(captureDivider.id) || platformCaptureStates.length != 1 ||
			!platformCaptureStates[0])
			return 248;
		context.pointerLeave();
		if (!context.events.hasPointerCapture(captureDivider.id) ||
			platformCaptureStates.length != 1)
			return 248;
		context.pointerMove(captureDividerX - 15.0, captureDividerY);
		if (captureSplit.extent != 175.0)
			return 248;
		context.pointerMove(captureDividerX, captureDividerY);
		// Physical capture is shared by the window, while logical capture stays
		// independent per pointer. Releasing pointer 1 must not release pointer 0.
		context.pointerDown(captureDividerX, captureDividerY, 0, 0, 1);
		if (!context.events.hasPointerCapture(captureDivider.id, 1) ||
			platformCaptureStates.length != 1)
			return 253;
		context.pointerUp(captureDividerX, captureDividerY, 0, 0, 1);
		if (context.events.hasPointerCapture(captureDivider.id, 1) ||
			!context.events.hasPointerCapture(captureDivider.id) || platformCaptureStates.length != 1)
			return 254;
		context.pointerMove(captureButtonX, captureButtonY);
		if (captureHoverEnters != 0 || capturePointerDowns != 0 || captureClicks != 0 ||
			context.events.hoveredId() == null ||
			!context.events.hoveredId().equals(captureDivider.id) ||
			context.events.cursorShape() != UiCursorShape.HorizontalResize)
			return 249;
		context.pointerUp(captureButtonX, captureButtonY, 0);
		if (captureHoverEnters != 1 || captureClicks != 0 ||
			context.events.hasPointerCapture(captureDivider.id) ||
			platformCaptureStates.length != 2 || platformCaptureStates[1] ||
			context.events.hoveredId() == null ||
			!context.events.hoveredId().equals(captureButton.id) ||
			context.events.cursorShape() != UiCursorShape.Arrow)
			return 250;
		context.pointerMove(captureDividerX, captureDividerY);
		context.pointerDown(captureDividerX, captureDividerY, 0);
		context.pointerMove(captureButtonX, captureButtonY);
		context.pointerCancel(0, captureButtonX, captureButtonY);
		if (context.events.hasPointerCapture(captureDivider.id) ||
			platformCaptureStates.length != 4 || !platformCaptureStates[2] || platformCaptureStates[3] ||
			context.events.hoveredId() != null ||
			context.events.cursorShape() != UiCursorShape.Arrow)
			return 251;
		// Detaching the host bridge releases the OS capture but preserves the
		// logical owner; reattaching must immediately restore physical capture.
		context.pointerMove(captureDividerX, captureDividerY);
		context.pointerDown(captureDividerX, captureDividerY, 0);
		if (!context.events.hasPointerCapture(captureDivider.id) || platformCaptureStates.length != 5)
			return 255;
		context.setPointerCaptureHandler(null);
		if (!context.events.hasPointerCapture(captureDivider.id) || platformCaptureStates.length != 6 ||
			platformCaptureStates[5])
			return 256;
		context.setPointerCaptureHandler(function(captured) platformCaptureStates.push(captured));
		if (!context.events.hasPointerCapture(captureDivider.id) || platformCaptureStates.length != 7 ||
			!platformCaptureStates[6])
			return 257;
		context.windowFocusLost();
		if (context.events.hasPointerCapture(captureDivider.id) || platformCaptureStates.length != 8 ||
			platformCaptureStates[7] || context.events.hoveredId() != null)
			return 258;
		context.pointerMove(captureDividerX, captureDividerY);
		context.pointerDown(captureDividerX, captureDividerY, 0);
		context.submit(new Text("Unmounted capture owner"), new LayoutFrame(320.0, 192.0));
		if (context.events.hasPointerCapture(captureDivider.id) || platformCaptureStates.length != 10 ||
			!platformCaptureStates[8] || platformCaptureStates[9])
			return 252;
		context.setPointerCaptureHandler(null);
		if (!checkSplitKeyboard(context))
			return 247;
		var reentryOptions = new SplitViewOptions();
		reentryOptions.extent = 200.0;
		var reentrySplit = new SplitView("reentry-split", new Text("First"),
			new Text("Second"), reentryOptions);
		var reentryRoot = context.submit(reentrySplit, new LayoutFrame(400.0, 192.0));
		var reentryDivider = reentryRoot.children[1];
		var reentryGeometry:ResolvedLayoutItem = cast reentryDivider.resolved;
		var reentryX = reentryGeometry.x + reentryGeometry.width * 0.5;
		var reentryY = reentryGeometry.y + reentryGeometry.height * 0.5;
		context.pointerDown(reentryX, reentryY, 0);
		context.pointerLeave();
		if (!context.events.hasPointerCapture(reentryDivider.id))
			return 248;
		context.pointerReenter(false, reentryX, reentryY);
		if (context.events.hasPointerCapture(reentryDivider.id))
			return 248;
		context.pointerMove(reentryX - 20.0, reentryY);
		if (reentrySplit.extent != 200.0)
			return 248;
		var inheritedColor = Color.rgba(0.24, 0.31, 0.42, 1.0);
		var nestedColor = Color.rgba(0.76, 0.42, 0.18, 1.0);
		var typography = new DefaultTextStyle(new Column("typography", [
			new KeyedView("outer", new Text("Outer")),
			new KeyedView("nested", new DefaultTextStyle(new Text("Nested"),
				TextStyleOverride.text(28.0, null, nestedColor))),
			new KeyedView("after", new Text("After"))
		]), TextStyleOverride.combine(
			TextStyleOverride.text(22.0, 1.25, inheritedColor),
			TextStyleOverride.paragraph(null, TextAlignment.Center, 30.0, TextDirection.Rtl)));
		var typographyRoot = context.submit(typography, new LayoutFrame(320.0, 192.0));
		var outerText = typographyRoot.children[0];
		var nestedText = typographyRoot.children[1];
		var afterText = typographyRoot.children[2];
		if (outerText.layout.textStyle.fontSize != 22.0 ||
			outerText.layout.textStyle.letterSpacing != 1.25 ||
			outerText.layout.paragraphStyle.alignment != TextAlignment.Center ||
			outerText.layout.paragraphStyle.lineHeight != 30.0 ||
			outerText.layout.paragraphStyle.direction != TextDirection.Rtl ||
			outerText.layout.textColor != inheritedColor ||
			nestedText.layout.textStyle.fontSize != 28.0 ||
			nestedText.layout.textStyle.letterSpacing != 1.25 ||
			nestedText.layout.paragraphStyle.alignment != TextAlignment.Center ||
			nestedText.layout.textColor != nestedColor ||
			afterText.layout.textStyle.fontSize != 22.0 ||
			afterText.layout.textColor != inheritedColor)
			return 215;
		var inheritedField = new TextField("inherited-style-field", "edit");
		var inheritedFieldRoot = context.submit(new DefaultTextStyle(inheritedField,
			TextStyleOverride.text(19.0)), new LayoutFrame(320.0, 192.0));
		if (inheritedFieldRoot.children[0].children[0].layout.textStyle.fontSize != 19.0)
			return 216;
		inheritedFieldRoot = context.submit(new DefaultTextStyle(inheritedField,
			TextStyleOverride.text(23.0)), new LayoutFrame(320.0, 192.0));
		var inheritedEditorState:State<TextEditorState> =
			context.buildContext.existingState(inheritedFieldRoot.id);
		var inheritedEditor:TextEditorState = cast inheritedEditorState.value;
		if (inheritedFieldRoot.children[0].children[0].layout.textStyle.fontSize != 23.0 ||
			inheritedEditor.textStyle.fontSize != 23.0)
			return 217;
		var themedClicks = 0;
		var themedButton = new Button("Themed", null, function() { themedClicks++; }, "theme-key");
		themedButton.variant = ButtonVariant.Primary;
		var themedFrame = new LayoutFrame(256.0, 192.0);
		var themedRoot = context.submit(themedButton, themedFrame);
		if (!frameMetricsValid(context, false))
			return 236;
		if (!context.focusWidget(themedRoot.id))
			return 80;
		themedRoot = context.submit(themedButton, themedFrame);
		if (themedRoot.layout.style.background.red != 0.4)
			return 81;
		themedRoot = context.submit(themedButton, themedFrame);
		if (!frameMetricsValid(context, true))
			return 237;
		if (!frameInvalidationValid(context, false, false))
			return 238;
		var themedLabelGeometry:ResolvedLayoutItem = cast themedRoot.children[0].resolved;
		var themedX = themedLabelGeometry.x + themedLabelGeometry.width * 0.5;
		var themedY = themedLabelGeometry.y + themedLabelGeometry.height * 0.5;
		context.pointerMove(themedX, themedY);
		themedRoot = context.submit(themedButton, themedFrame);
		var themedSnapshot = context.inspect();
		if (themedRoot.layout.style.background.red != 0.8 || !themedSnapshot[0].hovered ||
			themedSnapshot[1].hovered)
			return 82;
		if (!frameInvalidationValid(context, true, true))
			return 239;
		context.pointerDown(themedX, themedY, 0);
		themedRoot = context.submit(themedButton, themedFrame);
		themedSnapshot = context.inspect();
		if (themedRoot.layout.style.background.red != 0.7 || !themedSnapshot[0].pressed ||
			themedSnapshot[1].pressed)
			return 83;
		context.pointerUp(themedX, themedY, 0);
		if (themedClicks != 1 || context.inspect()[0].pressed)
			return 84;
		themedButton.enabled = false;
		themedRoot = context.submit(themedButton, themedFrame);
		if (themedRoot.layout.style.background.red != 0.2)
			return 85;
		var inspected = context.inspect();
		var inspectedBackgroundSource:Null<StyleSource> = inspected[0].computedStyle == null
			? null : inspected[0].computedStyle.source(StyleProperty.Background);
		if (inspected.length != 2 || inspected[0].label != "Themed" ||
			inspected[1].parentId != inspected[0].id || context.dumpTree().length == 0 ||
			context.auditAccessibility().length != 0 || inspected[0].styleType != "button" ||
			inspected[0].computedStyle == null ||
			inspectedBackgroundSource == null || inspectedBackgroundSource.selector != "button:disabled" ||
			(inspected[0].interactionStates & StyleState.Disabled) == 0)
			return 99;
		var inspectorEffects = new StyleSheet("InspectorEffects");
		inspectorEffects.rule(StyleSelector.widget("button"), [
			StyleValue.effects(EffectChain.of([BlurEffect.withSigma(4.0)])),
			StyleValue.backdropEffects(EffectChain.of([new BrightnessEffect(1.1)])),
			StyleValue.mask(Mask.roundedRect(6.0))
		]);
		context.setStyleSheet(inspectorEffects);
		context.submit(new Button("Inspector effects", null, function() {}, "inspector-effects"),
			new LayoutFrame(256.0, 192.0));
		var effectSnapshot = context.inspect()[0];
		if (!effectSnapshot.causesIsolation || effectSnapshot.effectPasses != 3 ||
			effectSnapshot.backdropEffectPasses != 1 || effectSnapshot.maskPasses != 1 ||
			effectSnapshot.effectDescriptions.length != 1 ||
			effectSnapshot.backdropEffectDescriptions.length != 1 ||
			effectSnapshot.isolationReasons.join(",") != "effects,backdrop-effects,mask" ||
			effectSnapshot.estimatedIntermediateTargets != 5 ||
			effectSnapshot.inkOverflow.left != 12.0 ||
			effectSnapshot.paintBounds.width <= effectSnapshot.bounds.width ||
			effectSnapshot.estimatedRenderTargetBytes <= 0.0)
			return 101;
		context.setStyleSheet(new StyleSheet("Application"));
		var unnamedSemantics:Semantics = cast themedRoot.semantics;
		unnamedSemantics.label = "";
		if (AccessibilityAudit.isValid(themedRoot))
			return 100;
		var navigationTokens = new ThemeTokens();
		navigationTokens.navigationBackground = Color.rgba(0.11, 0.12, 0.13, 1.0);
		navigationTokens.navigationHover = Color.rgba(0.31, 0.32, 0.33, 1.0);
		context.setTheme(new Theme(navigationTokens));
		var navigationButton = new Button("Navigation");
		navigationButton.variant = ButtonVariant.Navigation;
		var navigationRoot = context.submit(navigationButton, themedFrame);
		if (navigationRoot.styleClasses.indexOf("navigation") < 0 ||
			navigationRoot.layout.style.background.red != 0.11)
			return 240;
		var navigationGeometry:ResolvedLayoutItem = cast navigationRoot.resolved;
		context.pointerMove(navigationGeometry.x + 2.0, navigationGeometry.y + 2.0);
		navigationRoot = context.submit(navigationButton, themedFrame);
		if (navigationRoot.layout.style.background.red != 0.31)
			return 241;

		// Remaining widgets resolve through the same application cascade, including
		// paint-only properties consumed by their retained custom painters.
		var migratedStyles = new StyleSheet("MigratedWidgets");
		migratedStyles.rule(StyleSelector.widget("slider"), [
			StyleValue.sliderTrackColor(Color.rgba(0.11, 0.12, 0.14, 1.0)),
			StyleValue.sliderFillColor(Color.rgba(0.91, 0.31, 0.18, 1.0)),
			StyleValue.sliderThumbColor(Color.rgba(0.98, 0.98, 0.98, 1.0))
		]);
		migratedStyles.rule(StyleSelector.widget("progress-bar"), [
			StyleValue.progressTrackColor(Color.rgba(0.12, 0.13, 0.15, 1.0)),
			StyleValue.progressFillColor(Color.rgba(0.20, 0.78, 0.42, 1.0))
		]);
		migratedStyles.rule(StyleSelector.widget("popup-content"), [
			StyleValue.background(Color.rgba(0.18, 0.12, 0.22, 1.0))
		]);
		migratedStyles.rule(StyleSelector.widget("tooltip"), [
			StyleValue.background(Color.rgba(0.92, 0.72, 0.12, 1.0))
		]);
		context.setStyleSheet(migratedStyles);
		var migratedSlider = new Slider("migrated-slider", "Level", 0.5);
		var migratedSliderRoot = context.submit(migratedSlider, new LayoutFrame(256.0, 192.0));
		var sliderFillSource:Null<StyleSource> = migratedSliderRoot.computedStyle == null ? null :
			migratedSliderRoot.computedStyle.source(StyleProperty.SliderFillColor);
		if (migratedSliderRoot.computedStyle == null ||
			migratedSliderRoot.computedStyle.get(StyleProperty.SliderFillColor).red != 0.91 ||
			sliderFillSource == null || sliderFillSource.stylesheet != "MigratedWidgets" ||
			migratedSliderRoot.styleType != "slider")
			return 226;
		var migratedProgressRoot = context.submit(new ProgressBar("migrated-progress", 0.5),
			new LayoutFrame(256.0, 192.0));
		var progressFillSource:Null<StyleSource> = migratedProgressRoot.computedStyle == null ? null :
			migratedProgressRoot.computedStyle.source(StyleProperty.ProgressFillColor);
		if (migratedProgressRoot.computedStyle == null ||
			migratedProgressRoot.computedStyle.get(StyleProperty.ProgressFillColor).green != 0.78 ||
			progressFillSource == null || progressFillSource.stylesheet != "MigratedWidgets")
			return 227;
		var migratedPopupRoot = context.submit(new Popup("migrated-popup", new Text("Popup")),
			new LayoutFrame(256.0, 192.0));
		var migratedPopupPanel = migratedPopupRoot.children[1];
		var popupBackgroundSource:Null<StyleSource> = migratedPopupPanel.computedStyle == null ? null :
			migratedPopupPanel.computedStyle.source(StyleProperty.Background);
		if (migratedPopupPanel.computedStyle == null ||
			migratedPopupPanel.computedStyle.get(StyleProperty.Background).red != 0.18 ||
			popupBackgroundSource == null || popupBackgroundSource.stylesheet != "MigratedWidgets" ||
			migratedPopupPanel.styleType != "popup-content")
			return 228;
		var migratedTooltipRoot = context.submit(
			new Tooltip("migrated-tooltip", new Text("Anchor"), new Text("Hint")),
			new LayoutFrame(256.0, 192.0));
		var migratedTooltipNode = migratedTooltipRoot.children[1];
		var tooltipBackgroundSource:Null<StyleSource> = migratedTooltipNode.computedStyle == null ? null :
			migratedTooltipNode.computedStyle.source(StyleProperty.Background);
		if (migratedTooltipNode.computedStyle == null ||
			migratedTooltipNode.computedStyle.get(StyleProperty.Background).red != 0.92 ||
			tooltipBackgroundSource == null || tooltipBackgroundSource.stylesheet != "MigratedWidgets")
			return 229;
		context.setStyleSheet(new StyleSheet("Application"));

		var taps = 0;
		var doubleTaps = 0;
		var longPresses = 0;
		var dragStarts = 0;
		var dragMoves = 0;
		var dragEnds = 0;
		var gestures = new GestureDetector("gesture-smoke",
			new SizedBox("gesture-area", new Text("Drag here"), LayoutAxis.fixed(100.0),
				LayoutAxis.fixed(60.0)), [
			new TapRecognizer(function(_:GestureEvent) { taps++; }),
			new DoubleTapRecognizer(function(_:GestureEvent) { doubleTaps++; }),
			new LongPressRecognizer(function(_:GestureEvent) { longPresses++; }),
			new DragRecognizer(6.0,
				function(_:GestureEvent) { dragStarts++; },
				function(_:GestureEvent) { dragMoves++; },
				function(_:GestureEvent) { dragEnds++; })
		]);
		var gestureFrame = new LayoutFrame(256.0, 192.0);
		var gestureRoot = context.submit(gestures, gestureFrame);
		var gestureGeometry:ResolvedLayoutItem = cast gestureRoot.children[0].resolved;
		var gestureX = gestureGeometry.x + 10.0;
		var gestureY = gestureGeometry.y + 10.0;
		context.pointerDown(gestureX, gestureY, 0);
		context.pointerUp(gestureX, gestureY, 0);
		gestureFrame.deltaSeconds = 0.1;
		gestureRoot = context.submit(gestures, gestureFrame);
		gestureFrame.deltaSeconds = 0.0;
		context.pointerDown(gestureX, gestureY, 0);
		context.pointerUp(gestureX, gestureY, 0);
		if (taps != 2 || doubleTaps != 1)
			return 86;
		context.pointerDown(gestureX, gestureY, 0);
		gestureFrame.deltaSeconds = 0.6;
		gestureRoot = context.submit(gestures, gestureFrame);
		gestureFrame.deltaSeconds = 0.0;
		context.pointerUp(gestureX, gestureY, 0);
		if (longPresses != 1 || taps != 2)
			return 87;
		context.pointerDown(gestureX, gestureY, 0);
		context.pointerMove(gestureX + 20.0, gestureY + 10.0);
		context.pointerUp(gestureX + 20.0, gestureY + 10.0, 0);
		if (dragStarts != 1 || dragMoves == 0 || dragEnds != 1 || taps != 2)
			return 88;

		var animationUpdates = 0;
		var animationCompletions = 0;
		var animation = new AnimationController(context.animations,
			function(_) { animationUpdates++; }, function() { animationCompletions++; });
		animation.play(0.0, 100.0, 1.0, Easing.EaseInOut);
		var animationFrame = new LayoutFrame(256.0, 192.0);
		animationFrame.deltaSeconds = 0.5;
		context.submit(new Text("Tween"), animationFrame);
		if (animation.value < 49.9 || animation.value > 50.1 || animationUpdates != 1)
			return 89;
		context.submit(new Text("Tween"), animationFrame);
		if (animation.value != 100.0 || animation.active || animationCompletions != 1)
			return 90;

		// Transform animation is a composite-only change: the resolved box keeps
		// its layout size while the visual transform changes between submits.
		var transformStyle = new LayoutStyle();
		transformStyle.width = LayoutAxis.fixed(120.0);
		transformStyle.height = LayoutAxis.fixed(48.0);
		var transformCanvas = CanvasView.simple("transform-animation", function(_) {},
			transformStyle);
		var transformFrame = new LayoutFrame(256.0, 192.0);
		transformFrame.deltaSeconds = 0.0;
		var transformRoot = context.submit(transformCanvas, transformFrame);
		var initialTransformGeometry:ResolvedLayoutItem = cast transformRoot.resolved;
		var transformWidth = initialTransformGeometry.width;
		var transformHeight = initialTransformGeometry.height;
		var initialContentRevision = transformRoot.contentRevision;
		var initialGeometryRevision = transformRoot.geometryRevision;
		var initialCompositeRevision = transformRoot.compositeRevision;
		var transformAnimation = new AnimationController(context.animations, function(value) {
			transformCanvas.style.transform = Transform2D.translation(value, 0.0);
		});
		transformAnimation.play(0.0, 48.0, 1.0, Easing.EaseInOut);
		transformFrame.deltaSeconds = 0.5;
		transformRoot = context.submit(transformCanvas, transformFrame);
		var transformGeometry:ResolvedLayoutItem = cast transformRoot.resolved;
		var transformMetrics:Null<UiFrameMetrics> = context.frameMetrics;
		if (transformMetrics == null || transformMetrics.layoutInvalidatedNodes != 0 ||
			!transformMetrics.nativeLayoutSubmitted || transformMetrics.nativeLayoutReused ||
			transformMetrics.compositeInvalidatedNodes <= 0 ||
			transformMetrics.hitGeometryInvalidatedNodes <= 0 ||
			transformGeometry.width != transformWidth ||
			transformGeometry.height != transformHeight ||
			transformGeometry.transform.tx == 0.0 ||
			transformRoot.contentRevision != initialContentRevision ||
			transformRoot.geometryRevision <= initialGeometryRevision ||
			transformRoot.compositeRevision <= initialCompositeRevision)
			return 241;
		var opacitySheet = new StyleSheet("RevisionOpacity");
		opacitySheet.rule(StyleSelector.widget("canvas"), [StyleValue.opacity(0.5)]);
		context.setStyleSheet(opacitySheet);
		transformFrame.deltaSeconds = 0.0;
		var opacityRoot = context.submit(transformCanvas, transformFrame);
		if (opacityRoot.geometryRevision != transformRoot.geometryRevision ||
			opacityRoot.contentRevision != transformRoot.contentRevision ||
			opacityRoot.compositeRevision <= transformRoot.compositeRevision ||
			!UiDirtyFlag.contains(opacityRoot.invalidationFlags, UiDirtyFlag.NeedsComposite) ||
			UiDirtyFlag.contains(opacityRoot.invalidationFlags, UiDirtyFlag.NeedsHitGeometry)) {
				Sys.println('revision opacity check failed content=${opacityRoot.contentRevision}/${transformRoot.contentRevision} geometry=${opacityRoot.geometryRevision}/${transformRoot.geometryRevision} composite=${opacityRoot.compositeRevision}/${transformRoot.compositeRevision} flags=${opacityRoot.invalidationFlags}');
				return 242;
			}
		var opacityMetrics:Null<UiFrameMetrics> = context.frameMetrics;
		if (opacityMetrics == null || opacityMetrics.nativeLayoutSubmitted ||
			!opacityMetrics.nativeLayoutReused || opacityMetrics.resolvedGeometryChangedNodes != 0 ||
			opacityMetrics.resolvedGeometryReusedNodes != 1)
			return 243;
		context.setStyleSheet(new StyleSheet("Application"));
		var spring = new SpringController(0.0, 180.0, 24.0, 1.0, 0.001,
			context.animations);
		spring.setTarget(1.0);
		animationFrame.deltaSeconds = 1.0 / 60.0;
		for (_ in 0...120)
			context.submit(new Text("Spring"), animationFrame);
		if (spring.value < 0.99 || spring.active || context.animations.activeCount != 0)
			return 91;
		var restart:AnimationController = null;
		var restartCompletions = 0;
		restart = new AnimationController(context.animations, null, function() {
			restartCompletions++;
			if (restartCompletions == 1)
				restart.play(0.0, 1.0, 0.1);
		});
		restart.play(0.0, 1.0, 0.1);
		animationFrame.deltaSeconds = 0.1;
		context.submit(new Text("Restart"), animationFrame);
		if (restartCompletions != 1 || !restart.active || context.animations.activeCount != 1)
			return 119;
		context.submit(new Text("Restart"), animationFrame);
		if (restartCompletions != 2 || restart.active || context.animations.activeCount != 0)
			return 121;
		var loop = new LoopAnimation();
		var firstHandle = context.animations.track(loop);
		var secondHandle = context.animations.track(loop);
		if (firstHandle != secondHandle || context.animations.activeCount != 1)
			return 117;
		firstHandle.cancel();
		if (firstHandle.active || context.animations.activeCount != 0)
			return 118;

		var spinner = new Spinner("spinner-smoke", "Loading", null, SpinnerKind.Dots,
			Color.rgba(0.3, 0.7, 1.0, 1.0), 1.5);
		var spinnerFrame = new LayoutFrame(256.0, 192.0);
		var animationRequests = 0;
		context.onAnimationFrameRequested = function() { animationRequests++; };
		var spinnerRoot = context.submit(spinner, spinnerFrame);
		var spinnerSemantics:Semantics = cast spinnerRoot.semantics;
		if (spinnerRoot.resolved == null || spinnerRoot.resolved.width != 24.0 ||
			spinnerRoot.resolved.height != 24.0 || spinnerSemantics == null ||
			spinnerSemantics.role != AccessibilityRole.ProgressBar ||
			spinnerSemantics.label != "Loading" ||
			(spinnerSemantics.states & AccessibilityState.Busy) == 0 ||
			context.animations.activeCount != 1 || animationRequests == 0 ||
			!context.needsAnimationFrame || !context.isDirty())
			return 109;
		spinnerFrame.deltaSeconds = 0.25;
		var requestsBeforeFrame = animationRequests;
		context.submit(spinner, spinnerFrame);
		if (context.animations.activeCount != 1 || animationRequests <= requestsBeforeFrame)
			return 110;
		spinner.running = false;
		spinnerFrame.deltaSeconds = 0.0;
		spinnerRoot = context.submit(spinner, spinnerFrame);
		spinnerSemantics = cast spinnerRoot.semantics;
		if (context.animations.activeCount != 0 ||
			(spinnerSemantics.states & AccessibilityState.Busy) != 0 ||
			spinnerSemantics.value != "Paused" || context.needsAnimationFrame || context.isDirty())
			return 111;
		spinner.running = true;
		spinnerRoot = context.submit(spinner, spinnerFrame);
		if (context.animations.activeCount != 1)
			return 112;
		var spinnerId = spinnerRoot.id;
		context.onAnimationFrameRequested = null;
		context.submit(new Text("Unmount"), spinnerFrame);
		if (context.stateStore.contains(spinnerId) || context.animations.activeCount != 0)
			return 112;

		var spinnerGeometry = new ResolvedLayoutItem(1, 1, 0.0, 0.0, 24.0, 24.0,
			new Rect(0.0, 0.0, 24.0, 24.0), new Rect(0.0, 0.0, 24.0, 24.0),
			Transform2D.identity(), 0.0);
		var spinnerPainter = new SpinnerPainter(context.animations,
			Color.rgba(0.3, 0.7, 1.0, 1.0), 1.0);
		var spinnerCanvas = new Canvas();
		var spinnerList = DisplayList.create();
		spinnerPainter.paintFrame(spinnerCanvas, spinnerGeometry);
		spinnerCanvas.update(spinnerList);
		if (spinnerList.info().commandCount <= 0)
			return 113;
		spinnerList.clear();
		spinnerCanvas.reset();
		spinnerPainter.configure(SpinnerKind.Dots, Color.rgba(0.3, 0.7, 1.0, 1.0), 1.0);
		spinnerPainter.paintFrame(spinnerCanvas, spinnerGeometry);
		spinnerCanvas.update(spinnerList);
		if (spinnerList.info().commandCount <= 0)
			return 114;
		spinnerList.clear();
		spinnerCanvas.reset();
		spinnerPainter.configure(SpinnerKind.Bars, Color.rgba(0.3, 0.7, 1.0, 1.0), 1.0);
		spinnerPainter.paintFrame(spinnerCanvas, spinnerGeometry);
		spinnerCanvas.update(spinnerList);
		if (spinnerList.info().commandCount <= 0)
			return 115;
		spinnerList.clear();
		spinnerCanvas.reset();
		spinnerPainter.configure(SpinnerKind.Pulse, Color.rgba(0.3, 0.7, 1.0, 1.0), 1.0);
		spinnerPainter.paintFrame(spinnerCanvas, spinnerGeometry);
		spinnerCanvas.update(spinnerList);
		if (spinnerList.info().commandCount <= 0)
			return 116;
		spinnerList.clear();
		spinnerCanvas.reset();
		spinnerList.dispose();
		spinnerPainter.dispose();
		var accessibilityResult = AccessibilityContract.run(fonts);
		if (accessibilityResult != 0)
			return 120 + accessibilityResult;

		var degenerateCanvas = new Canvas();
		var degenerateList = DisplayList.create();
		if (degenerateCanvas.fillRectIfPositive(new Rect(0.0, 0.0, 0.0, 4.0),
			Color.rgba(0.2, 0.4, 0.8, 0.5)) ||
			degenerateCanvas.fillRectIfPositive(new Rect(0.0, 0.0, 4.0, -1.0),
			Color.rgba(0.2, 0.4, 0.8, 0.5)))
			return 107;
		degenerateCanvas.update(degenerateList);
		if (degenerateList.info().commandCount != 0)
			return 108;
		degenerateList.dispose();

		var overlayCanvas = new Canvas();
		var overlayList = DisplayList.create();
		overlayCanvas.fillRect(new Rect(2.0, 3.0, 12.0, 8.0), Color.rgba(0.2, 0.4, 0.8, 0.5));
		overlayCanvas.update(overlayList);
		if (overlayList.info().commandCount != 2)
			return 29;
		overlayList.clear();
		overlayList.dispose();

		var gradientCanvas = new Canvas();
		var gradientList = DisplayList.create();
		gradientCanvas.fillLinearGradientRect(new Rect(0.0, 0.0, 32.0, 16.0),
			0.0, 0.0, 32.0, 0.0, [
				new GradientStop(0.0, Color.rgba(0.2, 0.4, 0.8, 1.0)),
				new GradientStop(1.0, Color.rgba(0.2, 0.8, 0.4, 1.0))
			]);
		gradientCanvas.update(gradientList);
		if (gradientList.info().commandCount != 2)
			return 235;
		gradientCanvas.reset();
		gradientList.dispose();
		var gradientDecorationCanvas = new Canvas();
		var gradientDecorationList = DisplayList.create();
		new GradientDecoration(Color.rgba(0.2, 0.4, 0.8, 1.0),
			Color.rgba(0.2, 0.8, 0.4, 1.0)).paint(gradientDecorationCanvas,
			new ResolvedLayoutItem(602, 1, 0.0, 0.0, 32.0, 16.0,
				new Rect(0.0, 0.0, 32.0, 16.0), new Rect(0.0, 0.0, 32.0, 16.0),
				Transform2D.identity(), 0.0), new ComputedStyle());
		gradientDecorationCanvas.update(gradientDecorationList);
		if (gradientDecorationList.info().commandCount != 2)
			return 264;
		gradientDecorationList.dispose();

		var cachedBuilds = 0;
		var cachedFrame = new LayoutFrame(256.0, 192.0);
		var cachedRoot = context.submitCached(function() {
			cachedBuilds++;
			return new Text("Cached");
		}, cachedFrame, "framework-cache");
		var reusedRoot = context.submitCached(function() {
			cachedBuilds++;
			return new Text("Should not build");
		}, cachedFrame, "framework-cache");
		var cachedMetrics:Null<UiFrameMetrics> = context.frameMetrics;
		if (cachedBuilds != 1 || reusedRoot != cachedRoot || cachedMetrics == null ||
			!cachedMetrics.reusedSubmission || cachedMetrics.styleResolutions != 0)
			return 109;
		cachedFrame.deltaSeconds = 0.1;
		var jitteredRoot = context.submitCached(function() {
			cachedBuilds++;
			return new Text("Should still reuse on timing jitter");
		}, cachedFrame, "framework-cache");
		cachedMetrics = context.frameMetrics;
		if (cachedBuilds != 1 || jitteredRoot != cachedRoot || cachedMetrics == null ||
			!cachedMetrics.reusedSubmission)
			return 110;
		if (!checkWindowChrome(context))
			return 231;

		var cleaned = 0;
		context.stateStore.onDispose(initialId, function() {
			cleaned++;
		});
		context.dispose();
		if (cleaned != 1)
			return 31;
		fonts.dispose();
		Sys.println("PASS: Haxe framework, 4,000-node layout pressure, and NativeKit input routing");
		return 0;
	}

	static function propertyInputContrastValid(fonts:FontCollection):Bool {
		var theme = haxeon.ui.theme.Theme.light();
		var context = new UiContext(null, fonts, theme);
		var values = ["1.5", "0.1", "Blue box", "#458AFF"];
		for (index in 0...values.length) {
			var fieldStyle = new LayoutStyle();
			fieldStyle.width = LayoutAxis.fixed(220.0);
			var field = new TextField("contrast-" + index, values[index], null, fieldStyle);
			field.classes = ["property-input"];
			field.enabled = index != 1;
			var root = context.submit(field, new LayoutFrame(240.0, 40.0));
			var expected = field.enabled ? theme.tokens.textPrimary : theme.tokens.textDisabled;
			var foreground:Color = root.computedStyle.get(haxeon.ui.style.StyleProperty.TextColor);
			var background:Color = root.computedStyle.get(haxeon.ui.style.StyleProperty.Background);
			var rendered:Color = root.children[0].children[0].layout.textColor;
			if (foreground == null || background == null || rendered == null ||
				root.children[0].children[0].layout.visualKind != LayoutVisualKind.Text ||
				foreground.red != expected.red || foreground.green != expected.green ||
				foreground.blue != expected.blue || rendered.red != expected.red ||
				rendered.green != expected.green || rendered.blue != expected.blue ||
				background.red != theme.tokens.surfaceSunken.red ||
				background.green != theme.tokens.surfaceSunken.green ||
				background.blue != theme.tokens.surfaceSunken.blue ||
				contrastRatio(foreground, background) < 4.5) {
				context.dispose();
				return false;
			}
		}
		context.dispose();
		return true;
	}

	static function defaultTextFieldContrastValid(fonts:FontCollection):Bool {
		for (theme in [haxeon.ui.theme.Theme.light(), haxeon.ui.theme.Theme.dark()]) {
			var context = new UiContext(null, fonts, theme);
			var root = context.submit(new TextField("default-field", "Rename me"),
				new LayoutFrame(280.0, 48.0));
			var background:Color = root.computedStyle.get(haxeon.ui.style.StyleProperty.Background);
			var foreground:Color = root.children[0].children[0].layout.textColor;
			var valid = background != null && foreground != null &&
				background.red == theme.tokens.surfaceSunken.red &&
				background.green == theme.tokens.surfaceSunken.green &&
				background.blue == theme.tokens.surfaceSunken.blue &&
				contrastRatio(foreground, background) >= 4.5;
			context.dispose();
			if (!valid) return false;
		}
		return true;
	}

	/** A retained panel must be able to tell which of its own widget states changed (a select opening). */
	static function stateRevisionsTrackOwnUpdates():Bool {
		var store = new StateStore();
		var context = new BuildContext(store, null, null, null, Theme.light());
		store.beginFrame();
		var open:State<Bool> = context.state(context.id("open"), false);
		var other:State<Int> = context.state(context.id("other"), 0);
		var ids = [open.id.value, other.id.value];
		var before = context.stateRevisions(ids);
		if (context.stateRevisions(ids)[0] != before[0])
			return false;
		open.update(true);
		var after = context.stateRevisions(ids);
		var ok = after[0] != before[0] && after[1] == before[1];
		other.update(3);
		var last = context.stateRevisions(ids);
		store.endFrame();
		return ok && last[1] != after[1] && last[0] == after[0];
	}

	/** Retained views compare this fingerprint, so a light-to-dark swap must never reuse one. */
	static function themeSwapChangesStyleRevision():Bool {
		var context = new BuildContext(new StateStore(), null, null, null, Theme.light());
		var light = context.styleRevision;
		if (context.styleRevision != light)
			return false;
		context.setTheme(Theme.dark());
		var dark = context.styleRevision;
		context.setTheme(Theme.light());
		var lightAgain = context.styleRevision;
		context.setStyleSheet(new StyleSheet("Replacement"));
		return light != dark && dark != lightAgain && light != lightAgain &&
			context.styleRevision != lightAgain;
	}

	static function retainedStateUsageValid():Bool {
		var store = new StateStore();
		var id = new WidgetId(90501);
		var disposals = 0;
		store.beginFrame();
		store.initialize(id, "editor");
		store.onUnmount(id, function() disposals++);
		store.endFrame();
		store.beginFrame();
		var parentMarker = store.usageMarker();
		store.retain([id.value]);
		var parentIds = store.usedIdsSince(parentMarker);
		store.endFrame();
		store.beginFrame();
		store.retain(parentIds);
		store.endFrame();
		var retained = parentIds.length == 1 && parentIds[0] == id.value &&
			store.contains(id) && disposals == 0;
		store.beginFrame();
		store.endFrame();
		return retained && !store.contains(id) && disposals == 1;
	}

	static function tabStrip(root:RenderNode):RenderNode {
		var found:RenderNode = null;
		root.walk(function(node) {
			if (node.children.length == 0 || node.children[0].children.length == 0) return;
			var semantics = node.children[0].children[0].semantics;
			if (found == null && semantics != null && semantics.role == AccessibilityRole.Tab) found = node;
		});
		if (found == null) throw "Missing tab strip";
		return found;
	}

	static function tabHierarchyValid(fonts:FontCollection):Bool {
		var theme = haxeon.ui.theme.Theme.light();
		var context = new UiContext(null, fonts, theme);
		var tabs = new Tabs("hierarchy-test", [
			new TabItem("one", "One", new Text("First")),
			new TabItem("two", "Two", new Text("Second"))
		], "one");
		var root = context.submit(tabs, new LayoutFrame(300.0, 120.0));
		var first = tabStrip(root).children[0];
		var second = tabStrip(root).children[1];
		var active = first.children[0].layout.style.background;
		var inactive = second.children[0].layout.style.background;
		var indicator = first.children[1].layout.style.background;
		var result = active.red == theme.tokens.surfaceRaised.red &&
			active.green == theme.tokens.surfaceRaised.green &&
			inactive.alpha == 0.0 &&
			indicator.red == theme.tokens.accent.red &&
			indicator.green == theme.tokens.accent.green &&
			second.children[1].layout.style.background.alpha == 0.0;
		context.dispose();
		return result;
	}

	static function contrastRatio(a:Color, b:Color):Float {
		var aLuminance = colorLuminance(a);
		var bLuminance = colorLuminance(b);
		return (Math.max(aLuminance, bLuminance) + 0.05) /
			(Math.min(aLuminance, bLuminance) + 0.05);
	}

	static function colorLuminance(color:Color):Float {
		return 0.2126 * linearChannel(color.red) +
			0.7152 * linearChannel(color.green) +
			0.0722 * linearChannel(color.blue);
	}

	static function linearChannel(channel:Float):Float
		return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);

	static function hostFrameLifecycleValid():Bool {
		var state = new UiHostFrameState(800, 600);
		if (state.canRender()) return false;
		state.setSurfaceAvailable(true);
		state.setScale(2); state.setZoom(1.25);
		if (state.layoutWidth != 640 || state.layoutHeight != 480 || state.renderScale != 2.5 || state.scale != 2) return false;
		state.setZoom(1);
		if (!state.canRender() || state.nextDelta(10.0) != 0.0) return false;
		if (state.nextDelta(10.25) != 0.1) return false;
		state.setSurfaceAvailable(false);
		state.resize(1024, 768, 2048, 1536);
		if (state.canRender()) return false;
		state.setSurfaceAvailable(true);
		if (!state.canRender() || state.nextDelta(30.0) != 0.0) return false;
		state.resize(1024, 768, 0, 0);
		return !state.canRender();
	}

	static function hostSessionLifecycleValid():Bool {
		var stops = 0;
		var session = new UiHostSession(function() stops++);
		if (!session.isActive() || session.state != UiHostLifecycle.Starting) return false;
		session.stop();
		session.stop();
		session.dispose();
		return stops == 1 && !session.isActive() &&
			session.state == UiHostLifecycle.Stopping;
	}

	static function hostPendingResourcesValid():Bool {
		var pending = new UiHostPendingResources<String>();
		pending.add("first", "font-a");
		pending.add("second", "font-b");
		if (pending.remaining != 2 || pending.resolve("first") != "font-a" ||
			pending.remaining != 1) return false;
		pending.cancel();
		return pending.remaining == 0 && pending.resolve("second") == null;
	}

	static function hostRuntimeLifecycleValid(fonts:FontCollection):Bool {
		var failedSession = new UiHostSession(function() {});
		var failedRuntime = testHostRuntime(failedSession, fonts);
		var factoryCalls = 0;
		failedRuntime.start(function(_) {
			factoryCalls++;
			throw "factory failure";
		});
		if (failedSession.state != UiHostLifecycle.Failed || failedSession.error == null ||
			factoryCalls != 1) return false;
		var originalError:haxeon.ui.host.UiHostSession.UiHostError = cast failedSession.error;
		var originalFailure = originalError.message;
		failedRuntime.start(function(_) {
			factoryCalls++;
			return new SmokeHostApplication(false);
		});
		var retainedError:haxeon.ui.host.UiHostSession.UiHostError = cast failedSession.error;
		if (factoryCalls != 1 || retainedError.message != originalFailure ||
			originalError.stack.length == 0) return false;

		var stoppedRuntime:Null<UiHostRuntime> = null;
		var stoppedSession = new UiHostSession(function() {
			if (stoppedRuntime != null) stoppedRuntime.dispose();
		});
		stoppedRuntime = testHostRuntime(stoppedSession, fonts);
		var stoppedApp = new SmokeHostApplication(true);
		stoppedRuntime.start(function(_) {
			stoppedSession.stop();
			return stoppedApp;
		});
		return stoppedSession.state == UiHostLifecycle.Stopping &&
			stoppedApp.disposeCalls == 1 && stoppedSession.cleanupErrors.length == 1 &&
			!stoppedRuntime.isCallbackActive();
	}

	static function testHostRuntime(session:UiHostSession, fonts:FontCollection):UiHostRuntime {
		var context = new UiHostContext(fonts, new NativeKitEvents(),
			function() session.stop(), function() {});
		return new UiHostRuntime(session, context, WindowHandle.invalid(), SurfaceHandle.invalid(),
			800, 600);
	}

	static function decorationStyleContract():Int {
		var decorationsA = DecorationChain.of([
			new BackgroundDecoration(Color.rgba(0.1, 0.2, 0.3, 1.0)),
			new GradientDecoration(Color.rgba(0.0, 0.2, 0.8, 1.0),
				Color.rgba(0.2, 0.8, 0.4, 1.0)),
			new BorderDecoration(Color.rgba(0.8, 0.9, 1.0, 1.0), 2.0)
		]);
		var decorationsB = DecorationChain.of([
			new BackgroundDecoration(Color.rgba(0.8, 0.2, 0.1, 1.0)),
			new GradientDecoration(Color.rgba(1.0, 0.2, 0.0, 1.0),
				Color.rgba(0.8, 0.1, 0.5, 1.0)),
			new BorderDecoration(Color.rgba(1.0, 0.8, 0.2, 1.0), 4.0)
		]);
		if (decorationsA.decorations.length != 3 || !decorationsA.isEqual(decorationsA.copy()) ||
			decorationsA.isEqual(decorationsB))
			return 260;
		var directMid:GradientDecoration = cast DecorationChain.interpolate(decorationsA, decorationsB,
			0.5).decorations[1];
		if (directMid == null || Math.abs(directMid.start.red - 0.5) > 0.00001 ||
			Math.abs(directMid.end.green - 0.45) > 0.00001)
			return 264;
		var customDecorationA = new Decoration();
		var customDecorationB = new Decoration();
		var customChainA = DecorationChain.of([customDecorationA]);
		var customChainB = DecorationChain.of([customDecorationB]);
		var customEarly = DecorationChain.interpolate(customChainA, customChainB, 0.25);
		var customLate = DecorationChain.interpolate(customChainA, customChainB, 0.75);
		if (!customChainA.isEqual(customChainA.copy()) || customChainA.isEqual(customChainB) ||
			customEarly.decorations[0] != customDecorationA ||
			customLate.decorations[0] != customDecorationB)
			return 265;
		var decorationSheet = new StyleSheet("DecorationSheet");
		decorationSheet.rule(StyleSelector.widget("panel"),
			[StyleValue.decorations(decorationsA)]);
		decorationSheet.rule(StyleSelector.widget("panel").state(StyleState.Hovered),
			[StyleValue.decorations(decorationsB)]);
		var decorationResolver = new StyleResolver();
		var decorationTarget = new StyleTarget("panel", "decoration-key", "decoration-id",
			null, null, 0);
		var normalDecorated = decorationResolver.resolve(decorationTarget, null, null,
			decorationSheet);
		decorationTarget = new StyleTarget("panel", "decoration-key", "decoration-id",
			null, null, StyleState.Hovered);
		var hoveredDecorated = decorationResolver.resolve(decorationTarget, null, null,
			decorationSheet);
		var decorationSource = hoveredDecorated.source(StyleProperty.Decorations);
		if (!normalDecorated.get(StyleProperty.Decorations).isEqual(decorationsA) ||
			!hoveredDecorated.get(StyleProperty.Decorations).isEqual(decorationsB) ||
			decorationSource == null || decorationSource.selector != "panel:hovered" ||
			StyleDiff.compare(normalDecorated, hoveredDecorated).impact != StyleImpact.Paint)
			return 261;
		var decorationTransitionSheet = new StyleSheet("DecorationTransitionSheet");
		decorationTransitionSheet.rule(StyleSelector.widget("panel"),
			[StyleValue.decorations(decorationsA)]);
		decorationTransitionSheet.rule(StyleSelector.widget("panel").state(StyleState.Hovered),
			[StyleValue.decorations(decorationsB)]);
		decorationTransitionSheet.transition(StyleProperty.Decorations, 0.1, Easing.Linear);
		var decorationScheduler = new AnimationScheduler();
		var decorationTransitionResolver = new StyleResolver(decorationScheduler);
		var decorationTransitionTarget = new StyleTarget("panel", "decoration-transition-key",
			"decoration-transition-id", null, null, 0);
		decorationTransitionResolver.resolve(decorationTransitionTarget, null, null,
			decorationTransitionSheet);
		decorationTransitionTarget = new StyleTarget("panel", "decoration-transition-key",
			"decoration-transition-id", null, null, StyleState.Hovered);
		decorationTransitionResolver.resolve(decorationTransitionTarget, null, null,
			decorationTransitionSheet);
		if (decorationScheduler.activeCount != 1)
			return 262;
		decorationScheduler.advance(0.05);
		var midDecorated = decorationTransitionResolver.resolve(decorationTransitionTarget, null, null,
			decorationTransitionSheet);
		var midChain:DecorationChain = midDecorated.get(StyleProperty.Decorations);
		var midGradient:GradientDecoration = cast midChain.decorations[1];
		if (midGradient == null || Math.abs(midGradient.start.red - 0.5) > 0.00001 ||
			Math.abs(midGradient.end.green - 0.45) > 0.00001)
			return 263;
		return 0;
	}

	static function checkWindowChrome(context:UiContext):Bool {
		var runtime:Null<NativeKitRuntime> = null;
		var attached = false;
		var result = false;
		try {
			var initOptions = new InitOptions();
			initOptions.set_api_version(NativeKit.nk_api_version());
			runtime = NativeKitRuntime.start(initOptions);
			var windowOptions = new WindowOptions();
			windowOptions.set_width(320);
			windowOptions.set_height(192);
			windowOptions.set_title("NativeKit UI chrome smoke");
			windowOptions.set_flags(WindowFlags.Hidden | WindowFlags.Borderless);
			windowOptions.set_owner(WindowHandle.invalid());
			windowOptions.set_kind(WindowKind.Normal);
			var window = runtime.createWindow(windowOptions);
			context.attachPlatformWindow(window.nativeHandle());
			attached = true;
			var root = context.submit(new WindowChrome("chrome", WindowDecorationRegionKind.Drag,
				new Row("chrome-row", [new KeyedView("client", new WindowChrome(
					"client", WindowDecorationRegionKind.Client, new Text("Client")))])),
				new LayoutFrame(320.0, 192.0));
			result = root.windowDecoration == WindowDecorationRegionKind.Drag &&
				root.children.length == 1 &&
				root.children[0].windowDecoration == WindowDecorationRegionKind.Client &&
				root.cursor == UiCursorShape.Arrow &&
				root.children[0].cursor == UiCursorShape.Arrow &&
				root.resolved != null && root.resolved.width > 0.0 && root.resolved.height > 0.0;
			var diagonal = context.submit(new WindowChrome("chrome-diagonal",
				WindowDecorationRegionKind.ResizeNortheast, new Text("Resize")),
				new LayoutFrame(320.0, 192.0));
			result = result && diagonal.cursor == UiCursorShape.DiagonalResizeNesw &&
				diagonal.windowDecorationCursor == null;
			var custom = context.submit(new WindowChrome("chrome-custom",
				WindowDecorationRegionKind.Client, new Text("Custom"), UiCursorShape.Hand),
				new LayoutFrame(320.0, 192.0));
			result = result && custom.cursor == UiCursorShape.Hand &&
				custom.windowDecorationCursor == UiCursorShape.Hand;
		} catch (_:Dynamic) {
		}
		if (attached) {
			try {
				context.detachPlatformWindow();
			} catch (_:Dynamic) {}
		}
		if (runtime != null) {
			try {
				runtime.dispose();
			} catch (_:Dynamic) {}
		}
		return result;
	}

	static function checkSplitKeyboard(context:UiContext):Bool {
		var frame = new LayoutFrame(320.0, 192.0);
		var trailingOptions = new SplitViewOptions();
		trailingOptions.resizableSide = SplitSide.Trailing;
		trailingOptions.extent = 96.0;
		trailingOptions.minimumExtent = 64.0;
		trailingOptions.maximumExtent = 144.0;
		var trailingSplit = new SplitView("keyboard-trailing-split", new Text("Leading"),
			new Text("Trailing"), trailingOptions);
		var trailingRoot = context.submit(trailingSplit, frame);
		var trailingDivider = trailingRoot.children[1];
		var trailingSemantics:Semantics = cast trailingDivider.semantics;
		if (trailingSemantics == null || !trailingDivider.focusable ||
			(trailingSemantics.actions & AccessibilityAction.Increment) == 0 ||
			(trailingSemantics.actions & AccessibilityAction.Decrement) == 0 ||
			trailingSemantics.numericValue != 96.0)
			return false;
		if (!context.focusWidget(trailingDivider.id))
			return false;
		context.key(UiEventKind.KeyDown, UiKey.Right);
		if (trailingSplit.extent != 88.0)
			return false;
		context.key(UiEventKind.KeyDown, UiKey.Home);
		if (trailingSplit.extent != 64.0)
			return false;
		context.key(UiEventKind.KeyDown, UiKey.End);
		if (trailingSplit.extent != 144.0)
			return false;
		trailingRoot = context.submit(trailingSplit, frame);
		if (!context.accessibilityAction(trailingRoot.children[1].id.value,
			AccessibilityRequest.Decrement, null, -1, -1, 2) || trailingSplit.extent != 128.0)
			return false;

		var leadingResizes = 0;
		var leadingExpansions = 0;
		var leadingOptions = new SplitViewOptions();
		leadingOptions.resizableSide = SplitSide.Leading;
		leadingOptions.extent = 96.0;
		leadingOptions.minimumExtent = 64.0;
		leadingOptions.maximumExtent = 144.0;
		leadingOptions.onResize = function(value) { leadingResizes = Std.int(value); };
		leadingOptions.onCollapsedChanged = function(collapsed) {
			if (!collapsed)
				leadingExpansions++;
		};
		var leadingSplit = new SplitView("keyboard-leading-split", new Text("Leading"),
			new Text("Trailing"), leadingOptions);
		var leadingRoot = context.submit(leadingSplit, frame);
		if (leadingRoot.children.length != 3 ||
			leadingRoot.children[0].layout.style.width.sizing != LayoutSizing.Fixed ||
			leadingRoot.children[2].layout.style.width.sizing != LayoutSizing.Grow)
			return false;
		var leadingDivider = leadingRoot.children[1];
		var leadingSemantics:Semantics = cast leadingDivider.semantics;
		if (leadingSemantics == null || leadingSemantics.label != "Leading pane divider" ||
			leadingSemantics.numericValue != 96.0)
			return false;
		var leadingGeometry:ResolvedLayoutItem = cast leadingDivider.resolved;
		var leadingX = leadingGeometry.x + leadingGeometry.width * 0.5;
		var leadingY = leadingGeometry.y + leadingGeometry.height * 0.5;
		context.pointerDown(leadingX, leadingY, 0);
		context.pointerMove(leadingX + 20.0, leadingY);
		context.pointerUp(leadingX + 20.0, leadingY, 0);
		if (leadingResizes != 116 || leadingSplit.extent != 116.0)
			return false;
		leadingSplit.collapsed = true;
		leadingRoot = context.submit(leadingSplit, frame);
		var collapsedLeadingGeometry:ResolvedLayoutItem = cast leadingRoot.children[0].resolved;
		if (leadingRoot.children[0].layout.style.visible ||
			collapsedLeadingGeometry.width != 0.0)
			return false;
		var collapsedDividerGeometry:ResolvedLayoutItem = cast leadingRoot.children[1].resolved;
		var collapsedX = collapsedDividerGeometry.x + collapsedDividerGeometry.width * 0.5;
		var collapsedY = collapsedDividerGeometry.y + collapsedDividerGeometry.height * 0.5;
		context.pointerDown(collapsedX, collapsedY, 0);
		context.pointerMove(collapsedX + 20.0, collapsedY);
		context.pointerUp(collapsedX + 20.0, collapsedY, 0);
		if (leadingExpansions != 1 || leadingSplit.collapsed || leadingSplit.extent != 84.0)
			return false;
		leadingRoot = context.submit(leadingSplit, frame);
		if (!context.focusWidget(leadingRoot.children[1].id))
			return false;
		context.key(UiEventKind.KeyDown, UiKey.Right);
		if (leadingSplit.extent != 92.0)
			return false;
		leadingRoot = context.submit(leadingSplit, frame);
		if (!context.accessibilityAction(leadingRoot.children[1].id.value,
			AccessibilityRequest.Decrement, null, -1, -1, 2) || leadingSplit.extent != 76.0)
			return false;
		return true;
	}

	static function frameMetricsValid(context:UiContext, requireCacheHit:Bool):Bool {
		var metrics:Null<UiFrameMetrics> = context.frameMetrics;
		if (metrics == null || metrics.frameNumber <= 0 || metrics.nodeCount != 2 ||
			metrics.styleResolutions <= 0 || metrics.submitSeconds < 0.0 || metrics.totalSeconds < 0.0)
			return false;
		return !requireCacheHit || (metrics.styleCacheHits > 0 && metrics.styleCacheMisses == 0);
	}

	static function frameInvalidationValid(context:UiContext, requireChanged:Bool,
			requirePaint:Bool):Bool {
		var metrics:Null<UiFrameMetrics> = context.frameMetrics;
		if (metrics == null || metrics.styleChangedNodes < 0 || metrics.styleUnchangedNodes < 0 ||
			metrics.layoutInvalidatedNodes < 0 || metrics.textLayoutInvalidatedNodes < 0 ||
			metrics.paintInvalidatedNodes < 0 || metrics.compositeInvalidatedNodes < 0 ||
			metrics.semanticsInvalidatedNodes < 0)
			return false;
		if (!requireChanged && metrics.styleChangedNodes != 0)
			return false;
		if (!requireChanged && metrics.styleInvalidationFlags != UiDirtyFlag.None)
			return false;
		if (requireChanged && metrics.styleChangedNodes <= 0)
			return false;
		if (requireChanged && !UiDirtyFlag.contains(metrics.styleInvalidationFlags, UiDirtyFlag.NeedsStyle))
			return false;
		if (requirePaint && !UiDirtyFlag.contains(metrics.styleInvalidationFlags, UiDirtyFlag.NeedsPaint))
			return false;
		return !requirePaint || metrics.paintInvalidatedNodes > 0;
	}

	static function coordinateMathValid():Bool {
		var local = new Point(23.0, 11.0);
		var transforms:Array<Transform2D> = [
			Transform2D.translation(40.0, 25.0),
			Transform2D.identity().scaled(1.5, 0.75).translated(12.0, -8.0),
			Transform2D.identity().rotated(0.37).translated(18.0, 9.0),
			Transform2D.identity().skewed(0.17, -0.11).translated(-6.0, 14.0)
		];
		for (transform in transforms) {
			var item = new ResolvedLayoutItem(900, 1, 17.0, 13.0, 120.0, 64.0,
				new Rect(-1000.0, -1000.0, 2000.0, 2000.0),
				new Rect(0.0, 0.0, 0.0, 0.0), transform, 0.0);
			var global = item.localToViewport(local);
			var roundTrip = item.viewportToLocal(global);
			if (!near(roundTrip.x, local.x) || !near(roundTrip.y, local.y) ||
				!item.hitTest(global.x, global.y))
				return false;
		}

		var parent = Transform2D.translation(100.0, 40.0).rotated(0.23).scaled(1.2, 0.8);
		var child = Transform2D.translation(12.0, 7.0).skewed(0.09, -0.04);
		var world = parent.multiply(child);
		var worldPoint = world.transformPoint(local);
		var nestedRoundTrip = world.inverse().transformPoint(worldPoint);
		if (!near(nestedRoundTrip.x, local.x) || !near(nestedRoundTrip.y, local.y))
			return false;

		var singular = Transform2D.scale(0.0, 1.0);
		if (singular.isInvertible() || singular.tryInverse() != null)
			return false;
		var singularItem = new ResolvedLayoutItem(901, 1, 0.0, 0.0, 20.0, 20.0,
				new Rect(-100.0, -100.0, 200.0, 200.0),
				new Rect(0.0, 0.0, 0.0, 0.0), singular, 0.0);
		return !singularItem.hitTest(0.0, 0.0) && nestedSceneSemanticsValid();
	}

	static function commandHistoryValid(uiContext:UiContext):Bool {
		var history = new EditHistory();
		var value = 0;
		var latest = 1;
		var first = new EditOperation("Move", function() value = latest,
			function() value = 0, "drag", function(next) {
				latest = cast next.mergeData;
				return true;
			}, 1);
		if (!history.apply(first) || value != 1 || history.undoCount != 1)
			return false;
		var second = new EditOperation("Move", function() value = 2,
			function() value = 1, "drag", null, 2);
		if (!history.apply(second) || value != 2 || history.undoCount != 1)
			return false;
		if (!history.undo() || value != 0 || history.canUndo || !history.canRedo)
			return false;
		if (!history.redo() || value != 2 || !history.canUndo || history.canRedo)
			return false;

		history.clear();
		value = 0;
		var transaction = history.begin("Transform");
		transaction.apply(new EditOperation("Translate X", function() value = 4,
			function() value = 0));
		transaction.apply(new EditOperation("Translate Y", function() value = 9,
			function() value = 4));
		if (!transaction.commit() || value != 9 || history.undoCount != 1 ||
			history.undoLabel() != "Transform")
			return false;
		if (!history.undo() || value != 0 || !history.redo() || value != 9)
			return false;
		history.clear();
		value = 0;
		var dragStart = history.begin("Drag", "drag-transaction");
		dragStart.apply(new EditOperation("Move", function() value = 4, function() value = 0));
		if (!dragStart.commit())
			return false;
		var dragEnd = history.begin("Drag", "drag-transaction");
		dragEnd.apply(new EditOperation("Move", function() value = 9, function() value = 4));
		if (!dragEnd.commit() || history.undoCount != 1 || value != 9 ||
			!history.undo() || value != 0)
			return false;

		var document = new EditorDocument("scene");
		var documentValue = 0;
		if (document.isDirty || !document.apply(new EditOperation("Set value",
			function() documentValue = 7, function() documentValue = 0)) ||
			documentValue != 7 || !document.isDirty)
			return false;
		document.markSaved();
		if (document.isDirty || !document.undo() || documentValue != 0 || !document.isDirty ||
			!document.redo() || documentValue != 7 || document.isDirty)
			return false;

		var registry = new CommandRegistry();
		var globalRuns = 0;
		var scopedRuns = 0;
		var enabled = true;
		var checked = false;
		registry.register(new Command("save", "Save", function() globalRuns++,
			new Shortcut(UiKey.S, UiModifier.Control), function() return enabled,
			function() return checked));
		if (!registry.dispatch(UiKey.S, UiModifier.Control) || globalRuns != 1 ||
			!registry.get("save").isEnabled() || registry.get("save").isChecked())
			return false;
		checked = true;
		if (!registry.get("save").isChecked())
			return false;
		registry.pushScope("viewport");
		registry.register(new Command("viewport.save", "Save viewport", function() scopedRuns++,
			new Shortcut(UiKey.S, UiModifier.Control)), "viewport");
		if (!registry.dispatch(UiKey.S, UiModifier.Control) || scopedRuns != 1 ||
			globalRuns != 1 || !registry.popScope("viewport"))
			return false;
		enabled = false;
		if (registry.dispatch(UiKey.S, UiModifier.Control))
			return false;
		var paletteRuns = 0;
		var paletteCommand = new Command("palette", "Open palette", function() paletteRuns++,
			new Shortcut(UiKey.K, UiModifier.Control));
		paletteCommand.addShortcut(new Shortcut(UiKey.P, UiModifier.Control));
		registry.register(paletteCommand);
		if (!registry.dispatch(UiKey.K, UiModifier.Control) ||
			!registry.dispatch(UiKey.P, UiModifier.Control) || paletteRuns != 2 ||
			registry.ids().length != 3)
			return false;

		var parameters = new CommandParameters();
		parameters.setString("property", "mass");
		var commandContext = new CommandContext(document, ["body-1"], "main-viewport",
			parameters, "property-editor");
		uiContext.setCommandContext(commandContext);
		if (uiContext.commandContext != commandContext ||
			uiContext.buildContext.commandContext != commandContext)
			return false;
		var mass = 2.0;
		var massSettings = new PropertyDescriptorOptions();
		massSettings.category = "Physics";
		massSettings.minimum = 0.0;
		massSettings.maximum = 100.0;
		massSettings.step = 0.1;
		massSettings.unit = "kg";
		massSettings.defaultValue = PropertyValue.Float(2.0);
		var massProperty = new PropertyDescriptor("mass", "Mass", PropertyType.Float,
			function(_) return PropertyValue.Float(mass), function(_, value) {
				switch (value) {
					case PropertyValue.Float(next): mass = next;
					case PropertyValue.Int(next): mass = next;
					default: throw "Mass requires a numeric value";
				}
			}, massSettings);
		var mode = "solid";
		var modeSettings = new PropertyDescriptorOptions();
		modeSettings.category = "Display";
		modeSettings.options = [new PropertyOption("solid", "Solid"),
			new PropertyOption("wire", "Wire")];
		var modeProperty = new PropertyDescriptor("mode", "Mode", PropertyType.Enum,
			function(_) return PropertyValue.Enum(mode), function(_, value) {
				switch (value) {
					case PropertyValue.Enum(next): mode = next;
					default: throw "Mode requires an enum value";
				}
			}, modeSettings);
		if (modeProperty.validateValue(commandContext, PropertyValue.Enum("wire")) != null ||
			modeProperty.validateValue(commandContext, PropertyValue.Enum("invalid")) == null)
			return false;
		var mixedProperty = new PropertyDescriptor("visible", "Visible", PropertyType.Bool,
			function(_) return PropertyValue.Mixed, function(_, _) {}, null);
		var inspector = new PropertyEditor("inspector", [massProperty, modeProperty, mixedProperty]);
		var inspectorRoot = uiContext.submit(inspector, new LayoutFrame(480.0, 320.0));
		if (inspectorRoot == null || inspectorRoot.children.length < 4 ||
			!PropertyValueTools.same(PropertyValue.Float(2.0), PropertyValue.Float(2.0)))
			return false;
		var sectionChanges = 0;
		var composedInspector = new PropertyInspector("composed-inspector",
			[massProperty, modeProperty, mixedProperty], null, null, [
				new PropertyInspectorSection("physics", "Physics", [massProperty]),
				new PropertyInspectorSection("display", "Display", [modeProperty, mixedProperty])
			]);
		composedInspector.onSectionExpanded = function(id, expanded) {
			if (id == "display" && !expanded)
				sectionChanges++;
		};
		var composedRoot = uiContext.submit(composedInspector, new LayoutFrame(480.0, 320.0));
		if (composedRoot == null || composedRoot.semantics == null ||
			composedRoot.semantics.label != "Inspector" ||
			!composedInspector.isSectionExpanded("display"))
			return false;
		if (!composedInspector.setSectionExpanded("display", false) || sectionChanges != 1 ||
			composedInspector.isSectionExpanded("display"))
			return false;
		composedRoot = uiContext.submit(composedInspector, new LayoutFrame(480.0, 320.0));
		if (composedRoot == null || composedRoot.children.length == 0 ||
			composedRoot.children[0].children.length == 0 ||
			composedRoot.children[0].children[0].children.length != 3)
			return false;
		composedInspector.scrollable = false;
		composedRoot = uiContext.submit(composedInspector, new LayoutFrame(480.0, 320.0));
		if (composedRoot.styleType != "column" || composedRoot.semantics == null ||
			composedRoot.semantics.role != AccessibilityRole.Group ||
			composedRoot.semantics.label != "Inspector")
			return false;
		var embeddedScrolls = 0;
		composedRoot.walk(function(node) {
			if (node.styleType == "scroll-view") embeddedScrolls++;
		});
		if (embeddedScrolls != 0)
			return false;
		var appliedMass = inspector.applyValue(uiContext.buildContext, massProperty,
			PropertyValue.Float(4.0));
		if (!appliedMass || mass != 4.0 || !document.isDirty)
			return false;
		var invalidMass = inspector.applyValue(uiContext.buildContext, massProperty,
			PropertyValue.Float(101.0));
		if (invalidMass || mass != 4.0)
			return false;
		var undoneMass = document.undo();
		var massAfterUndo = mass;
		var cleanAfterUndo = !document.isDirty;
		var redoneMass = document.redo();
		if (!undoneMass || massAfterUndo != 2.0 || !cleanAfterUndo ||
			!redoneMass || mass != 4.0 || !document.isDirty)
			return false;
		var bindingValue = 1;
		var bindingDocument = new EditorDocument("binding");
		var bindingDescriptor = new PropertyDescriptor("value", "Value", PropertyType.Int,
			function(_) return PropertyValue.Int(bindingValue), function(_, value) {
				switch (value) {
					case PropertyValue.Int(next): bindingValue = next;
					default: throw "Binding value requires an integer";
				}
			});
		var binding = new PropertyBinding(bindingDescriptor,
			new CommandContext(bindingDocument));
		if (binding.read() == null || binding.validate(PropertyValue.Int(2)) != null)
			return false;
		switch (binding.apply(PropertyValue.Int(2), "binding-drag")) {
			case PropertyEditResult.Applied:
			default: return false;
		}
		switch (binding.apply(PropertyValue.Int(3), "binding-drag")) {
			case PropertyEditResult.Applied:
			default: return false;
		}
		if (bindingValue != 3 || bindingDocument.history.undoCount != 1 ||
			!bindingDocument.undo() || bindingValue != 1 || !bindingDocument.redo() ||
			bindingValue != 3)
			return false;

		var camera = new ViewportCamera();
		var cameraAnchor = camera.viewportToWorld(40.0, 30.0);
		if (!camera.zoomAt(2.0, 40.0, 30.0) ||
			!near(camera.viewportToWorld(40.0, 30.0).x, cameraAnchor.x) ||
			!near(camera.viewportToWorld(40.0, 30.0).y, cameraAnchor.y))
			return false;
		if (!camera.panByScreen(10.0, 6.0) || camera.revision < 3)
			return false;
		var plotModel = new PlotModel();
		var plotSeries = new PlotSeries("temperature", "Temperature",
			Color.rgba(0.9, 0.35, 0.2, 1.0));
		plotSeries.setPoints([new PlotPoint(0.0, 1.0), new PlotPoint(1.0, 2.0),
			new PlotPoint(2.0, 1.5)]);
		plotModel.addSeries(plotSeries);
		var plotRange = plotModel.range();
		if (plotRange == null || plotRange.minimumX != 0.0 || plotRange.maximumX != 2.0 ||
			plotModel.revision() <= 1)
			return false;
		var plotRoot = uiContext.submit(new PlotView("telemetry-plot", plotModel),
			new LayoutFrame(320.0, 180.0));
		if (plotRoot == null || plotRoot.semantics == null ||
			plotRoot.semantics.label != "Plot")
			return false;
		var viewportContent = new SmokeViewportContent(640.0, 480.0);
		var viewportCamera = new ViewportCamera();
		var viewport = new GpuViewport("scene-viewport", viewportContent, viewportCamera);
		var viewportRoot = uiContext.submit(viewport, new LayoutFrame(320.0, 180.0));
		if (viewportRoot == null || viewportRoot.semantics == null ||
			viewportRoot.semantics.label != "GPU viewport")
			return false;
		uiContext.pointerDown(40.0, 40.0, 0, 0, 7);
		uiContext.pointerMove(55.0, 52.0, 0, 7);
		uiContext.pointerUp(55.0, 52.0, 0, 0, 7);
		if (viewportCamera.panX == 0.0 || viewportCamera.panY == 0.0)
			return false;

		var vector = new SmokeVector(1.0, 2.0, 3.0);
		var customRegistry = new PropertyEditorRegistry();
		customRegistry.register(new SmokeVectorExtension());
		var vectorProperty = new PropertyDescriptor("position", "Position",
			PropertyType.Custom("vec3"), function(_) {
				return PropertyValue.Custom("vec3", vector);
			}, function(_, value) {
				switch (value) {
					case PropertyValue.Custom("vec3", next): vector = cast next;
					default: throw "Position requires a vec3 value";
				}
			});
		var customInspector = new PropertyEditor("custom-inspector", [vectorProperty], null,
			customRegistry);
		var customRoot = uiContext.submit(customInspector, new LayoutFrame(480.0, 120.0));
		var customPresentationValid = customRoot != null &&
			customRegistry.display(PropertyValue.Custom("vec3", vector)) == "1, 2, 3" &&
			customRegistry.editableText(PropertyValue.Custom("vec3", vector)) == "1,2,3";
		if (!customPresentationValid)
			return false;
		var parsedVector = customRegistry.parse(PropertyType.Custom("vec3"), "7,8,9");
		if (parsedVector == null || !customRegistry.same(parsedVector,
			PropertyValue.Custom("vec3", new SmokeVector(7.0, 8.0, 9.0))))
			return false;
		var nextVector = new SmokeVector(4.0, 5.0, 6.0);
		var appliedVector = customInspector.applyValue(uiContext.buildContext, vectorProperty,
			PropertyValue.Custom("vec3", nextVector));
		if (!appliedVector || vector != nextVector)
			return false;
		var undoneVector = document.undo();
		var undoRestoredVector = vector.x == 1.0 && vector.y == 2.0 && vector.z == 3.0;
		var redoneVector = document.redo();
		var redoRestoredVector = vector.x == 4.0 && vector.y == 5.0 && vector.z == 6.0;
		if (!undoneVector || !undoRestoredVector || !redoneVector || !redoRestoredVector)
			return false;
		if (vectorProperty.validateValue(commandContext,
			PropertyValue.Custom("other", nextVector)) == null || vector != nextVector ||
			!document.undo() || vector.x != 1.0 ||
			vector.y != 2.0 || vector.z != 3.0)
			return false;
		var contextualRuns = 0;
		var contextualRegistry = new CommandRegistry();
		contextualRegistry.register(Command.contextual("property.reset", "Reset property",
			function(context) {
				if (context.document != document || !context.hasSelected("body-1") ||
					context.parameters.getString("property") != "mass")
					return CommandResult.rejected("Wrong command context");
				contextualRuns++;
				return CommandResult.executed();
			}, new Shortcut(UiKey.R, UiModifier.Control), function(context) {
				return context.document == document && context.hasSelection;
			}));
		var contextualResult = contextualRegistry.dispatchContext(UiKey.R, UiModifier.Control,
			commandContext);
		if (!contextualResult.succeeded || contextualRuns != 1)
			return false;
		var wrongContextResult = contextualRegistry.executeContext("property.reset",
			new CommandContext(null, ["other"], "other-viewport"));
		if (wrongContextResult.succeeded || wrongContextResult.status == null)
			return false;

		var documentHistory = new CommandRegistry();
		documentHistory.installDocumentHistoryCommands(document);
		var undoResult = documentHistory.dispatchContext(UiKey.Z, UiModifier.Control, commandContext);
		if (!undoResult.succeeded || mass != 2.0 || document.isDirty)
			return false;
		var redoResult = documentHistory.dispatchContext(UiKey.Y, UiModifier.Control, commandContext);
		if (!redoResult.succeeded || mass != 4.0 || !document.isDirty)
			return false;

		var focus = new FocusManager();
		var routingRoot = new RenderNode(new WidgetId(940));
		var routingTarget = new RenderNode(new WidgetId(941));
		var broadClip = new Rect(-100.0, -100.0, 200.0, 200.0);
		routingRoot.resolved = new ResolvedLayoutItem(940, 1, 0.0, 0.0, 100.0, 100.0,
			broadClip, new Rect(0.0, 0.0, 0.0, 0.0), Transform2D.identity(), 0.0);
		routingTarget.resolved = new ResolvedLayoutItem(941, 1, 0.0, 0.0, 100.0, 100.0,
			broadClip, new Rect(0.0, 0.0, 0.0, 0.0), Transform2D.identity(), 0.0);
		routingTarget.focusable = true;
		routingRoot.add(routingTarget);
		focus.rebuild(routingRoot);
		if (!focus.focus(routingTarget.id))
			return false;
		var routed = 0;
		var routingCommands = new CommandRegistry();
		routingCommands.register(Command.contextual("focus.command", "Focus command", function(context) {
			if (context.document != document)
				return CommandResult.rejected("Missing active document");
			routed++;
			return CommandResult.executed();
		}, new Shortcut(UiKey.K, UiModifier.Control)), "focused");
		var globalRouted = 0;
		routingCommands.register(new Command("global.command", "Global command", function() {
			globalRouted++;
		}, new Shortcut(UiKey.K, UiModifier.Control)));
		routingRoot.commandScope = "focused";
		var dispatcher = new EventDispatcher(focus, new InteractionStateStore(), routingCommands,
			commandContext);
		dispatcher.setRoot(routingRoot);
		dispatcher.key(UiEventKind.KeyDown, UiKey.K, UiModifier.Control);
		if (routed != 1 || globalRouted != 0 || dispatcher.lastCommandResult == null ||
			!dispatcher.lastCommandResult.succeeded)
			return false;
		routingRoot.commandScope = null;
		dispatcher.key(UiEventKind.KeyDown, UiKey.K, UiModifier.Control);
		if (routed != 1 || globalRouted != 1)
			return false;

		var surfaceRegistry = new CommandRegistry();
		var surfaceRuns = 0;
		surfaceRegistry.register(new Command("surface.run", "Run simulation", function() {
			surfaceRuns++;
		}, new Shortcut(UiKey.R, UiModifier.Control)));
		surfaceRegistry.register(new Command("surface.stop", "Stop simulation", function() {}));
		var toolbar = new Toolbar("command-toolbar", ["surface.run"], surfaceRegistry);
		var toolbarRoot = uiContext.submit(toolbar, new LayoutFrame(480.0, 48.0));
		var commandButton:Null<RenderNode> = null;
		toolbarRoot.walk(function(node) {
			if (commandButton == null && node.styleType == "button" && node.styleKey == "surface.run")
				commandButton = node;
		});
		if (commandButton == null || commandButton.semantics == null ||
			commandButton.semantics.label != "Run simulation")
			return false;
		if (!uiContext.accessibilityAction(commandButton.id.value, AccessibilityAction.Activate,
			null, -1, -1, 1) || surfaceRuns != 1)
			return false;
		var commandMenu = new CommandMenu("surface-menu", ["surface.run", "surface.stop"],
			24.0, 24.0, surfaceRegistry);
		commandMenu.selectFirstOnOpen = true;
		var menuRoot = uiContext.submit(commandMenu, new LayoutFrame(480.0, 320.0));
		if (menuRoot == null || menuRoot.semantics == null ||
			menuRoot.semantics.role != AccessibilityRole.Menu)
			return false;
		var firstItem:Null<RenderNode> = null;
		menuRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.label == "Run simulation" &&
				node.semantics.role == AccessibilityRole.MenuItem)
				firstItem = node;
		});
		if (firstItem == null ||
			firstItem.computedStyle.get(StyleProperty.Background).red !=
			uiContext.buildContext.theme.tokens.selectionField.red)
			return false;
		var settledMenu = uiContext.submit(commandMenu, new LayoutFrame(480.0, 320.0));
		var settledFirst:Null<RenderNode> = settledMenu.find(firstItem.id);
		if (settledFirst == null ||
			settledFirst.computedStyle.get(StyleProperty.Background).red !=
			firstItem.computedStyle.get(StyleProperty.Background).red)
			return false;
		var sceneNudges = 0;
		uiContext.commands.register(new Command("scene.nudge", "Nudge scene", function() {
			sceneNudges++;
		}, new Shortcut(UiKey.Down)));
		uiContext.key(UiEventKind.KeyDown, UiKey.Down);
		var focused = uiContext.focus.focusedNode();
		if (sceneNudges != 0 || focused == null || focused.semantics == null ||
			focused.semantics.label != "Stop simulation")
			return false;
		var palette = new CommandPalette("surface-palette", surfaceRegistry, null,
			40.0, 40.0);
		var paletteRoot = uiContext.submit(palette, new LayoutFrame(640.0, 480.0));
		if (paletteRoot == null || paletteRoot.semantics == null ||
			paletteRoot.semantics.label != "Command palette")
			return false;
		var resultRows = 0;
		var nestedButtons = 0;
		paletteRoot.walk(function(node) {
			if (node.semantics != null &&
				node.semantics.role == AccessibilityRole.CollectionItem) {
				resultRows++;
				if (node.semantics.label == null || node.semantics.label.length == 0)
					nestedButtons++;
			}
			if (node.styleType == "button") nestedButtons++;
		});
		if (resultRows != 2 || nestedButtons != 0)
			return false;
		var centeredPalette = new CommandPalette("centered-palette", surfaceRegistry);
		centeredPalette.centered = true;
		var centeredRoot = uiContext.submit(centeredPalette, new LayoutFrame(480.0, 360.0));
		var centeredPanel = centeredRoot.children[1];
		var centeredGeometry = centeredPanel.resolved;
		if (centeredRoot.children[0].layout.style.zIndex != 1000 ||
			centeredPanel.layout.style.zIndex != 1001 || centeredGeometry == null ||
			centeredGeometry.x < 7.0 ||
			centeredGeometry.x + centeredGeometry.width > 473.0 ||
			centeredGeometry.y < 7.0 ||
			centeredGeometry.y + centeredGeometry.height > 353.0)
			return false;
		var centeredSearch:Null<RenderNode> = null;
		centeredRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.label == "Search commands" &&
				node.styleType == "text-field") centeredSearch = node;
		});
		if (centeredSearch == null) return false;
		var localCaretLayer = false;
		centeredSearch.walk(function(node) {
			if (node.layout.visualKind == LayoutVisualKind.Custom &&
				node.layout.style.zIndex == 2)
				localCaretLayer = true;
		});
		if (!localCaretLayer) return false;
		uiContext.key(UiEventKind.KeyDown, UiKey.Down);
		uiContext.key(UiEventKind.KeyDown, UiKey.R, UiModifier.Control);
		if (sceneNudges != 0 || surfaceRuns != 1)
			return false;
		uiContext.key(UiEventKind.KeyDown, UiKey.Up);
		uiContext.key(UiEventKind.KeyDown, UiKey.Enter);
		if (surfaceRuns != 2)
			return false;
		var disabledRuns = 0;
		surfaceRegistry.register(new Command("surface.disabled", "Unavailable", function() {
			disabledRuns++;
		}, null, function() return false));
		var disabledPalette = new CommandPalette("disabled-palette", surfaceRegistry,
			null, 0.0, 0.0, "Unavailable");
		var disabledRoot = uiContext.submit(disabledPalette,
			new LayoutFrame(480.0, 360.0));
		var disabledRow:Null<RenderNode> = null;
		disabledRoot.walk(function(node) {
			if (node.semantics != null &&
				node.semantics.role == AccessibilityRole.CollectionItem)
				disabledRow = node;
		});
		if (disabledRow == null)
			return false;
		var disabledSemantics:Semantics = cast disabledRow.semantics;
		if (disabledSemantics.label != "Unavailable" ||
			(disabledSemantics.states & AccessibilityState.Disabled) == 0 ||
			disabledRow.focusable)
			return false;
		uiContext.key(UiEventKind.KeyDown, UiKey.Enter);
		if (disabledRuns != 0)
			return false;
		var pointerResults = 0, pointerDismissals = 0;
		var pointerPalette = new CommandPalette("pointer-palette", surfaceRegistry, null, 0, 0, "",
			function() pointerDismissals++, function(_) pointerResults++);
		var pointerFrame = new LayoutFrame(640, 480);
		var pointerRoot = uiContext.submit(pointerPalette, pointerFrame);
		var runRow:Null<RenderNode> = null;
		pointerRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.CollectionItem &&
				node.semantics.label == "Run simulation") runRow = node;
		});
		if (runRow == null) return false;
		var rowBounds = runRow.globalBounds();
		uiContext.pointerDown(rowBounds.x + 20, rowBounds.y + 18, 1);
		uiContext.pointerUp(rowBounds.x + 20, rowBounds.y + 18, 1);
		if (surfaceRuns != 2 || pointerResults != 0) return false;
		uiContext.pointerDown(rowBounds.x + 20, rowBounds.y + 18, 0);
		uiContext.submit(pointerPalette, pointerFrame);
		uiContext.pointerUp(rowBounds.x + 20, rowBounds.y + 18, 0);
		if (surfaceRuns != 3 || pointerResults != 1 || pointerDismissals != 1)
			throw "A palette row primary click must execute exactly once and dismiss the palette";
		return true;
	}

	static function transientWidgetLifetimeValid(context:UiContext):Bool {
		var frame = new LayoutFrame(240, 80);
		context.submit(new Text("lifetime baseline"), frame);
		var before = context.buildContext.stateStore.diagnosticCounts();
		var beforeKeys = context.buildContext.diagnosticKeyCounts();
		for (index in 0...40) {
			var content = new LayoutStyle(); content.height = LayoutAxis.fixed(500);
			var label = new haxeon.ui.widgets.text.MiddleEllipsisText("label-" + index, "A long transient label");
			var children:Array<KeyedView> = [new KeyedView("label", label)];
			var scroll = new ScrollView("scroll-" + index, new Column("content", children, content));
			context.submit(scroll, frame);
			context.submit(new Text("lifetime baseline"), frame);
		}
		var after = context.buildContext.stateStore.diagnosticCounts();
		var afterKeys = context.buildContext.diagnosticKeyCounts();
		return after.values == before.values && after.resources == before.resources && after.paths == before.paths &&
			afterKeys.ids == beforeKeys.ids && afterKeys.paths == beforeKeys.paths;
	}

	static function selfUpdatingLifetimeValid(context:UiContext):Bool {
		var field = new TextField("builder-lifetime", "document");
		var view = new haxeon.ui.core.RetainedView("builder-retained", function(_) return field);
		var frame = new LayoutFrame(240, 80);
		var root = context.submit(view, frame);
		var id = root.id;
		// Retained trees must keep patching without rebuilding their widget.
		context.submit(view, frame);
		if (!context.buildContext.requestPatch(id)) return false;
		context.submit(view, frame);
		context.submit(new Text("unmounted builder"), frame);
		if (context.buildContext.requestPatch(id)) return false;
		// A fresh mount with the same key restores a live builder.
		root = context.submit(view, frame);
		if (!root.id.equals(id) || !context.buildContext.requestPatch(id)) return false;
		context.submit(new Text("unmounted again"), frame);
		return !context.buildContext.requestPatch(id);
	}

	static function externalScrollbarValid(context:UiContext):Bool {
		var controller = new ScrollController();
		var view = new ExternalScrollbarSmoke(controller);
		var frame = new LayoutFrame(240, 80); frame.deltaSeconds = 0;
		var root = context.submit(view, frame);
		var track = root.children[0], viewport = root.children[1], fixed = root.children[2];
		var bounds = track.globalBounds(), side = fixed.globalBounds();
		if (viewport.children.length != 1 || Math.abs(bounds.x + bounds.width - 238) > 0.01
			|| bounds.x < side.x || Math.abs(controller.viewportWidth - 160) > 0.01) return false;
		context.pointerMove(bounds.x + 5, bounds.y + 40);
		context.scroll(bounds.x + 5, bounds.y + 40, 0, 20);
		if (controller.offsetY != 20) return false;
		root = context.submit(view, frame); track = root.children[0];
		var thumb = track.children[0];
		if (!context.focusWidget(thumb.id)) return false;
		context.key(UiEventKind.KeyDown, UiKey.PageDown);
		if (controller.offsetY <= 20) return false;
		frame.deltaSeconds = 0.3; root = context.submit(view, frame); track = root.children[0]; thumb = track.children[0];
		var thumbBounds = thumb.globalBounds(), before = controller.offsetY;
		context.pointerDown(thumbBounds.x + 4, thumbBounds.y + thumbBounds.height / 2, 0);
		context.pointerMove(-20, thumbBounds.y + thumbBounds.height / 2 + 15);
		if (controller.offsetY <= before) return false;
		context.pointerUp(-20, thumbBounds.y + thumbBounds.height / 2 + 15, 0);
		frame.deltaSeconds = 0.8; root = context.submit(view, frame);
		var color = root.children[0].children[0].children[0].layout.style.background;
		if (color == null || color.alpha != 0) return false;
		frame.deltaSeconds = 0; context.submit(new Text("external-unmounted"), frame);
		return context.animations.activeCount == 0;
	}

	static function scrollbarVisual(root:RenderNode):RenderNode {
		return root.children[1].children[0].children[0];
	}

	static function scrollbarAlpha(root:RenderNode):Float {
		var color = scrollbarVisual(root).layout.style.background;
		return color == null ? -1.0 : color.alpha;
	}

	static function scrollbarCheck(value:Bool, message:String):Void {
		if (!value) throw "Scrollbar visibility: " + message;
	}

	static function scrollbarVisibilityValid(context:UiContext):Bool {
		var clock = new AnimationScheduler();
		var visibility = new haxeon.ui.widgets.scroll.ScrollbarVisibilityController();
		visibility.attach(clock, function() {});
		visibility.setAvailable(true);
		scrollbarCheck(visibility.opacity == 0, "new scrollbar is hidden");
		visibility.reveal();
		scrollbarCheck(visibility.opacity == 0 && clock.activeCount == 1, "reveal schedules a fade");
		clock.advance(0.15);
		scrollbarCheck(Math.abs(visibility.opacity - 0.5) < 0.001, "gradual fade-in");
		visibility.reveal(); clock.advance(0.15);
		scrollbarCheck(visibility.opacity == 1, "repeated activity preserves fade progress");
		clock.advance(0.49);
		scrollbarCheck(visibility.opacity == 1, "idle delay follows completed fade-in");
		clock.advance(0.11);
		scrollbarCheck(Math.abs(visibility.opacity - 0.5) < 0.001, "gradual fade-out");
		clock.advance(0.11);
		scrollbarCheck(visibility.opacity == 0 && clock.activeCount == 0, "idle animation stops");

		visibility.setViewportHovered(true); clock.advance(0.15);
		visibility.setAvailable(true);
		scrollbarCheck(Math.abs(visibility.opacity - 0.5) < 0.001, "layout does not interrupt the fade");
		clock.advance(0.15); clock.advance(2);
		scrollbarCheck(visibility.opacity == 1 && clock.activeCount == 0, "pane hover holds without continuous animation");
		visibility.setHovered(true); visibility.setViewportHovered(false);
		clock.advance(2);
		scrollbarCheck(visibility.opacity == 1, "external track hover holds visibility");
		visibility.setDragging(true); visibility.setHovered(false); clock.advance(2);
		scrollbarCheck(visibility.opacity == 1, "dragging holds visibility");
		visibility.setFocused(true); visibility.setDragging(false); clock.advance(2);
		scrollbarCheck(visibility.opacity == 1, "keyboard focus holds visibility");
		visibility.setFocused(false); clock.advance(0.1);
		var fading = visibility.opacity;
		visibility.setViewportHovered(true);
		scrollbarCheck(visibility.opacity == fading && fading > 0 && fading < 1, "re-entry reverses without an opacity jump");
		clock.advance(0.3);
		visibility.setAvailable(false);
		scrollbarCheck(visibility.opacity == 0 && visibility.viewportHovered && clock.activeCount == 0, "overflow loss preserves pane hover");
		visibility.setAvailable(true);
		scrollbarCheck(visibility.opacity == 0 && clock.activeCount == 1, "new overflow fades in under a stationary pointer");
		clock.advance(0.3);

		visibility.configure(haxeon.ui.widgets.scroll.ScrollbarVisibility.Auto, true);
		visibility.setViewportHovered(false);
		scrollbarCheck(visibility.opacity == 0, "reduced motion hides immediately on exit");
		visibility.setViewportHovered(true);
		scrollbarCheck(visibility.opacity == 1 && clock.activeCount == 0, "reduced motion reveals immediately");
		visibility.configure(haxeon.ui.widgets.scroll.ScrollbarVisibility.Hidden, false);
		scrollbarCheck(visibility.opacity == 0 && clock.activeCount == 0, "hidden policy overrides hover");
		visibility.configure(haxeon.ui.widgets.scroll.ScrollbarVisibility.Always, false);
		scrollbarCheck(visibility.opacity == 1 && clock.activeCount == 0, "always policy does not animate");
		visibility.setAvailable(false);
		scrollbarCheck(visibility.opacity == 0, "no scrollbar without overflow");
		visibility.setAvailable(true);
		scrollbarCheck(visibility.opacity == 1, "always policy restores on overflow");
		visibility.configure(haxeon.ui.widgets.scroll.ScrollbarVisibility.Hidden, false);
		visibility.configure(haxeon.ui.widgets.scroll.ScrollbarVisibility.Auto, false);
		scrollbarCheck(clock.activeCount == 1, "auto policy fades in while hovered");
		visibility.dispose();
		scrollbarCheck(clock.activeCount == 0, "unmount cancels animation");

		var coarseClock = new AnimationScheduler(), fineClock = new AnimationScheduler();
		var coarse = new haxeon.ui.widgets.scroll.ScrollbarVisibilityController();
		var fine = new haxeon.ui.widgets.scroll.ScrollbarVisibilityController();
		coarse.attach(coarseClock, function() {}); fine.attach(fineClock, function() {});
		coarse.setAvailable(true); fine.setAvailable(true);
		coarse.reveal(); fine.reveal(); coarseClock.advance(0.9);
		for (_ in 0...9) fineClock.advance(0.1);
		scrollbarCheck(Math.abs(coarse.opacity - fine.opacity) < 0.001, "frame-rate-independent phase timing");
		coarse.dispose(); fine.dispose();

		var oldPolicy = context.buildContext.environment.scrollbarVisibility;
		context.buildContext.environment.scrollbarVisibility = haxeon.ui.widgets.scroll.ScrollbarVisibility.Auto;
		context.pointerMove(-20, -20);
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(180); style.height = LayoutAxis.fixed(80);
		var content = new LayoutStyle(); content.width = LayoutAxis.fixed(180); content.height = LayoutAxis.fixed(600);
		var frame = new LayoutFrame(180, 80); frame.deltaSeconds = 0;
		var controller = new ScrollController();
		var view = new ScrollView("visibility-regression", new Column("content", [], content), style, ScrollAxis.Vertical, controller);
		var root = context.submit(view, frame);
		var restingAlpha = context.buildContext.theme.tokens.textSecondary.alpha * 0.4;
		var activeAlpha = context.buildContext.theme.tokens.textSecondary.alpha * 0.65;
		scrollbarCheck(scrollbarAlpha(root) == 0 && !root.children[1].children[0].hitTestSelf, "transparent thumb has no pointer target");
		context.pointerMove(20, 20);
		root = context.submit(view, frame);
		scrollbarCheck(scrollbarAlpha(root) == 0, "pane entry starts at zero opacity");
		frame.deltaSeconds = 0.15; root = context.submit(view, frame);
		scrollbarCheck(scrollbarAlpha(root) > 0 && scrollbarAlpha(root) < restingAlpha,
			"pane hover animates actual thumb paint: alpha=" + scrollbarAlpha(root) + " resting=" + restingAlpha);
		root = context.submit(view, frame);
		scrollbarCheck(Math.abs(scrollbarAlpha(root) - restingAlpha) < 0.001 &&
			controller.offsetY == 0 && controller.viewportWidth == 180, "pane hover reveals without scrolling or reserving width");
		context.pointerMove(40, 40);
		frame.deltaSeconds = 1; root = context.submit(view, frame);
		scrollbarCheck(Math.abs(scrollbarAlpha(root) - restingAlpha) < 0.001, "moving between descendants does not hide the scrollbar");
		var track:ResolvedLayoutItem = cast root.children[1].resolved;
		context.pointerMove(track.x + 5, track.y + 50);
		frame.deltaSeconds = 0; root = context.submit(view, frame);
		scrollbarCheck(Math.abs(scrollbarAlpha(root) - activeAlpha) < 0.001, "track hover retains stronger styling");
		context.pointerMove(20, 20);
		frame.deltaSeconds = 1; root = context.submit(view, frame);
		scrollbarCheck(Math.abs(scrollbarAlpha(root) - restingAlpha) < 0.001, "leaving the track inside the pane keeps it visible");
		context.pointerMove(220, 100);
		frame.deltaSeconds = 0.1; root = context.submit(view, frame);
		scrollbarCheck(scrollbarAlpha(root) > 0 && scrollbarAlpha(root) < restingAlpha, "pane exit fades out immediately");
		root = context.submit(view, frame);
		scrollbarCheck(scrollbarAlpha(root) == 0, "pane exit finishes hiding");

		context.scroll(20, 20, 0, 40);
		frame.deltaSeconds = 0.15; root = context.submit(view, frame);
		scrollbarCheck(controller.offsetY == 40 && scrollbarAlpha(root) > 0 && scrollbarAlpha(root) < restingAlpha,
			"scroll activity fades in without requiring pane hover");

		frame.deltaSeconds = 0;
		context.pointerMove(20, 20); root = context.submit(view, frame);
		content.height = LayoutAxis.fixed(20);
		view = new ScrollView("visibility-regression", new Column("content", [], content), style, ScrollAxis.Vertical, controller);
		root = context.submit(view, frame);
		scrollbarCheck(!root.children[1].layout.style.visible && context.animations.activeCount == 0, "no hover animation without overflow");
		content.height = LayoutAxis.fixed(600);
		view = new ScrollView("visibility-regression", new Column("content", [], content), style, ScrollAxis.Vertical, controller);
		root = context.submit(view, frame);
		frame.deltaSeconds = 0.15; root = context.submit(view, frame);
		scrollbarCheck(scrollbarAlpha(root) > 0 && scrollbarAlpha(root) < restingAlpha, "overflow restoration reveals under a stationary pointer");

		context.buildContext.environment.scrollbarVisibility = haxeon.ui.widgets.scroll.ScrollbarVisibility.Hidden;
		frame.deltaSeconds = 0; root = context.submit(view, frame);
		scrollbarCheck(root.children.length == 1 && context.animations.activeCount == 0, "hidden policy removes track and animation");
		context.buildContext.environment.scrollbarVisibility = haxeon.ui.widgets.scroll.ScrollbarVisibility.Always;
		root = context.submit(view, frame); root = context.submit(view, frame);
		scrollbarCheck(Math.abs(scrollbarAlpha(root) - restingAlpha) < 0.001, "always policy paints immediately");
		context.submit(new Text("unmounted"), frame);
		context.buildContext.environment.scrollbarVisibility = oldPolicy;
		scrollbarCheck(context.animations.activeCount == 0, "view unmount cancels visibility animation");
		return true;
	}

	static function smoothScrollValid(context:UiContext):Bool {
		var motion = new ScrollController(); motion.configureAnimation(true);
		motion.scrollBy(0, 100); motion.advance(1.0 / 60.0);
		if (motion.offsetY <= 40 || motion.offsetY >= 100) return false;
		for (_ in 0...7) motion.advance(1.0 / 60.0);
		if (motion.offsetY < 99) return false;
		motion.jumpTo(0, 0); motion.scrollBy(0, 100); motion.advance(1.0 / 60.0);
		var before = motion.offsetY; motion.scrollBy(0, -20); motion.advance(1.0 / 60.0);
		if (motion.offsetY >= before) return false;
		var slow = new ScrollController(), fast = new ScrollController();
		slow.configureAnimation(true); fast.configureAnimation(true);
		slow.scrollBy(1000, 1000); fast.scrollBy(1000, 1000);
		for (_ in 0...3) slow.advance(1.0 / 30.0);
		for (_ in 0...12) fast.advance(1.0 / 120.0);
		if (Math.abs(slow.offsetY - fast.offsetY) > 0.000001) return false;
		motion.jumpTo(0, 30); if (motion.advance(0.1) || motion.offsetY != 30) return false;
		motion.configureAnimation(true, 0); motion.scrollBy(0, 10);
		if (motion.offsetY != 40) return false;
		motion.configureAnimation(true); motion.scrollBy(0, 100); motion.configureAnimation(false);
		if (motion.offsetY != 140 || motion.advance(0.1)) return false;
		var style = new LayoutStyle(); style.width = LayoutAxis.fixed(200); style.height = LayoutAxis.fixed(100);
		var content = new LayoutStyle(); content.width = LayoutAxis.fixed(200); content.height = LayoutAxis.fixed(1000);
		var frame = new LayoutFrame(200, 100); frame.deltaSeconds = 0;
		context.events.cancelPointers();
		var mounted = new ScrollController(); mounted.configureAnimation(true);
		context.submit(new ScrollView("smooth-lifetime", new Column("content", [], content), style, ScrollAxis.Vertical, mounted), frame);
		context.scroll(20, 20, 0, 100);
		if (mounted.offsetY != 0 || context.animations.activeCount != 2) return false;
		frame.deltaSeconds = 1.0 / 60.0;
		context.submit(new ScrollView("smooth-lifetime", new Column("content", [], content), style, ScrollAxis.Vertical, mounted), frame);
		if (mounted.offsetY <= 40 || mounted.offsetY >= 100) return false;
		// Keep the pointer outside while testing binding ownership; pane hover
		// legitimately schedules the replacement scrollbar's fade-in.
		context.pointerMove(-20, -20);
		var replacement = new ScrollController(); replacement.configureAnimation(true);
		frame.deltaSeconds = 0;
		context.submit(new ScrollView("smooth-lifetime", new Column("content", [], content), style, ScrollAxis.Vertical, replacement), frame);
		if (context.animations.activeCount != 0) return false;
		replacement.scrollBy(0, 100);
		if (context.animations.activeCount != 2) return false;
		// Moving a supplied controller creates the new mount before retiring the old one.
		context.submit(new ScrollView("smooth-moved", new Column("content", [], content), style, ScrollAxis.Vertical, replacement), frame);
		if (context.animations.activeCount != 1)
			throw "old scroll mount detached replacement binding: animations=" + context.animations.activeCount;
		context.animations.advance(1.0 / 60.0);
		if (replacement.offsetY <= 40) return false;
		context.submit(new Text("unmounted"), frame);
		return context.animations.activeCount == 0 && !replacement.advance(0.1);
	}

	static function sidebarValid(context:UiContext):Bool {
		var model = new haxeon.ui.widgets.sidebar.SidebarModel();
		var files = 0, search = 0;
		model.register("search", function() { search++; return new Text("Search content"); },
			new haxeon.ui.widgets.sidebar.SidebarModeOptions("Search", 10, true));
		model.register("files", function() { files++; return new Text("Files content"); },
			new haxeon.ui.widgets.sidebar.SidebarModeOptions("Files", 0, true));
		model.select("files");
		if (files != 0 || search != 0 || model.modes[0].id != "files") return false;
		var view = new haxeon.ui.widgets.sidebar.SidebarHost("sidebar-regression", model, function(id) { model.select(id); });
		context.submit(view, new LayoutFrame(240, 240));
		if (files != 1 || search != 0) return false;
		model.select("search");
		context.submit(view, new LayoutFrame(320, 240));
		var filesMode = model.find("files");
		if (filesMode == null || files != 1 || search != 1 || model.width != 320) return false;
		model.setVisible(false);
		context.submit(view, new LayoutFrame(320, 240));
		if (files != 1 || search != 1) return false;
		var state = model.encode(), restored = new haxeon.ui.widgets.sidebar.SidebarModel();
		if (!restored.restore(state)) return false;
		restored.register("files", function() return new Text("Files"), new haxeon.ui.widgets.sidebar.SidebarModeOptions("Files"));
		restored.register("search", function() return new Text("Search"), new haxeon.ui.widgets.sidebar.SidebarModeOptions("Search"));
		var searchMode = restored.find("search");
		if (searchMode == null || restored.activeId != "search" || restored.visible || restored.width != 320) return false;
		var before = restored.encode();
		for (invalid in ["2|search|1|", "1|search|1|search,NaN,1", "1|search|1|search,320oops,1", "1|search|1|search,320,1;search,240,1"])
			if (restored.restore(invalid) || restored.encode() != before) return false;
		if (!restored.setModeVisible("search", false)) return false;
		var selected = restored.selected();
		if (selected == null || selected.id != "files") return false;
		var dock = new DockWorkspaceModel();
		dock.register(new DockPanelDescriptor("sidebar", "Sidebar"));
		dock.register(new DockPanelDescriptor("editor", "Editor"));
		dock.setDefaultLayout(DockNode.Split(DockSplitAxis.Horizontal, 0.25, DockNode.Panel("sidebar"), DockNode.Panel("editor")));
		if (!dock.setPanelWidth("sidebar", 320, 1000)) return false;
		switch dock.root { case Split(_, ratio, _, _): if (ratio != 0.32) return false; case _: return false; }
		if (!dock.setPanelWidth("editor", 500, 1000, 8)) return false;
		switch dock.root { case Split(_, ratio, _, _): if (Math.abs(ratio - 0.492) > 0.0001) return false; case _: return false; }
		dock.register(new DockPanelDescriptor("outer", "Outer"));
		dock.setDefaultLayout(DockNode.Split(DockSplitAxis.Horizontal, 0.6,
			DockNode.Split(DockSplitAxis.Horizontal, 0.2, DockNode.Panel("sidebar"), DockNode.Panel("editor")), DockNode.Panel("outer")));
		if (!dock.setPanelWidth("sidebar", 240, 1000, 8)) return false;
		switch dock.root { case Split(_, outerRatio, Split(_, innerRatio, _, _), _):
			if (outerRatio != 0.6 || Math.abs(innerRatio - 0.4) > 0.0001) return false;
			case _: return false;
		}
		if (!restored.unregister("search") || !restored.restore("1|future|1|future,360,1")) return false;
		restored.register("future", function() return new Text("Future"), new haxeon.ui.widgets.sidebar.SidebarModeOptions("Future"));
		var future = restored.selected();
		if (future == null || future.id != "future" || restored.width != 360) return false;
		trace("PASS: sidebar lazy providers, shared width, deferred registration and atomic persistence");
		return true;
	}

	static function dockWorkspaceValid(uiContext:UiContext):Bool {
		var hierarchyBuilds = 0;
		var viewportBuilds = 0;
		var viewportDockWidth = 0.0;
		var inspectorBuilds = 0;
		var consoleBuilds = 0;
		var model = new DockWorkspaceModel();
		model.register(new DockPanelDescriptor("hierarchy", "Hierarchy", false));
		model.register(new DockPanelDescriptor("viewport", "Viewport"));
		model.register(new DockPanelDescriptor("inspector", "Inspector"));
		model.register(new DockPanelDescriptor("console", "Console"));
		var panelContents = [
			new DockPanelContent("hierarchy", function(_) {
				hierarchyBuilds++;
				return new Text("Hierarchy");
			}),
			new DockPanelContent("viewport", function(_) {
				throw "Width-aware viewport builder was bypassed";
			}, function(_, width) {
				viewportBuilds++;
				viewportDockWidth = width;
				return new Text("Viewport");
			}),
			new DockPanelContent("inspector", function(_) {
				inspectorBuilds++;
				return new Text("Inspector");
			}),
			new DockPanelContent("console", function(_) {
				consoleBuilds++;
				return new Text("Console");
			})
		];
		var defaultLayout = DockNode.Split(DockSplitAxis.Horizontal, 0.3,
			DockNode.Panel("hierarchy"), DockNode.Tabs(["viewport", "inspector"], "viewport"));
		model.setDefaultLayout(defaultLayout);
		var reorder = new DockWorkspaceModel();
		for (panelId in ["a", "b", "c"])
			reorder.register(new DockPanelDescriptor(panelId, panelId, false));
		reorder.setDefaultLayout(DockNode.Tabs(["a", "b", "c"], "a"));
		if (!reorder.dock("a", "c", DockDropZone.TabAfter))
			return false;
		switch (reorder.root) {
			case DockNode.Tabs(ids, active):
				if (ids.length != 3 || ids[0] != "b" || ids[1] != "c" || ids[2] != "a" ||
					active != "a")
					return false;
			default: return false;
		}
		var singletonDock = new DockWorkspaceModel();
		var groupedDock = new DockWorkspaceModel();
		groupedDock.register(new DockPanelDescriptor("surface", "Surface", false, true, null,
			haxeon.ui.docking.DockPanelHeaderMode.Content,
			new haxeon.ui.docking.DockPanelGrouping("surfaces", false)));
		groupedDock.register(new DockPanelDescriptor("tool-a", "Tool A", true, true, null,
			haxeon.ui.docking.DockPanelHeaderMode.Dock,
			new haxeon.ui.docking.DockPanelGrouping("tools")));
		groupedDock.register(new DockPanelDescriptor("tool-b", "Tool B", true, true, null,
			haxeon.ui.docking.DockPanelHeaderMode.Dock,
			new haxeon.ui.docking.DockPanelGrouping("tools")));
		groupedDock.setDefaultLayout(DockNode.Panel("surface"));
		if (groupedDock.canDock("tool-a", "surface", DockDropZone.Center) ||
			groupedDock.dock("tool-a", "surface", DockDropZone.TabBefore) ||
			!groupedDock.open("tool-a", "surface") || !groupedDock.open("tool-b", "surface")) return false;
		var groupedSnapshot = new haxeon.ui.docking.DockWorkspaceSnapshot(DockNode.Tabs(["surface", "tool-a", "tool-b"], "tool-b"), "tool-b");
		if (!groupedDock.restorePersisted(groupedSnapshot) || groupedDock.activePanelId != "tool-b") return false;
		switch groupedDock.root {
			case Split(Vertical, _, Panel("surface"), Tabs(ids, selected)):
				if (ids.length != 2 || ids[0] != "tool-a" || ids[1] != "tool-b" || selected != "tool-b") return false;
			default: return false;
		}
		var groupedJson = groupedDock.snapshotJson();
		if (!groupedDock.restoreJson(groupedJson) || groupedDock.snapshotJson() != groupedJson) return false;
		if (!groupedDock.canDock("tool-a", "surface", DockDropZone.Right) ||
			!groupedDock.dock("tool-a", "surface", DockDropZone.Right)) return false;
		var contentHeaderDock = new DockWorkspaceModel();
		contentHeaderDock.register(new DockPanelDescriptor("content-header", "Content header", false,
			true, null, haxeon.ui.docking.DockPanelHeaderMode.Content));
		contentHeaderDock.register(new DockPanelDescriptor("tool-header", "Tool header"));
		contentHeaderDock.setDefaultLayout(DockNode.Panel("content-header"));
		var contentHeaderWorkspace = new DockWorkspace("content-header-workspace", contentHeaderDock);
		var contentHeaderRoot = uiContext.submit(contentHeaderWorkspace, new LayoutFrame(640.0, 480.0));
		var contentHeaderTabs = 0;
		if (contentHeaderRoot == null) return false;
		contentHeaderRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab) contentHeaderTabs++;
		});
		if (contentHeaderTabs != 0) return false;
		if (!contentHeaderDock.dock("tool-header", "content-header", DockDropZone.Center)) return false;
		contentHeaderRoot = uiContext.submit(contentHeaderWorkspace, new LayoutFrame(640.0, 480.0));
		contentHeaderTabs = 0;
		if (contentHeaderRoot == null) return false;
		contentHeaderRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab) contentHeaderTabs++;
		});
		if (contentHeaderTabs != 2) return false;
		if (!contentHeaderDock.close("tool-header")) return false;
		contentHeaderRoot = uiContext.submit(contentHeaderWorkspace, new LayoutFrame(640.0, 480.0));
		contentHeaderTabs = 0;
		if (contentHeaderRoot == null) return false;
		contentHeaderRoot.walk(function(node) {
			if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab) contentHeaderTabs++;
		});
		if (contentHeaderTabs != 0) return false;
		for (panelId in ["single-source", "single-target"])
			singletonDock.register(new DockPanelDescriptor(panelId, panelId));
		singletonDock.setDefaultLayout(DockNode.Split(DockSplitAxis.Horizontal, 0.5,
			DockNode.Panel("single-source"), DockNode.Panel("single-target")));
		var singletonWorkspace = new DockWorkspace("singleton-dock-workspace", singletonDock);
		var singletonRoot = uiContext.submit(singletonWorkspace, new LayoutFrame(640.0, 480.0));
		var singletonTabs:Array<RenderNode> = [];
		var singletonSourceTab:Null<RenderNode> = null;
		var singletonTargetTab:Null<RenderNode> = null;
		if (singletonRoot != null)
			singletonRoot.walk(function(node) {
				if (node.styleType == "tabs") singletonTabs.push(node);
				if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab) {
					if (node.semantics.label == "single-source") singletonSourceTab = node;
					if (node.semantics.label == "single-target") singletonTargetTab = node;
				}
			});
		if (singletonTabs.length != 2 || singletonSourceTab == null || singletonTargetTab == null)
			return false;
		var sourceBounds = singletonSourceTab.globalBounds(), targetBounds = singletonTargetTab.globalBounds();
		var sourceX = sourceBounds.x + sourceBounds.width * 0.5;
		var sourceY = sourceBounds.y + sourceBounds.height * 0.5;
		var targetX = targetBounds.x + targetBounds.width * 0.5;
		var targetY = targetBounds.y + targetBounds.height * 0.5;
		var ownPaneBounds = singletonTabs[0].globalBounds();
		var ownPaneX = ownPaneBounds.x + ownPaneBounds.width * 0.5;
		var ownPaneY = ownPaneBounds.y + ownPaneBounds.height * 0.5;
		var tabPlatformCaptureStates:Array<Bool> = [];
		uiContext.setPointerCaptureHandler(function(captured) tabPlatformCaptureStates.push(captured));
		uiContext.pointerDown(sourceX, sourceY, 0);
		if (tabPlatformCaptureStates.length != 0)
			return false;
		uiContext.pointerMove(ownPaneX, ownPaneY);
		if (singletonWorkspace.interaction.preview == null)
			return false;
		singletonRoot = uiContext.submit(singletonWorkspace, new LayoutFrame(640.0, 480.0));
		if (!uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		uiContext.pointerUp(ownPaneX, ownPaneY, 0);
		if (singletonWorkspace.interaction.preview != null || uiContext.events.hasPointerCapture(singletonSourceTab.id) ||
			tabPlatformCaptureStates.length != 0)
			return false;
		switch (singletonDock.root) {
			case DockNode.Split(_, _, DockNode.Panel("single-source"), DockNode.Panel("single-target")):
			default: return false;
		}
		uiContext.pointerDown(sourceX, sourceY, 0);
		if (!uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		uiContext.pointerMove(targetX, targetY);
		if (singletonWorkspace.interaction.preview == null)
			return false;
		singletonRoot = uiContext.submit(singletonWorkspace, new LayoutFrame(640.0, 480.0));
		if (!uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		uiContext.pointerUp(targetX, targetY, 0);
		if (singletonWorkspace.interaction.preview != null || uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		switch (singletonDock.root) {
			case DockNode.Tabs(ids, active):
				if (ids.length != 2 || !ids.contains("single-source") || !ids.contains("single-target") ||
					active != "single-source")
					return false;
			default: return false;
		}
		singletonRoot = uiContext.submit(singletonWorkspace, new LayoutFrame(640.0, 480.0));
		singletonTargetTab = null;
		if (singletonRoot != null)
			singletonRoot.walk(function(node) {
				if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab &&
					node.semantics.label == "single-target") singletonTargetTab = node;
			});
		if (singletonTargetTab == null)
			return false;
		targetBounds = singletonTargetTab.globalBounds();
		uiContext.pointerDown(targetBounds.x + targetBounds.width * 0.5,
			targetBounds.y + targetBounds.height * 0.5, 0);
		uiContext.pointerUp(targetBounds.x + targetBounds.width * 0.5,
			targetBounds.y + targetBounds.height * 0.5, 0);
		if (singletonDock.activePanelId != "single-target")
			return false;
		singletonRoot = uiContext.submit(singletonWorkspace, new LayoutFrame(640.0, 480.0));
		singletonSourceTab = null;
		singletonTargetTab = null;
		if (singletonRoot != null)
			singletonRoot.walk(function(node) {
				if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab) {
					if (node.semantics.label == "single-source") singletonSourceTab = node;
					if (node.semantics.label == "single-target") singletonTargetTab = node;
				}
			});
		if (singletonSourceTab == null || singletonTargetTab == null)
			return false;
		sourceBounds = singletonSourceTab.globalBounds();
		targetBounds = singletonTargetTab.globalBounds();
		sourceX = sourceBounds.x + sourceBounds.width * 0.5;
		sourceY = sourceBounds.y + sourceBounds.height * 0.5;
		targetX = targetBounds.x + targetBounds.width * 0.5;
		targetY = targetBounds.y + targetBounds.height * 0.5;
		uiContext.pointerDown(sourceX, sourceY, 0);
		uiContext.pointerMove(targetX, targetY);
		if (singletonWorkspace.interaction.preview == null)
			return false;
		uiContext.pointerLeave();
		if (singletonWorkspace.interaction.preview != null ||
			!uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		singletonRoot = uiContext.submit(singletonWorkspace, new LayoutFrame(640.0, 480.0));
		if (!uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		uiContext.pointerMove(targetX, targetY);
		if (singletonWorkspace.interaction.preview == null)
			return false;
		uiContext.pointerUp(targetX, targetY, 0);
		if (singletonWorkspace.interaction.preview != null ||
			uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		switch (singletonDock.root) {
			case DockNode.Tabs(ids, active):
				if (ids.length != 2 || !ids.contains("single-source") || !ids.contains("single-target") ||
					active != "single-source")
					return false;
			default: return false;
		}
		singletonRoot = uiContext.submit(singletonWorkspace, new LayoutFrame(640.0, 480.0));
		singletonTargetTab = null;
		if (singletonRoot != null)
			singletonRoot.walk(function(node) {
				if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab &&
					node.semantics.label == "single-target") singletonTargetTab = node;
			});
		if (singletonTargetTab == null)
			return false;
		targetBounds = singletonTargetTab.globalBounds();
		uiContext.pointerDown(targetBounds.x + targetBounds.width * 0.5,
			targetBounds.y + targetBounds.height * 0.5, 0);
		uiContext.pointerUp(targetBounds.x + targetBounds.width * 0.5,
			targetBounds.y + targetBounds.height * 0.5, 0);
		if (singletonDock.activePanelId != "single-target")
			return false;
		singletonRoot = uiContext.submit(singletonWorkspace, new LayoutFrame(640.0, 480.0));
		singletonSourceTab = null;
		singletonTargetTab = null;
		if (singletonRoot != null)
			singletonRoot.walk(function(node) {
				if (node.semantics != null && node.semantics.role == AccessibilityRole.Tab) {
					if (node.semantics.label == "single-source") singletonSourceTab = node;
					if (node.semantics.label == "single-target") singletonTargetTab = node;
				}
			});
		if (singletonSourceTab == null || singletonTargetTab == null)
			return false;
		sourceBounds = singletonSourceTab.globalBounds();
		targetBounds = singletonTargetTab.globalBounds();
		sourceX = sourceBounds.x + sourceBounds.width * 0.5;
		sourceY = sourceBounds.y + sourceBounds.height * 0.5;
		targetX = targetBounds.x + targetBounds.width * 0.5;
		targetY = targetBounds.y + targetBounds.height * 0.5;
		uiContext.pointerDown(sourceX, sourceY, 0);
		uiContext.pointerMove(targetX, targetY);
		if (singletonWorkspace.interaction.preview == null ||
			!uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		uiContext.key(UiEventKind.KeyDown, UiKey.Escape);
		if (singletonWorkspace.interaction.draggingPanelId != null ||
			singletonWorkspace.interaction.preview != null ||
			uiContext.events.hasPointerCapture(singletonSourceTab.id))
			return false;
		uiContext.setPointerCaptureHandler(null);
		var changes = 0;
		model.listen(function() changes++);
		var workspace = new DockWorkspace("editor-workspace", model, panelContents);
		var workspaceRoot = uiContext.submit(workspace, new LayoutFrame(640.0, 480.0));
		if (workspaceRoot == null || hierarchyBuilds != 1 || viewportBuilds != 1 ||
			viewportDockWidth < 300.0 || viewportDockWidth > 640.0 ||
			inspectorBuilds != 0 || consoleBuilds != 0 || model.activePanelId != "hierarchy")
			return false;
		if (!model.activate("inspector") || changes != 1)
			return false;
		workspaceRoot = uiContext.submit(workspace, new LayoutFrame(640.0, 480.0));
		if (workspaceRoot == null || inspectorBuilds != 1 || viewportBuilds != 1)
			return false;
		var dockedConsole = model.dock("console", "viewport", DockDropZone.Center);
		if (!dockedConsole ||
			!model.isOpen("console") || model.activePanelId != "console")
			return false;
		var snapshot = model.snapshot();
		workspaceRoot = uiContext.submit(workspace, new LayoutFrame(640.0, 480.0));
		if (workspaceRoot == null || consoleBuilds != 1)
			return false;
		var tabsNode:Null<RenderNode> = null;
		workspaceRoot.walk(function(node) {
			if (tabsNode == null && node.styleType == "tabs")
				tabsNode = node;
		});
		if (tabsNode == null)
			return false;
		var tabsBounds = tabsNode.globalBounds();
		var centerX = tabsBounds.x + tabsBounds.width * 0.5;
		var centerY = tabsBounds.y + tabsBounds.height * 0.5;
		if (!workspace.interaction.beginTabDrag("inspector", 11, centerX, centerY) ||
			!workspace.interaction.moveTabDrag("inspector", 11, centerX, centerY) ||
			workspace.interaction.preview == null)
			return false;
		// The drag preview must submit while the pointer is held, including when
		// the target panel's own root is a Text or Box render node.
		workspaceRoot = uiContext.submit(workspace, new LayoutFrame(640.0, 480.0));
		var sawDropPreview = false;
		if (workspaceRoot != null)
			workspaceRoot.walk(function(node) {
				if (node.styleType == "dock-drop-preview" &&
					node.layout.visualKind == LayoutVisualKind.Custom)
					sawDropPreview = true;
			});
		if (!sawDropPreview ||
			!workspace.interaction.endTabDrag("inspector", 11, centerX, centerY))
			return false;
		if (!model.restore(snapshot))
			return false;
		var snapshotJson = model.snapshotJson();
		if (snapshotJson == null || snapshotJson.length == 0 || !model.restoreJson(snapshotJson))
			return false;
		var storage = new SmokeDockStorage();
		DockWorkspaceStorage.save(model, storage, "editor");
		if (!DockWorkspaceStorage.restore(model, storage, "editor") || DockWorkspaceStorage.restore(model, storage, "missing"))
			return false;
		var persisted = new DockWorkspaceModel();
		persisted.register(new DockPanelDescriptor("known", "Known", false));
		persisted.register(new DockPanelDescriptor("removed", "Removed"));
		persisted.setDefaultLayout(DockNode.Tabs(["known", "removed"], "removed"));
		var persistedJson = persisted.snapshotJson();
		persisted.unregister("removed");
		if (!persisted.restoreJson(persistedJson) || persisted.isOpen("removed") ||
			!persisted.isOpen("known") || persisted.activePanelId != "known")
			return false;
		var fallback = new DockWorkspaceModel();
		fallback.register(new DockPanelDescriptor("fallback", "Fallback", false));
		fallback.setDefaultLayout(DockNode.Panel("fallback"));
		storage.save("broken", "not-json");
		if (DockWorkspaceStorage.restoreOrDefault(fallback, storage, "broken") || !fallback.isOpen("fallback") ||
			fallback.activePanelId != "fallback")
			return false;
		workspaceRoot = uiContext.submit(workspace, new LayoutFrame(640.0, 480.0));
		var inspectorTab:Null<RenderNode> = null;
		workspaceRoot.walk(function(node) {
			if (inspectorTab == null && node.styleType == "button" && node.styleKey == "inspector")
				inspectorTab = node;
		});
		if (inspectorTab == null)
			return false;
		var inspectorBounds = inspectorTab.globalBounds();
		var inspectorX = inspectorBounds.x + inspectorBounds.width * 0.5;
		var inspectorY = inspectorBounds.y + inspectorBounds.height * 0.5;
		uiContext.pointerDown(inspectorX, inspectorY, 0);
		uiContext.pointerMove(inspectorX + 12.0, inspectorY);
		uiContext.pointerUp(inspectorX + 12.0, inspectorY, 0);
		if (workspace.interaction.draggingPanelId != null || model.activePanelId != "inspector" ||
			!model.restore(snapshot))
			return false;
		if (!model.close("console") || model.isOpen("console") || !model.open("console", "viewport"))
			return false;
		if (!model.restore(snapshot) || !model.isOpen("console") || model.activePanelId != "console")
			return false;
		if (!model.setSplitRatio([], 0.6))
			return false;
		switch (model.root) {
			case DockNode.Split(_, ratio, _, _):
				if (ratio != 0.6)
					return false;
			default: return false;
		}
		if (!model.dock("inspector", "hierarchy", DockDropZone.Left) ||
			!model.isOpen("inspector"))
			return false;
		var commandRegistry = new CommandRegistry();
		DockWorkspaceCommands.install(model, commandRegistry, "workspace");
		var parameters = new CommandParameters();
		parameters.setString("panel", "console");
		var commandContext = new CommandContext(null, [], null, parameters, "dock-smoke");
		var closeResult = commandRegistry.executeContext("workspace.close", commandContext);
		if (!closeResult.succeeded || model.isOpen("console"))
			return false;
		var resetResult = commandRegistry.executeContext("workspace.reset", commandContext);
		if (!resetResult.succeeded || !model.isOpen("hierarchy") || !model.isOpen("viewport") ||
			model.isOpen("console") || !model.isOpen("inspector"))
			return false;
		if (!model.restore(snapshot) || !model.isOpen("console"))
			return false;
		var retainedInteraction:Null<DockWorkspaceInteraction> = null;
		for (index in 0...20) {
			var rebuilt = new DockWorkspace("editor-workspace", model, panelContents);
			uiContext.submit(rebuilt, new LayoutFrame(640.0, 480.0));
			if (index == 0) retainedInteraction = rebuilt.interaction;
			else if (rebuilt.interaction != retainedInteraction)
				return false;
		}
		if (model.listenerCount != 2 || retainedInteraction == null ||
			retainedInteraction.listenerCount != 1)
			return false;
		uiContext.submit(new Text("workspace unmounted"), new LayoutFrame(640.0, 480.0));
		return model.listenerCount == 1 && retainedInteraction.listenerCount == 0;
	}

	/** Covers the shared Haxe scene policy around transforms, clipping, order, and events. */
	static function nestedSceneSemanticsValid():Bool {
		var broadClip = new Rect(-1000.0, -1000.0, 3000.0, 3000.0);
		var root = new RenderNode(new WidgetId(910));
		var panel = new RenderNode(new WidgetId(911));
		var target = new RenderNode(new WidgetId(912));
		root.hitTestSelf = false;
		panel.hitTestSelf = false;
		root.add(panel);
		panel.add(target);
		var rootTransform = Transform2D.translation(100.0, 40.0);
		var panelTransform = rootTransform.multiply(Transform2D.rotation(0.21));
		var targetTransform = panelTransform.multiply(Transform2D.identity().skewed(0.08, -0.05));
		root.resolved = new ResolvedLayoutItem(910, 1, 0.0, 0.0, 400.0, 300.0,
			broadClip, new Rect(0.0, 0.0, 0.0, 0.0), rootTransform, 0.0);
		panel.resolved = new ResolvedLayoutItem(911, 1, 20.0, 30.0, 180.0, 120.0,
			broadClip, new Rect(0.0, 0.0, 0.0, 0.0), panelTransform, 0.0);
		target.resolved = new ResolvedLayoutItem(912, 1, 10.0, 15.0, 60.0, 40.0,
			broadClip, new Rect(0.0, 0.0, 0.0, 0.0), targetTransform, 0.0);
		var localPoint = new Point(8.0, 9.0);
		var globalPoint = target.localToGlobal(localPoint);
		var expectedRoot = root.globalToLocal(globalPoint);
		var expectedPanel = panel.globalToLocal(globalPoint);
		var order:Array<String> = [];
		var rootLocalX = 0.0;
		var panelLocalX = 0.0;
		var targetLocalX = 0.0;
		root.on(UiEventKind.PointerDown, function(event) {
			order.push("root-capture");
			rootLocalX = event.localX;
		}, "capture");
		panel.on(UiEventKind.PointerDown, function(event) {
			order.push("panel-capture");
			panelLocalX = event.localX;
		}, "capture");
		target.on(UiEventKind.PointerDown, function(event) {
			order.push("target");
			targetLocalX = event.localX;
		});
		panel.on(UiEventKind.PointerDown, function(event) {
			order.push("panel-bubble");
			if (!near(event.localX, expectedPanel.x))
				order.push("panel-coordinate-error");
		});
		root.on(UiEventKind.PointerDown, function(event) {
			order.push("root-bubble");
			if (!near(event.localX, expectedRoot.x))
				order.push("root-coordinate-error");
		});
		var dispatcher = new EventDispatcher(new FocusManager(), new InteractionStateStore());
		dispatcher.setRoot(root);
		dispatcher.pointerDown(globalPoint.x, globalPoint.y, 0);
		if (order.join(",") != "root-capture,panel-capture,target,panel-bubble,root-bubble" ||
			!near(rootLocalX, expectedRoot.x) || !near(panelLocalX, expectedPanel.x) ||
			!near(targetLocalX, localPoint.x) || HitTest.path(root, globalPoint.x, globalPoint.y).length != 3)
			return false;

		// An inverse-transformed child remains clipped in viewport space, even
		// when its own local bounds are reached by the pointer.
		var clippedGlobal = target.localToGlobal(new Point(8.0, 32.0));
		target.resolved = new ResolvedLayoutItem(912, 1, 10.0, 15.0, 60.0, 40.0,
			new Rect(globalPoint.x - 1.0, globalPoint.y - 1.0, 2.0, 2.0),
			new Rect(0.0, 0.0, 0.0, 0.0), targetTransform, 0.0);
		if (HitTest.path(root, clippedGlobal.x, clippedGlobal.y).length != 0)
			return false;

		var stack = new RenderNode(new WidgetId(920));
		stack.hitTestSelf = false;
		stack.resolved = new ResolvedLayoutItem(920, 1, 0.0, 0.0, 100.0, 100.0,
			broadClip, new Rect(0.0, 0.0, 0.0, 0.0), Transform2D.identity(), 0.0);
		var lower = new RenderNode(new WidgetId(921));
		var upper = new RenderNode(new WidgetId(922));
		var equalFirst = new RenderNode(new WidgetId(923));
		var equalSecond = new RenderNode(new WidgetId(924));
		var flowFirst = new RenderNode(new WidgetId(925));
		var flowSecond = new RenderNode(new WidgetId(926));
		for (child in [lower, upper, equalFirst, equalSecond, flowFirst, flowSecond]) {
			child.resolved = new ResolvedLayoutItem(child.id.value, 1, 0.0, 0.0, 100.0, 100.0,
				broadClip, new Rect(0.0, 0.0, 0.0, 0.0), Transform2D.identity(), 0.0);
			child.layout.style.positioning = LayoutPositioning.Absolute;
		}
		lower.layout.style.zIndex = 1;
		upper.layout.style.zIndex = 5;
		equalFirst.layout.style.zIndex = 7;
		equalSecond.layout.style.zIndex = 7;
		// Flow zIndex is intentionally ignored by the native renderer.
		flowFirst.layout.style.positioning = LayoutPositioning.Flow;
		flowFirst.layout.style.zIndex = 100;
		flowSecond.layout.style.positioning = LayoutPositioning.Flow;
		flowSecond.layout.style.zIndex = -100;
		stack.add(lower);
		stack.add(upper);
		stack.add(equalFirst);
		stack.add(equalSecond);
		var hitPath = HitTest.path(stack, 10.0, 10.0);
		if (hitPath.length != 2 || !hitPath[1].id.equals(equalSecond.id))
			return false;
		var flowStack = new RenderNode(new WidgetId(927));
		flowStack.hitTestSelf = false;
		flowStack.resolved = stack.resolved;
		flowStack.add(flowFirst);
		flowStack.add(flowSecond);
		hitPath = HitTest.path(flowStack, 10.0, 10.0);
		return hitPath.length == 2 && hitPath[1].id.equals(flowSecond.id);
	}

	static inline function near(left:Float, right:Float):Bool
		return Math.abs(left - right) < 0.00001;
}

private class SmokeListModel implements ListViewModel {
	final itemCount:Int;
	final builtRows:Array<Int>;
	public var extentCalls:Int;
	var modelRevision:Int;
	var extentRevisionValue:Int;
	var changedExtentIndex:Int;

	public function new(itemCount:Int, builtRows:Array<Int>) {
		this.itemCount = itemCount;
		this.builtRows = builtRows;
		extentCalls = 0;
		modelRevision = 1;
		extentRevisionValue = 1;
		changedExtentIndex = -1;
	}

	public function count():Int
		return itemCount;

	public function keyAt(index:Int):String
		return 'model-item:$index';

	public function estimatedExtent():Float
		return 24.0;

	public function extentIsUniform():Bool
		return false;

	public function extentAt(index:Int):Float {
		extentCalls++;
		return 20.0 + (index % 3) * 4.0 + (index == changedExtentIndex ? 4.0 : 0.0);
	}

	public function extentRevisionAt(index:Int):Int
		return index == changedExtentIndex ? extentRevisionValue : 1;

	public function totalExtent():Null<Float>
		return null;

	public function bumpExtent(index:Int):Void {
		changedExtentIndex = index;
		extentRevisionValue++;
		modelRevision++;
	}

	public function buildItem(index:Int):View {
		builtRows.push(index);
		return new Text('Model row $index');
	}

	public function revision():Int
		return modelRevision;

	public function offsetBefore(index:Int):Float {
		var result = 0.0;
		for (item in 0...index)
			result += 20.0 + (item % 3) * 4.0;
		return result;
	}
}

private class SmokeTreeModel implements TreeViewModel {
	final builtKeys:Array<String>;
	public var extentCalls:Int;
	public var childCalls:Int;

	public function new(builtKeys:Array<String>) {
		this.builtKeys = builtKeys;
		extentCalls = 0;
		childCalls = 0;
	}

	public function rootCount():Int
		return 100000;

	public function rootRange(start:Int, count:Int):Array<TreeRootMetadata> {
		var result:Array<TreeRootMetadata> = [];
		for (index in start...(start + count))
			result.push(new TreeRootMetadata('root:$index', index == 0));
		return result;
	}

	public function rootKeyAt(index:Int):String
		return 'root:$index';

	public function childCount(parentKey:String):Int
	{
		childCalls++;
		return parentKey == "root:0" ? 3 : 0;
	}

	public function childKeyAt(parentKey:String, index:Int):String
		return '$parentKey:child:$index';

	public function initiallyExpanded(key:String):Bool
		return key == "root:0";

	public function estimatedExtent():Float
		return 24.0;

	public function extentIsUniform():Bool
		return false;

	public function extentAt(key:String):Float
	{
		extentCalls++;
		return key.indexOf(":child:") >= 0 ? 28.0 : 24.0;
	}

	public function buildItem(key:String):View {
		builtKeys.push(key);
		return new Text(key);
	}

	public function revision():Int
		return 1;
}

private class SmokeVector {
	public final x:Float;
	public final y:Float;
	public final z:Float;

	public function new(x:Float, y:Float, z:Float) {
		this.x = x;
		this.y = y;
		this.z = z;
	}
}

private class SmokeViewportContent implements ViewportContent {
	final contentWidth:Float;
	final contentHeight:Float;

	public function new(width:Float, height:Float) {
		contentWidth = width;
		contentHeight = height;
	}

	public function width():Float
		return contentWidth;

	public function height():Float
		return contentHeight;

	public function revision():Int
		return 1;

	public function paint(canvas:Canvas, destination:Rect):Void
		canvas.fillRect(destination, Color.rgba(0.08, 0.12, 0.18, 1.0));
}

private class SmokeDockStorage implements DockWorkspacePersistence {
	var values:Map<String, String>;

	public function new()
		values = new Map();

	public function load(key:String):Null<String>
		return values.get(key);

	public function save(key:String, value:String):Void
		values.set(key, value);
}

private class SmokeVectorExtension implements PropertyEditorExtension {
	public function new() {}

	public function typeId():String
		return "vec3";

	public function same(first:Dynamic, second:Dynamic):Bool {
		var left:SmokeVector = cast first;
		var right:SmokeVector = cast second;
		return left != null && right != null && left.x == right.x && left.y == right.y &&
			left.z == right.z;
	}

	public function display(value:Dynamic):String {
		var vector:SmokeVector = cast value;
		return vector == null ? "" : Std.string(vector.x) + ", " + Std.string(vector.y) + ", " +
			Std.string(vector.z);
	}

	public function editableText(value:Dynamic):String {
		var vector:SmokeVector = cast value;
		return vector == null ? "" : Std.string(vector.x) + "," + Std.string(vector.y) + "," +
			Std.string(vector.z);
	}

	public function parse(text:String):Null<Dynamic> {
		var parts = StringTools.trim(text == null ? "" : text).split(",");
		if (parts.length != 3)
			return null;
		var x = Std.parseFloat(StringTools.trim(parts[0]));
		var y = Std.parseFloat(StringTools.trim(parts[1]));
		var z = Std.parseFloat(StringTools.trim(parts[2]));
		return !finite(x) || !finite(y) || !finite(z) ? null : new SmokeVector(x, y, z);
	}

	public function validate(context:CommandContext, descriptor:PropertyDescriptor,
		value:Dynamic):Null<String> {
		return value == null ? "A vec3 value is required" : null;
	}

	public function build(key:String, descriptor:PropertyDescriptor, value:PropertyValue,
		context:BuildContext, enabled:Bool, apply:PropertyValue->Void):View {
		var field = new TextField(key, editableTextValue(value), function(_) {}, null,
			descriptor.label);
		field.enabled = enabled;
		field.onSubmit = function(text) {
			var parsed = parse(text);
			if (parsed != null)
				apply(PropertyValue.Custom(typeId(), parsed));
		};
		return field;
	}

	function editableTextValue(value:PropertyValue):String {
		return switch (value) {
			case PropertyValue.Custom("vec3", data): editableText(data);
			default: "";
		};
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;
}

private class SmokeHostApplication implements UiApplication {
	public var disposeCalls(default, null):Int = 0;
	final throwOnDispose:Bool;
	final placeholder:Dynamic = {};

	public function new(throwOnDispose:Bool) this.throwOnDispose = throwOnDispose;
	public function context():UiContext return cast placeholder;
	public function submit(frame:LayoutFrame):RenderNode return cast placeholder;
	public function dispose():Void {
		disposeCalls++;
		if (throwOnDispose) throw "application dispose failure";
	}
}

/** Fixed sibling content shares the pane overlay, without becoming scroll content. */
private class ExternalScrollbarSmoke implements View {
	final controller:ScrollController;
	public function new(controller:ScrollController) this.controller = controller;
	public function build(context:BuildContext):RenderNode {
		return context.withScope(new haxeon.ui.core.Key("external-scrollbar-smoke"), function() {
			var style = new LayoutStyle(); style.width = LayoutAxis.fixed(240); style.height = LayoutAxis.fixed(80);
			style.direction = LayoutDirection.LeftToRight;
			var host = new RenderNode(context.id("host"), LayoutVisualKind.Box, style);
			var viewportStyle = new LayoutStyle(); viewportStyle.width = LayoutAxis.grow(); viewportStyle.height = LayoutAxis.grow();
			var contentStyle = new LayoutStyle(); contentStyle.width = LayoutAxis.stretch(); contentStyle.height = LayoutAxis.fixed(600);
			var viewport = new ScrollView("external-viewport", new Column("content", [], contentStyle), viewportStyle, ScrollAxis.Vertical, controller);
			viewport.scrollbarOverlayHost = host;
			host.add(viewport.build(context));
			var sideStyle = new LayoutStyle(); sideStyle.width = LayoutAxis.fixed(80); sideStyle.height = LayoutAxis.grow();
			host.add(new RenderNode(context.id("fixed-side"), LayoutVisualKind.Box, sideStyle));
			return host;
		});
	}
}

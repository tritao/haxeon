package haxeon.ui.widgets.text;
import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.TextLayout.TextRangeRect;

import haxeon.ui.TextWrap;

import haxeon.ui.widgets.controls.ComboBox;

import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.platform.NativeKitEventValue.NativeKitTextEdit;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.TextStyle;
import haxeon.ui.TextColorRange;
import haxeon.ui.Transform2D;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.ResolvedTextStyle;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.State;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.core.View;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleStateUtil;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleSource;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityActionData;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.AccessibilityState;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.theme.TextRole;
import nativekit.editorkit.TextDocument;

/** Text editor composed from a Haxe box and NativeUI text primitive. */
class TextField implements View {
	public final key:String;
	public var value:String;
	public var label:Null<String>;
	/** Muted visual hint shown only while the editor is empty. */
	public var placeholder:Null<String>;
	public final multiline:Bool;
	public final style:LayoutStyle;
	public final textStyle:Null<TextStyle>;
	public final textColor:Null<Color>;
	/** Sorted, disjoint absolute codepoint foreground ranges for a visible chunk. */
	public var colorRangeProvider:Null<(Int, Int)->Array<TextColorRange>>;
	/** Backgrounds and underlines in absolute document codepoint coordinates. */
	public var decorationProvider:Null<(Int, Int)->Array<TextDecoration>>;
	/** Increment when state captured by presentation providers changes. */
	public var presentationRevision:Int = 0;
	/** Optional controlled selection, queried on rebuild after shared-document synchronization. */
	public var selectionProvider:Null<Void->TextSelection>;
	/** Reports widget selection after edit callbacks have synchronized a caller-owned document. */
	public var onSelectionChange:Null<TextSelection->Void>;
	/** Additional owner-controlled selections; the primary stays in selectionProvider. */
	public var additionalSelectionProvider:Null<Void->Array<TextSelection>>;
	/** Handles navigation of all selections when additional carets are present. */
	public var onNavigationIntent:Null<(TextNavigationIntent, TextEditorLayout)->Bool>;
	/** Return true after applying an operation; the live layout supplies shaped word boundaries. */
	/** True when an application document owns undo/redo. */
	public var historyManagedExternally:Bool = false;
	/** Optional external viewport scroll; delta uses application layout coordinates. */
	public var onSelectionDragScroll:Null<Float->Bool>;
	public var onEditIntent:Null<(TextEditIntent, TextEditorLayout)->Bool>;
	/** Optional aggregate selected text for clipboard copy/cut. */
	public var selectionTextProvider:Null<Void->Null<String>>;
	/** Typed selector classes used by composite fields such as ComboBox. */
	public var classes:Array<String>;
	public var enabled:Bool;
	/** Selectable and copyable but not editable; multiline fields also scroll with the wheel. */
	public var readOnly:Bool;
	/** With readOnly, keeps the newest text in view until the user scrolls away from the end. */
	public var followTail:Bool;
	public var onChange:Null<String->Void>;
	/** Applied edit notifications for a caller-owned EditorKit document. */
	public var onEdit:Null<EditTransaction->Void>;
	/** Optional mutable EditorKit model shared with the persistent editor state. */
	public var document:Null<TextDocument>;
	public var onSubmit:Null<String->Void>;
	public var onDiagnostics:Null<TextEditorDiagnostics->Void>;
	/** Current logical-screen caret bounds after layout, or null when clipped out. */
	public var onCaretRect:Null<Null<Rect>->Void>;
	/** Borrowed retained text geometry after layout, for aligned companion views. */
	public var onLayoutResolved:Null<TextEditorLayout->ResolvedLayoutItem->Void>;
	/** Semantic role override used by composite editable controls. */
	public var semanticRole:AccessibilityRole;
	/** Semantic action capabilities override used by composite editable controls. */
	public var semanticActions:Int;

	public function new(key:String, value:String = "", ?onChange:String->Void,
			?style:LayoutStyle, ?label:String, ?textStyle:TextStyle, ?textColor:Color,
			multiline:Bool = false, ?document:TextDocument,
			?onEdit:EditTransaction->Void) {
		if (key == null || key.length == 0)
			throw "Text fields require a stable key";
		if (onEdit != null && document == null)
			throw "Transaction callbacks require a shared EditorKit document";
		this.key = key;
		this.value = value == null ? "" : value;
		this.onChange = onChange;
		this.onEdit = onEdit;
		this.document = document;
		this.onSubmit = null;
		this.onCaretRect = null;
		this.onLayoutResolved = null;
		this.colorRangeProvider = null;
		this.decorationProvider = null;
		this.selectionProvider = null;
		this.onSelectionChange = null;
		this.additionalSelectionProvider = null;
		this.onNavigationIntent = null;
		this.onEditIntent = null;
		this.selectionTextProvider = null;
		this.label = label;
		this.placeholder = null;
		this.multiline = multiline;
		this.style = style == null ? defaultStyle(multiline) : style.copy();
		this.textStyle = textStyle == null ? null :
			new TextStyle(textStyle.fontSize, textStyle.font, textStyle.letterSpacing);
		this.textColor = textColor;
		classes = [];
		enabled = true;
		readOnly = false;
		followTail = false;
		onDiagnostics = null;
		semanticRole = AccessibilityRole.TextField;
		semanticActions = AccessibilityAction.SetValue | AccessibilityAction.SetSelection;
	}

	/** Creates a field backed by a shared document and edit transaction stream. */
	public static function withDocument(key:String, document:TextDocument,
			?onEdit:EditTransaction->Void, ?style:LayoutStyle, ?label:String,
			?textStyle:TextStyle, ?textColor:Color, multiline:Bool = false):TextField
		return new TextField(key, "", null, style, label, textStyle, textColor,
			multiline, document, onEdit);

	public function build(context:BuildContext):RenderNode {
		return context.withScope(new Key(key), function() {
			var id = context.id("field");
			// The field rebuilds only itself when its own state changes (typing, selection, caret), so the panel around it stays cached.
			return context.selfUpdating(id, function() return buildField(context, id));
		});
	}

	function buildField(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
			var resolved = context.resolveTextRole(TextRole.Body,
				TextStyleOverride.fromTextStyle(textStyle));
			if (textColor != null)
				resolved = resolved.withTextColor(textColor);
			var paragraph = new ParagraphStyle(resolved.paragraphStyle.wrap,
				resolved.paragraphStyle.alignment, resolved.paragraphStyle.lineHeight,
				resolved.paragraphStyle.direction);
			paragraph.wrap = multiline ? TextWrap.WordCharacter : TextWrap.None;
			resolved = new ResolvedTextStyle(resolved.textStyle, paragraph, resolved.textColor);
			var stored:State<TextEditorState> = acquireState(context, id, value, resolved, document);
			var editor:TextEditorState = stored.value;
			// Quiet update plus a patch request: only this field rebuilds. Falls back to a full state update if it is not self-updating.
			var refresh = function() {
				stored.updateQuietly(editor);
				if (!context.requestPatch(id))
					stored.update(editor);
			};
			editor.configureTail(followTail && readOnly);
			var documentChanged = document != null
				? editor.syncDocument(document)
				: editor.syncExternal(value);
			if (documentChanged) {
				editor.resetCaretBlink(Sys.time());
				if (editor.tailFollowing)
					editor.scrollToEnd();
			}
			if (selectionProvider != null)
				editor.setAnchoredSelection(selectionProvider());
			var additionalSelections = additionalSelectionProvider == null ? [] : additionalSelectionProvider();
			var hasAdditionalCaret = false;
			for (selection in additionalSelections) {
				if (selection.anchor == selection.focus) hasAdditionalCaret = true;
				if (selection.anchor > editor.documentLength() || selection.focus > editor.documentLength())
					throw "Additional selection is outside the document";
			}
			editor.updateStyle(resolved.textStyle, resolved.paragraphStyle);
			editor.configurePresentation(colorRangeProvider, decorationProvider, presentationRevision);

			var flags = context.interactionStates.get(id);
			flags = StyleStateUtil.withState(flags, StyleState.Disabled, !enabled);
			var computed = context.styleResolver.resolve(
				new StyleTarget("text-field", key, key, classes, ["text-field"], flags),
				context.inheritedStyle, context.theme.styles, context.styleSheet, style, context.environment);
			if (textColor != null)
				computed.set(StyleProperty.TextColor, textColor,
					new StyleSource("local", "text-field", -1, "local"));
			var node = new RenderNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
			node.setStyleIdentity("text-field", key, key, classes, ["text-field"]);
			node.states = flags;
			node.computedStyle = computed;
			node.focusable = enabled;
			node.enabled = enabled;
			var semantics = new Semantics(semanticRole,
				label == null ? key : label, null, editor.documentLength());
			semantics.setValueProvider(function() return editor.text, editor.documentLength());
			semantics.actions = readOnly ? semanticActions & ~AccessibilityAction.SetValue : semanticActions;
			if (readOnly)
				semantics.states |= AccessibilityState.ReadOnly;
			semantics.textStart = 0;
			semantics.selectionStart = editor.selectionStart;
			semantics.selectionEnd = editor.selectionEnd;
			if (!enabled)
				semantics.states |= AccessibilityState.Disabled;
			if (editor.focused)
				semantics.states |= AccessibilityState.Focused;
			if (multiline)
				semantics.states |= AccessibilityState.Multiline;
			node.semantics = semantics;

			var textNodeStyle = new LayoutStyle();
			textNodeStyle.width = LayoutAxis.grow();
			textNodeStyle.height = LayoutAxis.grow();
			textNodeStyle.zIndex = 1;
			var editorContentStyle = new LayoutStyle();
			editorContentStyle.width = LayoutAxis.grow();
			editorContentStyle.height = LayoutAxis.grow();
			editorContentStyle.clipHorizontal = true;
			editorContentStyle.clipVertical = multiline;
			var editorContent = new RenderNode(context.id("editor-content"),
				LayoutVisualKind.Box, editorContentStyle);
			if (decorationProvider != null) {
				var backgroundStyle = new LayoutStyle();
				backgroundStyle.width = LayoutAxis.grow();
				backgroundStyle.height = LayoutAxis.grow();
				backgroundStyle.positioning = LayoutPositioning.Absolute;
				backgroundStyle.zIndex = 0;
				var backgroundNode = new RenderNode(context.id("editor-background"),
					LayoutVisualKind.Custom, backgroundStyle);
				backgroundNode.hitTestSelf = false;
				backgroundNode.onPaint(function(canvas, geometry) {
					if (!editor.isDisposed()) {
						var visible = geometry.visibleLocalBounds();
						canvas.translate(0.0, -editor.scrollOffsetY);
						editor.layout.paintDecorations(canvas, true,
							editor.scrollOffsetY + visible.y,
							editor.scrollOffsetY + visible.y + visible.height,
							visible.x, visible.x + visible.width);
					}
				});
				editorContent.add(backgroundNode);
			}
			// Unfocused, unselected fields need only their text node. State changes
			// invalidate the frame before selection or caret decoration is painted.
			if (editor.selectionStart != editor.selectionEnd || additionalSelections.length > 0) {
				var selectionStyle = new LayoutStyle();
				selectionStyle.width = LayoutAxis.grow();
				selectionStyle.height = LayoutAxis.grow();
				selectionStyle.positioning = LayoutPositioning.Absolute;
				selectionStyle.zIndex = 0;
				var selectionNode = new RenderNode(context.id("editor-selection"),
					LayoutVisualKind.Custom, selectionStyle);
				selectionNode.hitTestSelf = false;
				selectionNode.onPaint(function(canvas, _) {
					if (!editor.isDisposed())
						paintSelection(canvas, editor, context.textInput.isOwner(id), context.theme, additionalSelections);
				});
				editorContent.add(selectionNode);
			}
			var showsPlaceholder = editor.documentLength() == 0 && placeholder != null &&
				placeholder.length > 0;
			// Single-line fields use the text node so their full value and theme
			// foreground update together as the editor content changes.
			var useTextNode = showsPlaceholder || (!multiline && colorRangeProvider == null && decorationProvider == null);
			var textNode = new RenderNode(context.id("text"),
				useTextNode ? LayoutVisualKind.Text : LayoutVisualKind.Custom, textNodeStyle);
			if (showsPlaceholder)
				textNode.layout.text = placeholder;
			else if (useTextNode)
				textNode.layout.text = editor.layoutText();
			else {
				// Clay orders absolute paint layers independently of flow content.
				// Keep glyphs above decoration/selection layers, while a separate
				// measurement-only node supplies their shared intrinsic size.
				textNodeStyle.positioning = LayoutPositioning.Absolute;
				textNode.layout.intrinsicContent = editor.renderContent;
			}
			var textNodeTextStyle = new TextStyle(editor.textStyle.fontSize,
				editor.textStyle.font, editor.textStyle.letterSpacing);
			var fontSource = computed.source(StyleProperty.FontSize);
			var letterSource = computed.source(StyleProperty.LetterSpacing);
			if (textStyle == null && fontSource != null && fontSource.layer != "framework")
				textNodeTextStyle.fontSize = computed.get(StyleProperty.FontSize);
			if (textStyle == null && letterSource != null && letterSource.layer != "framework")
				textNodeTextStyle.letterSpacing = computed.get(StyleProperty.LetterSpacing);
			var colorSource = computed.source(StyleProperty.TextColor);
			var textNodeColor = showsPlaceholder ? context.theme.mutedText :
				(colorSource != null && colorSource.layer != "framework"
					? computed.get(StyleProperty.TextColor) : resolved.textColor);
			textNode.applyTextStyle(new ResolvedTextStyle(textNodeTextStyle,
				editor.paragraphStyle, textNodeColor));
			if (!showsPlaceholder) {
				editor.updateStyle(textNodeTextStyle, editor.paragraphStyle);
				editor.setRenderColor(textNodeColor);
			}
			editorContent.add(textNode);
			if (!useTextNode) {
				var measureStyle = new LayoutStyle();
				measureStyle.width = LayoutAxis.grow();
				measureStyle.height = LayoutAxis.grow();
				var measureNode = new RenderNode(context.id("editor-measure"), LayoutVisualKind.Custom, measureStyle);
				measureNode.hitTestSelf = false;
				measureNode.layout.intrinsicContent = editor.renderMeasurement;
				editorContent.add(measureNode);
			}
			if (editor.focused) {
				var paintStyle = new LayoutStyle();
				paintStyle.width = LayoutAxis.grow();
				paintStyle.height = LayoutAxis.grow();
				paintStyle.positioning = LayoutPositioning.Absolute;
				paintStyle.zIndex = 2;
				var paintNode = new RenderNode(context.id("editor-paint"),
					LayoutVisualKind.Custom, paintStyle);
				paintNode.hitTestSelf = false;
				paintNode.onPaint(function(canvas, _) {
					if (!editor.isDisposed()) {
						var now = Sys.time();
						var active = context.textInput.isOwner(id);
						if (active && !readOnly && (editor.selectionStart == editor.selectionEnd || hasAdditionalCaret))
							context.textInput.requestCaretFrameAt(editor.nextCaretBlinkTime(now));
						paintEditorDecorations(canvas, editor, active, context.theme, now, !readOnly, additionalSelections);
					}
				});
				editorContent.add(paintNode);
			}
			node.add(editorContent);

			var refreshState = function() {
				if (document == null || onChange != null)
					value = editor.layoutText();
				semantics.setValueProvider(function() return editor.text, editor.documentLength());
				semantics.selectionStart = editor.selectionStart;
				semantics.selectionEnd = editor.selectionEnd;
				refresh();
				if (multiline && editorContent.resolved != null &&
					editor.ensureCaretVisible(editorContent.resolved.height))
					refresh();
			};
			var publishSelection = function() {
				var handler = onSelectionChange;
				if (handler != null)
					handler(new TextSelection(editor.selectionAnchor, editor.selectionFocus,
						editor.selectionAnchorAffinity, editor.selectionFocusAffinity));
			};
			var updateState = function() {
				publishSelection();
				refreshState();
			};
			var delegateEdit = function(intent:TextEditIntent):Bool {
				var handler = onEditIntent;
				if (handler == null || !handler(intent, editor.layout)) return false;
				if (document != null) editor.syncDocument(document);
				else editor.syncExternal(value);
				if (selectionProvider != null) editor.setAnchoredSelection(selectionProvider());
				editor.resetCaretBlink(Sys.time());
				updateState();
				return true;
			};
			var copyCurrentSelection = function():Bool {
				if (selectionTextProvider != null) {
					var selectedText = selectionTextProvider();
					if (selectedText == null) return false;
					context.clipboard.writeText(selectedText);
				} else {
					if (editor.selectionStart == editor.selectionEnd) return false;
					copySelection(context.clipboard, editor);
				}
				return true;
			};
			var publishTextChange = function(previousRevision:Int) {
				if (document == null || onChange != null)
					value = editor.layoutText();
				if (editor.documentRevision() != previousRevision &&
					editor.lastEditTransaction != null && onEdit != null)
					onEdit(editor.lastEditTransaction);
				if (editor.documentRevision() != previousRevision && onChange != null)
					onChange(value);
				publishSelection();
				refreshState();
			};
			var publishDiagnostics = function(caretRect:Null<Rect>) {
				if (onDiagnostics == null)
					return;
				var compositionText = editor.compositionStart >= 0 &&
					editor.compositionEnd >= editor.compositionStart
					? editor.documentOffsets().sliceCodepoints(editor.compositionStart,
						editor.compositionEnd) : "";
				onDiagnostics(new TextEditorDiagnostics(key, label == null ? key : label,
					editor.focused, editor.selectionStart, editor.selectionEnd,
					editor.selectionFocus, editor.compositionStart, editor.compositionEnd,
					compositionText, caretRect, context.textInput.platformSupported,
					context.textInput.platformActive));
			};
			var syncCursor = function(geometry:ResolvedLayoutItem) {
				var caret = editor.layout.caret(editor.focusPosition());
				var topX = geometry.x + caret.x + caret.ascender * caret.slope;
				var topY = geometry.y + caret.y + caret.ascender - editor.scrollOffsetY;
				var bottomX = geometry.x + caret.x + caret.descender * caret.slope;
				var bottomY = geometry.y + caret.y + caret.descender - editor.scrollOffsetY;
				var transform:Transform2D = cast geometry.transform;
				var screenTopX = transform.a * topX + transform.c * topY + transform.tx;
				var screenTopY = transform.b * topX + transform.d * topY + transform.ty;
				var screenBottomX = transform.a * bottomX + transform.c * bottomY + transform.tx;
				var screenBottomY = transform.b * bottomX + transform.d * bottomY + transform.ty;
				var caretRect = new Rect(Math.min(screenTopX, screenBottomX), Math.min(screenTopY, screenBottomY),
					Math.max(1.0, absolute(screenBottomX - screenTopX)),
					Math.max(1.0, absolute(screenBottomY - screenTopY)));
				var caretHandler = onCaretRect;
				if (caretHandler != null) {
					var clip = geometry.clipBounds;
					var visible = geometry.visible && caretRect.x < clip.x + clip.width &&
						caretRect.x + caretRect.width > clip.x && caretRect.y < clip.y + clip.height &&
						caretRect.y + caretRect.height > clip.y;
					caretHandler(visible ? caretRect : null);
				}
				publishDiagnostics(caretRect);
				if (!editor.focused || !context.textInput.isOwner(id) || context.platformSurface == null ||
					context.platformSurface.isDisposed())
					return;
				var viewportHeight = editorContent.resolved == null ? geometry.height :
					editorContent.resolved.height;
				var visibleTop = editor.scrollOffsetY;
				var visibleBottom = visibleTop + viewportHeight;
				var selectionGeometry:Array<TextRangeRect> = [];
				if (editor.selectionStart != editor.selectionEnd)
					for (rect in editor.layout.selectionRangeRects(editor.anchorPosition(),
						editor.focusPosition(), visibleTop, visibleBottom))
						selectionGeometry.push(transformTextRangeRect(rect, geometry, transform,
							editor.scrollOffsetY));
				var compositionGeometry:Array<TextRangeRect> = [];
				for (rect in editor.compositionRangeRects(visibleTop, visibleBottom))
					compositionGeometry.push(transformTextRangeRect(rect, geometry, transform,
						editor.scrollOffsetY));
				context.textInput.update(editor.surroundingText(2048, 2048), editor.documentLength(),
					editor.selectionStart, editor.selectionEnd, editor.compositionStart,
					editor.compositionEnd, 0,
					multiline ? 1 : 0,
					caretRect, selectionGeometry, compositionGeometry);
			};
			editorContent.onResolved(function(geometry) {
				if (multiline) {
					editor.updateLayout(geometry.width);
					if (readOnly) {
						// A read-only view keeps what the user scrolled to instead of chasing the caret.
						editor.setViewportHeight(geometry.height);
						if (editor.tailFollowing && editor.scrollToEnd())
							refresh();
					} else if (editor.ensureCaretVisible(geometry.height))
						refresh();
				}
			});
			textNode.onResolved(function(geometry) {
				editor.updateLayout(geometry.width);
				if (onLayoutResolved != null) onLayoutResolved(editor.layout, geometry);
				if (multiline && !readOnly && editorContent.resolved != null &&
					editor.ensureCaretVisible(editorContent.resolved.height))
					refresh();
				syncCursor(geometry);
			});
			node.on(UiEventKind.Focus, function(_) {
				if (!enabled)
					return;
				editor.focused = true;
				editor.resetCaretBlink(Sys.time());
				semantics.states |= AccessibilityState.Focused;
				refresh();
				context.textInput.activate(id);
				if (textNode.resolved != null)
					syncCursor(cast textNode.resolved);
				else
					publishDiagnostics(null);
			});
			var blur = function(event:UiEvent) {
				if (!editor.focused && !editor.draggingSelection)
					return;
				editor.breakHistoryGroup();
				editor.focused = false;
				editor.draggingSelection = false;
				editor.cancelPointerClick();
				semantics.states &= ~AccessibilityState.Focused;
				refresh();
				context.textInput.deactivate(id);
				publishDiagnostics(null);
			};
			node.on(UiEventKind.Blur, blur);
			node.on(UiEventKind.FocusLost, blur);

			var drag = context.resourceState(context.id("selection-drag"),
				function() return new SelectionDragController(), function(value) value.dispose()).value;
			var extendDrag = function(x:Float, y:Float):Void {
				var geometry = textNode.resolved;
				if (geometry == null) return;
				var clip = geometry.clipBounds;
				var clampedY = Math.max(clip.y, Math.min(clip.y + clip.height, y));
				var point = geometry.viewportToLayout(x, clampedY);
				var position = editor.hitTest(point.x - geometry.x, point.y - geometry.y + editor.scrollOffsetY);
				if (editor.extendPointerSelection(position)) {
					editor.resetCaretBlink(Sys.time());
					updateState();
				}
			};
			drag.configure(context.animations, editor, function() return textNode.resolved, extendDrag, function(delta) {
				var changed = onSelectionDragScroll == null ? editor.scrollBy(delta) : onSelectionDragScroll(delta);
				if (changed) refresh();
				return changed;
			});
			node.on(UiEventKind.PointerDown, function(event) {
				if (!enabled || event.button != 0 || textNode.resolved == null)
					return;
				event.capturePointer();
				var geometry:ResolvedLayoutItem = cast textNode.resolved;
				var point = geometry.viewportToLayout(event.x, event.y);
				var position = editor.hitTest(point.x - geometry.x,
					point.y - geometry.y + editor.scrollOffsetY);
				editor.resetCaretBlink(Sys.time());
				var extend = (event.modifiers & UiModifier.Shift) != 0;
				if (extend)
					editor.cancelPointerClick();
				var clickCount = extend ? 1 : editor.registerPointerClick(position,
					context.gestures.timeSeconds(), event.x, event.y);
				var changed = editor.beginPointerSelection(position, clickCount, extend);
				if (changed)
					updateState();
				editor.draggingSelection = true;
				event.preventDefault();
			});
			node.on(UiEventKind.PointerMove, function(event) {
				if (!enabled || !editor.draggingSelection || textNode.resolved == null)
					return;
				editor.cancelPointerClickIfMoved(event.x, event.y);
				extendDrag(event.x, event.y);
				drag.update(event.x, event.y);
			});
			node.on(UiEventKind.PointerUp, function(event) {
				drag.stop();
				editor.completePointerClick(event.x, event.y);
				editor.draggingSelection = false;
			});
			node.on(UiEventKind.PointerCancel, function(_) {
				drag.stop();
				editor.cancelPointerClick();
				editor.draggingSelection = false;
			});

			editor.configureHistory(!historyManagedExternally);
			var handleKey = function(event:UiEvent) {
				if (!enabled)
					return;
				// Ctrl+Alt arrows belong to application navigation, including its
				// Shift variant. Leave them unconsumed for the command route.
				if ((event.modifiers & (UiModifier.Control | UiModifier.Alt)) ==
					(UiModifier.Control | UiModifier.Alt) &&
					(event.key == UiKey.Left || event.key == UiKey.Right ||
					 event.key == UiKey.Up || event.key == UiKey.Down)) return;
				var extend = (event.modifiers & UiModifier.Shift) != 0;
				var command = (event.modifiers & (UiModifier.Control | UiModifier.Super)) != 0;
				if (command && (event.key == UiKey.Z || event.key == UiKey.Y)) {
					if (historyManagedExternally) return;
					var previousRevision = editor.documentRevision();
					var changed = !readOnly && (event.key == UiKey.Y || extend ? editor.redo() : editor.undo());
					if (changed) publishTextChange(previousRevision);
					editor.resetCaretBlink(Sys.time());
					event.preventDefault();
					return;
				}
				var macWordNavigation = #if (mac || ios)
					(event.modifiers & UiModifier.Alt) != 0 &&
					(event.modifiers & UiModifier.Control) == 0;
				#else
					false;
				#end
				var wordNavigation = #if (mac || ios)
					macWordNavigation;
				#else
					(event.modifiers & UiModifier.Control) != 0;
				#end
				if (additionalSelections.length > 0 && onNavigationIntent != null) {
					var navigation:Null<TextNavigationIntent> = switch (event.key) {
						case UiKey.Left: #if (mac || ios) (event.modifiers & UiModifier.Super) != 0 ? LineBoundary(false, extend) : #end wordNavigation ? Word(-1, extend, macWordNavigation) : Character(-1, extend);
						case UiKey.Right: #if (mac || ios) (event.modifiers & UiModifier.Super) != 0 ? LineBoundary(true, extend) : #end wordNavigation ? Word(1, extend, macWordNavigation) : Character(1, extend);
						case UiKey.Up: wordNavigation ? Paragraph(-1, extend, macWordNavigation) :
							multiline ? VisualLine(-1, extend) : null;
						case UiKey.Down: wordNavigation ? Paragraph(1, extend, macWordNavigation) :
							multiline ? VisualLine(1, extend) : null;
						case UiKey.Home: LineBoundary(false, extend);
						case UiKey.End: LineBoundary(true, extend);
						case _: null;
					};
					#if (mac || ios)
					if ((event.modifiers & UiModifier.Super) != 0 && event.key == UiKey.Up)
						navigation = DocumentBoundary(false, extend);
					else if ((event.modifiers & UiModifier.Super) != 0 && event.key == UiKey.Down)
						navigation = DocumentBoundary(true, extend);
					#end
					if (command && (event.key == UiKey.Home || event.key == UiKey.End))
						navigation = DocumentBoundary(event.key == UiKey.End, extend);
					if (navigation != null && onNavigationIntent(navigation, editor.layout)) {
						refresh();
						editor.resetCaretBlink(Sys.time());
						event.preventDefault();
						return;
					}
				}
				if (!readOnly) {
					var consumed = event.key == UiKey.Backspace ? delegateEdit(wordNavigation ? DeleteWordBackward(macWordNavigation) : DeleteBackward) :
						event.key == UiKey.Delete ? delegateEdit(wordNavigation ? DeleteWordForward(macWordNavigation) : DeleteForward) :
						event.key == UiKey.Enter && multiline ? delegateEdit(Insert("\n")) : false;
					if (consumed) { event.preventDefault(); return; }
				}
				var handled = true;
				var changed = false;
				var textEdited = false;
				var previousRevision = editor.documentRevision();
				if (command && event.key == UiKey.A)
					changed = editor.selectAll();
				else if (command && event.key == UiKey.C)
					copyCurrentSelection();
				else if (command && event.key == UiKey.X) {
					copyCurrentSelection();
					if (!readOnly && delegateEdit(Insert(""))) { event.preventDefault(); return; }
					if (!readOnly) {
						changed = editor.replace(editor.selectionStart, editor.selectionEnd, "");
						textEdited = true;
					}
				} else if (command && event.key == UiKey.V) {
					if (readOnly)
						handled = false;
					else
						context.clipboard.readText(function(pasted) {
							if (editor.isDisposed() || !editor.focused)
								return;
							if (delegateEdit(Paste(pasted))) return;
							var beforePaste = editor.documentRevision();
							if (editor.insert(pasted, TextEditorHistoryKind.Paste)) {
								editor.resetCaretBlink(Sys.time());
								publishTextChange(beforePaste);
							}
						});
				}
				#if (mac || ios)
				else if ((event.modifiers & UiModifier.Super) != 0 && event.key == UiKey.Left)
					changed = editor.moveCaretToLineBoundary(false, extend);
				else if ((event.modifiers & UiModifier.Super) != 0 && event.key == UiKey.Right)
					changed = editor.moveCaretToLineBoundary(true, extend);
				#end
				else if (wordNavigation && event.key == UiKey.Left)
					changed = editor.moveCaretByWord(-1, extend, macWordNavigation);
				else if (wordNavigation && event.key == UiKey.Right)
					changed = editor.moveCaretByWord(1, extend, macWordNavigation);
				else if (wordNavigation && event.key == UiKey.Up)
					changed = editor.moveCaretByParagraph(-1, extend, macWordNavigation);
				else if (wordNavigation && event.key == UiKey.Down)
					changed = editor.moveCaretByParagraph(1, extend, macWordNavigation);
				else if (multiline && event.key == UiKey.Up)
					changed = editor.moveCaretVertically(-1, extend);
				else if (multiline && event.key == UiKey.Down)
					changed = editor.moveCaretVertically(1, extend);
				#if (mac || ios)
				else if ((event.modifiers & UiModifier.Super) != 0 && event.key == UiKey.Up)
					changed = editor.placeCaret(0, extend);
				else if ((event.modifiers & UiModifier.Super) != 0 && event.key == UiKey.Down)
					changed = editor.placeCaret(editor.documentLength(), extend);
				#end
				else if (event.key == UiKey.Left)
					changed = editor.moveCaret(-1, extend);
				else if (event.key == UiKey.Right)
					changed = editor.moveCaret(1, extend);
				else if (event.key == UiKey.Home)
					changed = multiline && !command ? editor.moveCaretToLineBoundary(false, extend) :
						editor.placeCaret(0, extend);
				else if (event.key == UiKey.End)
					changed = multiline && !command ? editor.moveCaretToLineBoundary(true, extend) :
						editor.placeCaret(editor.documentLength(), extend);
				else if (event.key == UiKey.Backspace) {
					if (readOnly)
						handled = false;
					else {
						changed = wordNavigation ? editor.deleteWord(-1, macWordNavigation) : editor.deleteBackward();
						textEdited = true;
					}
				} else if (event.key == UiKey.Delete) {
					if (readOnly)
						handled = false;
					else {
						changed = wordNavigation ? editor.deleteWord(1, macWordNavigation) : editor.deleteForward();
						textEdited = true;
					}
				} else if (event.key == UiKey.Enter) {
					if (multiline) {
						if (readOnly)
							handled = false;
						else {
							changed = editor.insert("\n");
							textEdited = true;
						}
					} else if (onSubmit != null)
						onSubmit(editor.layoutText());
				} else
					handled = false;
				if (changed) {
					if (textEdited)
						publishTextChange(previousRevision);
					else
						updateState();
				}
				if (handled) {
					editor.resetCaretBlink(Sys.time());
					event.preventDefault();
				}
			};
			node.on(UiEventKind.KeyDown, handleKey);
			node.on(UiEventKind.KeyRepeat, handleKey);

			if (multiline && readOnly)
				node.on(UiEventKind.Scroll, function(event) {
					if (scrollReadOnly(editor, event.deltaY)) {
						refresh();
						event.stopPropagation();
					}
				});

			node.on(UiEventKind.TextInput, function(event) {
				if (enabled && !readOnly && delegateEdit(Insert(event.text))) return;
				var previousRevision = editor.documentRevision();
				if (enabled && !readOnly && editor.insert(event.text)) {
					editor.resetCaretBlink(Sys.time());
					publishTextChange(previousRevision);
				}
			});
			node.on(UiEventKind.TextEdit, function(event) {
				if (!enabled || readOnly || event.data == null)
					return;
				var edit:NativeKitTextEdit = cast event.data;
				var previousRevision = editor.documentRevision();
				if (editor.applyTextEdit(edit)) {
					editor.resetCaretBlink(Sys.time());
					publishTextChange(previousRevision);
				}
			});
			node.on(UiEventKind.AccessibilitySetValue, function(event) {
				var previousRevision = editor.documentRevision();
				if (enabled && !readOnly && editor.replace(0, editor.documentLength(), event.text)) {
					editor.resetCaretBlink(Sys.time());
					publishTextChange(previousRevision);
				}
			});
			node.on(UiEventKind.AccessibilitySetSelection, function(event) {
				if (!enabled || event.data == null)
					return;
				var request:AccessibilityActionData = cast event.data;
				if (editor.setSelection(request.selectionStart, request.selectionEnd)) {
					editor.resetCaretBlink(Sys.time());
					updateState();
				}
			});
			return node;
	}

	/** Applies a wheel delta and re-pins to the tail when the view reaches the end again. */
	static function scrollReadOnly(editor:TextEditorState, deltaY:Float):Bool {
		var changed = editor.scrollBy(deltaY);
		if (changed)
			editor.tailFollowing = editor.isScrolledToEnd();
		return changed;
	}

	static function acquireState(context:BuildContext, id:haxeon.ui.core.WidgetId,
			value:String, resolved:ResolvedTextStyle,
			document:Null<TextDocument>):State<TextEditorState> {
		if (context.fonts == null || context.fonts.isDisposed())
			throw "Text fields require fonts on their build context";
		var fonts = context.fonts;
		return context.resourceState(id,
			function() {
				return new TextEditorState(cast fonts, value, resolved.textStyle,
				resolved.paragraphStyle, document);
			},
			function(editor:TextEditorState) { editor.dispose(); });
	}

	static function copySelection(clipboard:haxeon.ui.core.ClipboardService,
			editor:TextEditorState):Void {
		if (editor.selectionStart != editor.selectionEnd)
			clipboard.writeText(editor.documentOffsets().sliceCodepoints(editor.selectionStart,
				editor.selectionEnd));
	}

	static function paintSelection(canvas:Canvas, editor:TextEditorState,
			active:Bool, theme:haxeon.ui.theme.Theme, additional:Array<TextSelection>):Void {
		canvas.translate(0.0, -editor.scrollOffsetY);
		for (selection in additional)
			for (rect in editor.layout.selectionRects(new TextPosition(selection.anchor, selection.anchorAffinity),
				new TextPosition(selection.focus, selection.focusAffinity)))
				canvas.fillRectIfPositive(rect, active ? theme.textSelection : theme.textSelectionInactive);
		if (editor.selectionStart != editor.selectionEnd) {
			for (rect in editor.layout.selectionRects(editor.anchorPosition(), editor.focusPosition()))
				canvas.fillRectIfPositive(rect, active ? theme.textSelection : theme.textSelectionInactive);
		}
	}

	static function paintEditorDecorations(canvas:Canvas, editor:TextEditorState,
			active:Bool, theme:haxeon.ui.theme.Theme, timeSeconds:Float,
			showCaret:Bool = true, ?additional:Array<TextSelection>):Void {
		if (editor.scrollOffsetY != 0.0)
			canvas.translate(0.0, -editor.scrollOffsetY);
		if (active && editor.compositionStart >= 0 && editor.compositionStart != editor.compositionEnd) {
			for (rect in editor.compositionRects())
				canvas.fillRectIfPositive(new Rect(rect.x, rect.y + rect.height - 1.0, rect.width, 1.0),
					Color.rgba(0.95, 0.75, 0.24, 1.0));
		}
		if (showCaret && active && additional != null && editor.isCaretVisible(timeSeconds))
			for (selection in additional) if (selection.anchor == selection.focus) {
				var caret = editor.layout.caret(new TextPosition(selection.focus, selection.focusAffinity));
				var topX = caret.x + caret.ascender * caret.slope;
				var bottomX = caret.x + caret.descender * caret.slope;
				canvas.fillRectIfPositive(new Rect(Math.min(topX, bottomX), caret.y + Math.min(caret.ascender, caret.descender),
					Math.max(1.0, absolute(bottomX - topX)), Math.max(1.0, absolute(caret.descender - caret.ascender))), theme.textCaret);
			}
		if (showCaret && active && editor.selectionStart == editor.selectionEnd &&
				editor.isCaretVisible(timeSeconds)) {
			var caret = editor.layout.caret(editor.focusPosition());
			var topX = caret.x + caret.ascender * caret.slope;
			var topY = caret.y + caret.ascender;
			var bottomX = caret.x + caret.descender * caret.slope;
			var bottomY = caret.y + caret.descender;
			var x = Math.min(topX, bottomX);
			var y = Math.min(topY, bottomY);
			var height = Math.max(1.0, absolute(bottomY - topY));
			canvas.fillRectIfPositive(new Rect(x, y, Math.max(1.0, absolute(bottomX - topX)), height),
				theme.textCaret);
		}
	}

	static inline function absolute(value:Float):Float
		return value < 0.0 ? -value : value;

	static function transformTextRangeRect(rect:TextRangeRect, geometry:ResolvedLayoutItem,
			transform:Transform2D, scrollOffsetY:Float):TextRangeRect {
		var left = geometry.x + rect.x;
		var top = geometry.y + rect.y - scrollOffsetY;
		var right = left + rect.width;
		var bottom = top + rect.height;
		var x0 = transform.a * left + transform.c * top + transform.tx;
		var y0 = transform.b * left + transform.d * top + transform.ty;
		var x1 = transform.a * right + transform.c * top + transform.tx;
		var y1 = transform.b * right + transform.d * top + transform.ty;
		var x2 = transform.a * left + transform.c * bottom + transform.tx;
		var y2 = transform.b * left + transform.d * bottom + transform.ty;
		var x3 = transform.a * right + transform.c * bottom + transform.tx;
		var y3 = transform.b * right + transform.d * bottom + transform.ty;
		var minX = Math.min(Math.min(x0, x1), Math.min(x2, x3));
		var minY = Math.min(Math.min(y0, y1), Math.min(y2, y3));
		var maxX = Math.max(Math.max(x0, x1), Math.max(x2, x3));
		var maxY = Math.max(Math.max(y0, y1), Math.max(y2, y3));
		return new TextRangeRect(rect.start, rect.end, minX, minY, maxX - minX, maxY - minY,
			rect.visualLeftIsStart);
	}

	static function defaultStyle(multiline:Bool):LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.fixed(240.0);
		result.height = LayoutAxis.fixed(multiline ? 120.0 : 40.0);
		result.padding = new Insets(10.0, 8.0, 10.0, 8.0);
		result.radiusTopLeft = result.radiusTopRight = 5.0;
		result.radiusBottomLeft = result.radiusBottomRight = 5.0;
		result.clipHorizontal = true;
		return result;
	}
}

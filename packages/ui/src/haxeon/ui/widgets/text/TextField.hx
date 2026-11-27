package haxeon.ui.widgets.text;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import haxeon.platform.input.TextEdit;
import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.TextLayout.TextRangeRect;

import haxeon.ui.LayoutNode;

import haxeon.ui.widgets.controls.ComboBox;

import haxeon.editor.TextDocument;
import haxeon.platform.input.TextEdit;
import haxeon.ui.Canvas;
import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.TextStyle;
import haxeon.ui.Transform2D;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.State;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.AccessibilityRequest;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.style.StyleState;
import haxeon.ui.style.StyleTarget;
import haxeon.ui.theme.TextRole;
import nativekit.ffi.NativeKitTypes.TextEditAction;

import haxeon.ui.widgets.text.TextEditorState;
/** Text editor composed from a Haxe box and NativeUI text primitive. */
/**
 * A component: its inputs are its configuration, compared as `inputsEqual` says, and its body also depends on its
 * editor state, which wakes it on every change (`TextEditorState.version`). Callbacks run through the newest
 * description; providers it calls while building are inputs, compared by identity.
 */
class TextField implements ScopeView {
	/** Shared only by internal read-only selection paths. */
	static final NoAdditionalSelections:Array<TextSelection> = [];

	/**
	 * Identifies the field among its siblings, so its selection and history survive rebuilds: required, and never
	 * empty.
	 */
	public final key:String;

	/** The text; kept in sync with the document when the field edits one. */
	public final value:String;
	/** Paint-only whitespace visibility: off, selection, or all. */
	public final renderWhitespace:String;

	/** The color whitespace is drawn in when `renderWhitespace` shows it; the theme's muted text color when null. */
	public final whitespaceColor:Null<Color>;

	/** The field's accessible name. */
	public final label:Null<String>;
	/** Muted visual hint shown only while the editor is empty. */
	public final placeholder:Null<String>;
	/** Show a trailing ellipsis while an overflowing single-line value is not being edited. */
	public final ellipsizeWhenUnfocused:Bool;

	/** Whether Enter inserts a line break rather than submitting. */
	public final multiline:Bool;
	/** What the on-screen keyboard's action key is (NativeKit text-input action: 0 default, 5 send); Enter reaches the field as a key either way. */
	public final imeAction:Int;

	/** The field's box. */
	public final style:LayoutStyle;

	/** Its typography; the theme's body style when null. */
	public final textStyle:Null<TextStyle>;

	/** Its text color; the theme's when null. */
	public final textColor:Null<Color>;
	/** Sorted, disjoint absolute codepoint foreground ranges for a visible chunk. */
	public final colorRangeProvider:Null<(Int, Int) -> Array<TextColorRange>>;
	/** Backgrounds and underlines in absolute document codepoint coordinates. */
	public final decorationProvider:Null<(Int, Int) -> Array<TextDecoration>>;
	/** Increment when state captured by presentation providers changes. */
	public final presentationRevision:Int;
	/**
	 * Optional controlled selection, read when the field builds (after shared-document synchronization) and after a
	 * delegated edit; null from it imposes none. The field follows a change only through a rebuild, so a provider whose
	 * selection changes on its own reads reactive state, which the field then depends on.
	 */
	public final selectionProvider:Null<Void->Null<TextSelection>>;
	/** Reports widget selection after edit callbacks have synchronized a caller-owned document. */
	public final onSelectionChange:Null<TextSelection->Void>;

	/**
	 * Called when an edit or a caret move needs the caret scrolled into view, for a field inside a scroll view of its
	 * own.
	 */
	public final onCaretRevealRequest:Null<Void->Void>;
	/** Additional owner-controlled selections; the primary stays in selectionProvider. */
	public final additionalSelectionProvider:Null<Void->Array<TextSelection>>;
	/** Logical viewport height when an outer scroll container owns scrolling. */
	public final pageHeightProvider:Null<Void->Float>;
	/** Return true after applying an operation; the live layout supplies shaped word boundaries. */
	/** True when an application document owns undo/redo. */
	public final historyManagedExternally:Bool;
	/** Optional external viewport scroll; delta uses application layout coordinates. */
	public final onSelectionDragScroll:Null<Float->Bool>;

	/**
	 * Offered each edit before the field makes it; returning true takes it over, for a document owner that applies
	 * edits itself.
	 */
	public final onEditIntent:Null<(TextEditIntent, TextEditorLayout) -> Bool>;
	/** Optional aggregate selected text for clipboard copy/cut. */
	public final selectionTextProvider:Null<Void->Null<String>>;
	/** Optional pointer action at the text offset; true consumes normal selection handling. */
	public final onTextPointerDown:Null<Int->UiEvent->Bool>;
	/** Hit-tested pointer movement, independent of selection dragging. */
	public final onTextPointerMove:Null<Int->UiEvent->Void>;
	/** Typed selector classes used by composite fields such as ComboBox. */
	public final classes:Array<String>;

	/** Whether the field accepts input and focus. */
	public final enabled:Bool;
	/** Selectable and copyable but not editable; multiline fields also scroll with the wheel. */
	public final readOnly:Bool;
	/** With readOnly, keeps the newest text in view until the user scrolls away from the end. */
	public final followTail:Bool;

	/** Called with the text after each edit. */
	public final onChange:Null<String->Void>;
	/** Applied edit notifications for a caller-owned EditorKit document. */
	public final onEdit:Null<TextEditTransaction->Void>;
	/** Optional mutable EditorKit model shared with the persistent editor state. */
	public final document:Null<TextDocument>;

	/** Called with the text when the user presses Enter in a single-line field. */
	public final onSubmit:Null<String->Void>;

	/** Called each frame with the editor's state, for an input method debugging panel. */
	public final onDiagnostics:Null<TextEditorDiagnostics->Void>;
	/** Current logical-screen caret bounds after layout, or null when clipped out. */
	public final onCaretRect:Null<Null<Rect>->Void>;
	/** Borrowed retained text geometry after layout, for aligned companion views. */
	public final onLayoutResolved:Null<TextEditorLayout->ResolvedLayoutItem->Void>;
	/** Semantic role override used by composite editable controls. */
	public final semanticRole:AccessibilityRole;
	/** Semantic action capabilities override used by composite editable controls. */
	public final semanticActions:AccessibilityAction;
	/** Semantic states a composite editable control adds, such as a combo box's popup. */
	public final semanticStates:AccessibilityState;
	/** Views the field builds over its content with its style as their parent, such as a combo box's frame and icon. */
	public final overlays:Array<View>;

	/**
	 * A field editing `value`, or `document` when given, which several editors may share; `onEdit` then receives each
	 * transaction. Throws when `key` is empty, or with `onEdit` and no document. Every input is given here, the later ones
	 * by name (`new TextField("name", placeholder: "Name", onSubmit: submit)`); none changes after.
	 */
	public function new(key:String,
			value:String = "",
			?onChange:String->Void,
			?style:LayoutStyle,
			?label:String,
			?textStyle:TextStyle,
			?textColor:Color,
			multiline:Bool = false,
			?document:TextDocument,
			?onEdit:TextEditTransaction->Void,
			?placeholder:String,
			enabled:Bool = true,
			readOnly:Bool = false,
			followTail:Bool = false,
			?classes:Array<String>,
			ellipsizeWhenUnfocused:Bool = false,
			imeAction:Int = 0,
			renderWhitespace:String = "off",
			?whitespaceColor:Color,
			?tabWidth:Int,
			?wrap:TextWrap,
			codeWordBoundaries:Bool = false,
			historyManagedExternally:Bool = false,
			presentationRevision:Int = 0,
			semanticRole:AccessibilityRole = AccessibilityRole.TextField,
			?semanticActions:AccessibilityAction,
			?semanticStates:AccessibilityState,
			?overlays:Array<View>,
			?onSubmit:String->Void,
			?onSelectionChange:TextSelection->Void,
			?onCaretRect:Null<Rect>->Void,
			?onLayoutResolved:TextEditorLayout->ResolvedLayoutItem->Void,
			?onDiagnostics:TextEditorDiagnostics->Void,
			?onCaretRevealRequest:Void->Void,
			?onSelectionDragScroll:Float->Bool,
			?onEditIntent:(TextEditIntent, TextEditorLayout) -> Bool,
			?onTextPointerDown:Int->UiEvent->Bool,
			?onTextPointerMove:Int->UiEvent->Void,
			?selectionProvider:Void->Null<TextSelection>,
			?additionalSelectionProvider:Void->Array<TextSelection>,
			?selectionTextProvider:Void->Null<String>,
			?colorRangeProvider:(Int, Int) -> Array<TextColorRange>,
			?decorationProvider:(Int, Int) -> Array<TextDecoration>,
			?pageHeightProvider:Void->Float) {
		if (key == null || key.length == 0) throw "Text fields require a stable key";
		if (onEdit != null && document == null) throw "Transaction callbacks require a shared EditorKit document";
		this.key = key;
		this.value = value == null ? "" : value;
		this.onChange = onChange;
		this.style = style == null ? defaultStyle(multiline) : style.copy();
		this.label = label;
		this.textStyle = textStyle;
		this.textColor = textColor;
		this.multiline = multiline;
		this.document = document;
		this.onEdit = onEdit;
		this.placeholder = placeholder;
		this.enabled = enabled;
		this.readOnly = readOnly;
		this.followTail = followTail;
		this.classes = classes == null ? [] : classes.copy();
		this.ellipsizeWhenUnfocused = ellipsizeWhenUnfocused;
		this.imeAction = imeAction;
		this.renderWhitespace = renderWhitespace;
		this.whitespaceColor = whitespaceColor;
		this.tabWidth = tabWidth;
		this.wrap = wrap;
		this.codeWordBoundaries = codeWordBoundaries;
		this.historyManagedExternally = historyManagedExternally;
		this.presentationRevision = presentationRevision;
		this.semanticRole = semanticRole;
		this.semanticActions = semanticActions == null
			? AccessibilityAction.SetValue | AccessibilityAction.SetSelection : semanticActions;
		this.semanticStates = semanticStates == null ? AccessibilityState.empty() : semanticStates;
		this.overlays = overlays == null ? [] : overlays.copy();
		this.onSubmit = onSubmit;
		this.onSelectionChange = onSelectionChange;
		this.onCaretRect = onCaretRect;
		this.onLayoutResolved = onLayoutResolved;
		this.onDiagnostics = onDiagnostics;
		this.onCaretRevealRequest = onCaretRevealRequest;
		this.onSelectionDragScroll = onSelectionDragScroll;
		this.onEditIntent = onEditIntent;
		this.onTextPointerDown = onTextPointerDown;
		this.onTextPointerMove = onTextPointerMove;
		this.selectionProvider = selectionProvider;
		this.additionalSelectionProvider = additionalSelectionProvider;
		this.selectionTextProvider = selectionTextProvider;
		this.colorRangeProvider = colorRangeProvider;
		this.decorationProvider = decorationProvider;
		this.pageHeightProvider = pageHeightProvider;
	}


	/** Tab stops in space advances; zero preserves the default layout behavior. */
	public final tabWidth:Null<Int>;
	/** Explicit wrapping policy; null retains the normal single/multiline defaults. */
	public final wrap:Null<TextWrap>;
	/** Use lexical identifier boundaries for code selection and word commands. */
	public final codeWordBoundaries:Bool;

	public function scopeKey():String return key;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, TextField)) return false;
		var other:TextField = cast previous;
		if (key != other.key || value != other.value || renderWhitespace != other.renderWhitespace
			|| !haxeon.Equality.equals(whitespaceColor, other.whitespaceColor) || label != other.label
			|| placeholder != other.placeholder || ellipsizeWhenUnfocused != other.ellipsizeWhenUnfocused
			|| multiline != other.multiline || imeAction != other.imeAction || haxeon.Diff.mask(style, other.style) != 0
			|| textStyle != other.textStyle || !haxeon.Equality.equals(textColor, other.textColor)
			|| presentationRevision != other.presentationRevision
			|| historyManagedExternally != other.historyManagedExternally
			|| enabled != other.enabled || readOnly != other.readOnly || followTail != other.followTail
			|| document != other.document || semanticRole != other.semanticRole
			|| semanticActions != other.semanticActions
			|| semanticStates != other.semanticStates || tabWidth != other.tabWidth || wrap != other.wrap
			|| codeWordBoundaries != other.codeWordBoundaries || classes.length != other.classes.length
			|| overlays.length != other.overlays.length) return false;
		for (index in 0...classes.length) if (classes[index] != other.classes[index]) return false;
		for (index in 0...overlays.length) if (overlays[index] != other.overlays[index]) return false;
		// Called while building: inputs, by identity.
		if (colorRangeProvider != other.colorRangeProvider || decorationProvider != other.decorationProvider
			|| selectionProvider != other.selectionProvider
			|| additionalSelectionProvider != other.additionalSelectionProvider) return false;
		// Called on events through the newest description: only whether there is one matters.
		return (onChange == null) == (other.onChange == null) && (onEdit == null) == (other.onEdit == null)
			&& (onSubmit == null) == (other.onSubmit == null)
			&& (onSelectionChange == null) == (other.onSelectionChange == null)
			&& (onCaretRevealRequest == null) == (other.onCaretRevealRequest == null)
			&& (onSelectionDragScroll == null) == (other.onSelectionDragScroll == null)
			&& (onEditIntent == null) == (other.onEditIntent == null)
			&& (selectionTextProvider == null) == (other.selectionTextProvider == null)
			&& (pageHeightProvider == null) == (other.pageHeightProvider == null)
			&& (onTextPointerDown == null) == (other.onTextPointerDown == null)
			&& (onTextPointerMove == null) == (other.onTextPointerMove == null)
			&& (onDiagnostics == null) == (other.onDiagnostics == null)
			&& (onCaretRect == null) == (other.onCaretRect == null)
			&& (onLayoutResolved == null) == (other.onLayoutResolved == null);
	}

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

	public function buildBody(context:BuildContext):ViewRoot return buildField(context, context.rootId("field"));

	function buildField(context:BuildContext, id:haxeon.ui.core.WidgetId):RenderNode {
		var latest = context.latestOf(this);
		var resolved = context.resolveTextRole(TextRole.Body, TextStyleOverride.fromTextStyle(textStyle));
		var resolvedTextColor = textColor == null ? resolved.textColor : textColor;
		// Typography is immutable; replace the complete paragraph value for this field.
		var paragraph = resolved.paragraphStyle;
		if (tabWidth != null) paragraph = paragraph.withTabWidth(tabWidth);
		paragraph = paragraph.withWrap(wrap == null ? (multiline ? TextWrap.WordCharacter : TextWrap.None) : wrap);
		var stored:State<TextEditorState> = acquireState(context, id, value, resolved.textStyle, paragraph, document);
		var editor:TextEditorState = stored.value;
		// The editor is a mutable resource: the body depends on its version, which every change below bumps.
		editor.version.value;
		var refresh = function() editor.changed();
		editor.layout.codeWordBoundaries = codeWordBoundaries;
		editor.configureTail(followTail && readOnly);
		// A caller's value is adopted when it gives a new description; the body running again for its own state keeps
		// what the user typed.
		var documentChanged = document != null ? editor.syncDocument(document,
			true) : editor.adoptExternal(value, true);
		if (documentChanged) {
			editor.resetCaretBlink(Sys.time());
			if (editor.tailFollowing) editor.scrollToEnd();
		}
		var imposed = selectionProvider == null ? null : selectionProvider();
		if (imposed != null) editor.setAnchoredSelection(imposed, true);
		var additionalSelections = additionalSelectionProvider
			== null ? NoAdditionalSelections : additionalSelectionProvider();
		var hasAdditionalCaret = false;
		for (selection in additionalSelections) {
			if (selection.anchor == selection.focus) hasAdditionalCaret = true;
			if (selection.anchor > editor.documentLength()
				|| selection.focus > editor.documentLength()) throw "Additional selection is outside the document";
		}
		editor.updateStyle(resolved.textStyle, paragraph);
		editor.configurePresentation(colorRangeProvider, decorationProvider, presentationRevision);

		var authored = enabled ? StyleState.empty() : StyleState.Disabled;
		var identity = new StyleIdentity("text-field", key, key, classes, ["text-field"]);
		var computed = context.resolveStyled(id, identity, style, authored, null);
		if (textColor != null) computed.setColor(StyleProperty.TextColor,
			textColor,
			new StyleSource("local", "text-field", -1, "local"));
		var node = context.createNode(id, LayoutVisualKind.Box, computed.toLayoutStyle());
		context.applyStyled(node, identity, computed, authored);
		node.focusable = enabled;
		node.enabled = enabled;
		var semantics = new Semantics(semanticRole, label == null ? key : label);
		semantics.setValueSource(editor, editor.documentLength());
		semantics.actions = readOnly ? semanticActions.remove(AccessibilityAction.SetValue) : semanticActions;
		semantics.states |= semanticStates;
		if (readOnly) semantics.states |= AccessibilityState.ReadOnly;
		semantics.textStart = 0;
		semantics.selectionStart = editor.selectionStart;
		semantics.selectionEnd = editor.selectionEnd;
		if (!enabled) semantics.states |= AccessibilityState.Disabled;
		if (editor.focused) semantics.states |= AccessibilityState.Focused;
		if (multiline) semantics.states |= AccessibilityState.Multiline;
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
		var editorContent = context.createNode(context.rootId("editor-content"), LayoutVisualKind.Box,
			editorContentStyle);
		if (decorationProvider != null) {
			var backgroundStyle = new LayoutStyle();
			backgroundStyle.width = LayoutAxis.grow();
			backgroundStyle.height = LayoutAxis.grow();
			backgroundStyle.positioning = LayoutPositioning.Absolute;
			backgroundStyle.zIndex = 0;
			var backgroundNode = context.createNode(context.rootId("editor-background"),
				LayoutVisualKind.Custom,
				backgroundStyle);
			backgroundNode.hitTestSelf = false;
			backgroundNode.onPaint(function(canvas, geometry) {
				if (!editor.isDisposed()) {
					var visible = geometry.visibleLocalBounds();
					canvas.translate(0.0, -editor.scrollOffsetY);
					editor.layout.paintDecorations(canvas,
						true,
						editor.scrollOffsetY + visible.y,
						editor.scrollOffsetY + visible.y + visible.height,
						visible.x,
						visible.x + visible.width);
				}
			});
			editorContent.add(backgroundNode);
		}
		// Unfocused, unselected fields need only their text node. State changes
		// invalidate the frame before selection or caret decoration is painted.
		var showEllipsis = ellipsizeWhenUnfocused && !multiline
			&& !editor.focused && editor.documentLength() > 0 && colorRangeProvider == null
			&& decorationProvider == null;
		if (!showEllipsis && (editor.selectionStart != editor.selectionEnd || additionalSelections.length > 0)) {
			var selectionStyle = new LayoutStyle();
			selectionStyle.width = LayoutAxis.grow();
			selectionStyle.height = LayoutAxis.grow();
			selectionStyle.positioning = LayoutPositioning.Absolute;
			selectionStyle.zIndex = 0;
			var selectionNode = context.createNode(context.rootId("editor-selection"),
				LayoutVisualKind.Custom,
				selectionStyle);
			selectionNode.hitTestSelf = false;
			selectionNode.onPaint(function(canvas, geometry) {
				if (!editor.isDisposed()) {
					var visible = geometry.visibleLocalBounds();
					paintSelection(canvas,
						editor,
						context.textInput.isOwner(id),
						context.theme,
						additionalSelections,
						editor.scrollOffsetY + visible.y,
						editor.scrollOffsetY + visible.y + visible.height);
				}
			});
			editorContent.add(selectionNode);
		}
		if (renderWhitespace != "off") {
			// The painter retains the value independently of the rebuilt node.
			var fieldBackground = node.layout.style.background;
			var whitespaceStyle = new LayoutStyle();
			whitespaceStyle.width = LayoutAxis.grow();
			whitespaceStyle.height = LayoutAxis.grow();
			whitespaceStyle.positioning = LayoutPositioning.Absolute;
			whitespaceStyle.zIndex = 3;
			var whitespaceNode = context.createNode(context.rootId("editor-whitespace"),
				LayoutVisualKind.Custom,
				whitespaceStyle);
			whitespaceNode.hitTestSelf = false;
			whitespaceNode.onPaint(function(canvas, geometry) {
				if (editor.isDisposed()) return;
				var visible = geometry.visibleLocalBounds();
				var selections = additionalSelections.copy();
				selections.push(new TextSelection(editor.selectionAnchor, editor.selectionFocus));
				var normal = whitespaceColor == null ? context.theme.tokens.textSecondary : whitespaceColor;
				var editorBackground = fieldBackground.compositeOver(context.theme.tokens.surface);
				var selectionFill = context.textInput.isOwner(id)
					? context.theme.textSelection : context.theme.textSelectionInactive;
				var background = selectionFill.compositeOver(editorBackground);
				var selected = haxeon.ui.theme.Theme.contrastingDecoration(normal, background);
				normal = haxeon.ui.theme.Theme.contrastingDecoration(normal, editorBackground);
				canvas.translate(0, -editor.scrollOffsetY);
				editor.layout.paintWhitespace(canvas,
					renderWhitespace,
					selections,
					normal,
					selected,
					editor.scrollOffsetY + visible.y,
					editor.scrollOffsetY + visible.y + visible.height,
					visible.x,
					visible.x + visible.width);
			});
			editorContent.add(whitespaceNode);
		}
		var showsPlaceholder = editor.documentLength() == 0 && placeholder != null && placeholder.length > 0;
		// Single-line fields use the text node so their full value and theme
		// foreground update together as the editor content changes.
		var useTextNode = showsPlaceholder || (!multiline && colorRangeProvider == null && decorationProvider == null);
		var textNode = context.createNode(context.rootId("text"),
			useTextNode ? LayoutVisualKind.Text : LayoutVisualKind.Custom,
			textNodeStyle);
		if (showsPlaceholder) textNode.layout.text = placeholder;
		else if (useTextNode) textNode.layout.text = editor.layoutText();
		else {
			// Clay orders absolute paint layers independently of flow content.
			// Keep glyphs above decoration/selection layers, while a separate
			// measurement-only node supplies their shared intrinsic size.
			textNodeStyle.positioning = LayoutPositioning.Absolute;
			textNode.layout.intrinsicContent = editor.renderContent;
		}
		// The text node owns this style; it can also serve as the working copy for computed font overrides.
		var textNodeTextStyle = editor.textStyle;
		var fontSource = computed.source(StyleProperty.FontSize);
		var letterSource = computed.source(StyleProperty.LetterSpacing);
		if (textStyle == null && fontSource != null && fontSource.layer
			!= "framework") textNodeTextStyle =
			textNodeTextStyle.withFontSize(computed.getNumber(StyleProperty.FontSize));
		if (textStyle == null && letterSource != null && letterSource.layer != "framework") textNodeTextStyle =
			textNodeTextStyle.withLetterSpacing(computed.getNumber(StyleProperty.LetterSpacing));
		var colorSource = computed.source(StyleProperty.TextColor);
		var textNodeColor = showsPlaceholder ? context.theme.tokens.textSecondary : (colorSource != null
			&& colorSource.layer != "framework" ? computed.getColor(StyleProperty.TextColor) : resolvedTextColor);
		if (showEllipsis) textNode = new MiddleEllipsisText("inactive-value",
			editor.text,
			false,
			new TextStyleOverride(textNodeTextStyle.font,
			textNodeTextStyle.fontSize,
			textNodeTextStyle.letterSpacing,
			TextWrap.None,
			null,
			null,
			null,
			textNodeColor)).makeNode(context);
		textNode.applyTextComponents(textNodeTextStyle, editor.paragraphStyle, textNodeColor);
		if (!showsPlaceholder) {
			editor.updateStyle(textNodeTextStyle, editor.paragraphStyle);
			editor.setRenderColor(textNodeColor);
		}
		editorContent.add(textNode);
		if (!useTextNode) {
			var measureStyle = new LayoutStyle();
			measureStyle.width = LayoutAxis.grow();
			measureStyle.height = LayoutAxis.grow();
			var measureNode = context.createNode(context.rootId("editor-measure"), LayoutVisualKind.Custom,
				measureStyle);
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
			var paintNode = context.createNode(context.rootId("editor-paint"), LayoutVisualKind.Custom, paintStyle);
			paintNode.hitTestSelf = false;
			paintNode.onPaint(function(canvas, _) {
				if (!editor.isDisposed()) {
					var now = Sys.time();
					var active = context.textInput.isOwner(id);
					if (active && (editor.selectionStart == editor.selectionEnd
						|| hasAdditionalCaret)) context.textInput.requestCaretFrameAt(editor.nextCaretBlinkTime(now));
					paintEditorDecorations(canvas, editor, active, context.theme, now, true, additionalSelections);
				}
			});
			editorContent.add(paintNode);
		}
		node.add(editorContent);
		if (overlays.length > 0) context.withStyleParent(computed, function() {
			for (overlay in overlays) node.add(overlay.build(context));
		});

		var refreshState = function(revealCaret:Bool = true) {
			if (revealCaret) {
				editor.requestCaretReveal();
				var reveal = latest().onCaretRevealRequest;
				if (reveal != null) reveal();
			} else editor.preserveViewport();
			semantics.setValueSource(editor, editor.documentLength());
			semantics.selectionStart = editor.selectionStart;
			semantics.selectionEnd = editor.selectionEnd;
			refresh();
		};
		var updateState = function(revealCaret:Bool = true) {
			latest().publishSelection(editor);
			refreshState(revealCaret);
		};
		var delegateEdit = function(intent:TextEditIntent):Bool {
			var handler = latest().onEditIntent;
			if (handler == null || !handler(intent, editor.layout)) return false;
			if (document != null) editor.syncDocument(document);
			else editor.syncExternal(latest().value);
			var provider = latest().selectionProvider;
			var imposed = provider == null ? null : provider();
			if (imposed != null) editor.setAnchoredSelection(imposed);
			editor.resetCaretBlink(Sys.time());
			updateState();
			return true;
		};
		var publishTextChange = function(previousRevision:Int) {
			var field = latest(), edited = field.onEdit, changed = field.onChange;
			if (editor.documentRevision() != previousRevision && editor.lastEditTransaction != null && edited != null)
				edited(editor.lastEditTransaction);
			if (editor.documentRevision() != previousRevision && changed != null) changed(editor.layoutText());
			latest().publishSelection(editor);
			refreshState();
		};

		editorContent.onResolved(function(geometry) {
			editor.finishBuildSynchronization();
			editor.configureHistory(!historyManagedExternally);
			if (multiline) {
				editor.updateLayout(geometry.width);
				if (readOnly) {
					// A read-only view keeps what the user scrolled to instead of chasing the caret.
					editor.setViewportHeight(geometry.height);
					if (editor.tailFollowing && editor.scrollToEnd()) refresh();
				} else if (editor.resolveCaretReveal(geometry.height)) refresh();
			}
		});
		var drag = context.resourceState(context.id("selection-drag"),
			function() return new SelectionDragController(),
			function(value) value.dispose()).value;
		textNode.onResolved(function(geometry) {
			editor.updateLayout(geometry.width);
			drag.layoutResolved();
			var resolvedHandler = latest().onLayoutResolved;
			if (resolvedHandler != null) resolvedHandler(editor.layout, geometry);
			if (multiline && !readOnly
				&& editorContent.resolved != null
				&& editor.resolveCaretReveal(editorContent.resolved.height)) refresh();
			latest().syncCursor(editor, context, id, geometry);
		});
		node.on(UiEventKind.Focus, function(_) {
			if (!enabled) return;
			editor.focused = true;
			editor.resetCaretBlink(Sys.time());
			semantics.states |= AccessibilityState.Focused;
			refresh();
			context.textInput.activate(id);
			if (textNode.resolved != null) latest().syncCursor(editor, context, id, cast textNode.resolved);
			else latest().publishDiagnostics(editor, context, null);
		});
		var blur = function(event:UiEvent) {
			if (!editor.focused && !editor.draggingSelection) return;
			editor.breakHistoryGroup();
			editor.focused = false;
			editor.draggingSelection = false;
			editor.cancelPointerClick();
			semantics.states = semantics.states.remove(AccessibilityState.Focused);
			refresh();
			context.textInput.deactivate(id);
			latest().publishDiagnostics(editor, context, null);
		};
		node.on(UiEventKind.Blur, blur);
		node.on(UiEventKind.FocusLost, blur);

		var extendDrag = function(x:Float, y:Float):Void {
			var geometry = textNode.resolved;
			if (geometry == null) return;
			var clip = geometry.clipBounds;
			var clampedY = Math.max(clip.y, Math.min(clip.y + clip.height, y));
			var point = geometry.viewportToLayout(x, clampedY);
			var pointer = geometry.viewportToLayout(x, y);
			var position = editor.hitTestSelectionDrag(point.x - geometry.x,
				pointer.y - geometry.y + editor.scrollOffsetY,
				point.y - geometry.y + editor.scrollOffsetY);
			if (editor.extendPointerSelection(position)) {
				editor.resetCaretBlink(Sys.time());
				updateState(false);
			}
		};
		drag.configure(context.animations, editor, function() return textNode.resolved, extendDrag, function(delta) {
			var dragScroll = latest().onSelectionDragScroll;
			var changed = dragScroll == null ? editor.scrollBy(delta) : dragScroll(delta);
			if (changed) refresh();
			return changed;
		});
		node.on(UiEventKind.PointerDown, function(event) {
			var pointerAction = latest().onTextPointerDown;
			if (enabled && pointerAction != null && textNode.resolved != null) {
				var geometry:ResolvedLayoutItem = cast textNode.resolved;
				var point = geometry.viewportToLayout(event.x, event.y);
				var hit = editor.hitTest(point.x - geometry.x, point.y - geometry.y + editor.scrollOffsetY);
				if (pointerAction(hit.offset, event)) {
					event.preventDefault();
					event.stopPropagation();
					return;
				}
			}
			if (!enabled || event.button != 0 || textNode.resolved == null) return;
			event.capturePointer();
			var geometry:ResolvedLayoutItem = cast textNode.resolved;
			var point = geometry.viewportToLayout(event.x, event.y);
			var position = editor.hitTest(point.x - geometry.x, point.y - geometry.y + editor.scrollOffsetY);
			editor.resetCaretBlink(Sys.time());
			var extend = event.modifiers.contains(UiModifier.Shift);
			if (extend) editor.cancelPointerClick();
			var clickCount = extend ? 1 : editor.registerPointerClick(position,
				context.gestures.timeSeconds(),
				event.x,
				event.y);
			var changed = editor.beginPointerSelection(position, clickCount, extend);
			if (changed) updateState(false);
			editor.draggingSelection = true;
			event.preventDefault();
		});
		node.on(UiEventKind.PointerMove, function(event) {
			var pointerMove = latest().onTextPointerMove;
			if (enabled && pointerMove != null && textNode.resolved != null) {
				var geometry:ResolvedLayoutItem = cast textNode.resolved;
				var point = geometry.viewportToLayout(event.x, event.y);
				var hit = editor.hitTest(point.x - geometry.x, point.y - geometry.y + editor.scrollOffsetY);
				pointerMove(hit.offset, event);
			}
			if (!enabled || !editor.draggingSelection || textNode.resolved == null) return;
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

		var handleKey = function(event:UiEvent) {
			if (!enabled) return;
			// Ctrl+Alt arrows belong to application navigation, including its
			// Shift variant. Leave them unconsumed for the command route.
			if ((event.modifiers & (UiModifier.Control | UiModifier.Alt)) == (UiModifier.Control | UiModifier.Alt)
				&& (event.key == UiKey.Left
				|| event.key == UiKey.Right || event.key == UiKey.Up || event.key == UiKey.Down)) return;
			var extend = event.modifiers.contains(UiModifier.Shift);
			var command = (event.modifiers.contains(UiModifier.Control) || event.modifiers.contains(UiModifier.Super));
			if (command && (event.key == UiKey.Z || event.key == UiKey.Y)) {
				if (historyManagedExternally) return;
				var previousRevision = editor.documentRevision();
				var changed = !readOnly && (event.key == UiKey.Y || extend ? editor.redo() : editor.undo());
				if (changed) publishTextChange(previousRevision);
				editor.resetCaretBlink(Sys.time());
				event.preventDefault();
				return;
			}
			var macWordNavigation =
			#if (mac || ios)
			event.modifiers.contains(UiModifier.Alt) && !event.modifiers.contains(UiModifier.Control);
			#else
			false;
			#end
			var wordNavigation =
			#if (mac || ios)
			macWordNavigation;
			#else
			event.modifiers.contains(UiModifier.Control);
			#end
			if (!readOnly) {
				var consumed = event.key
					== UiKey.Backspace
					? delegateEdit(wordNavigation ? DeleteWordBackward(macWordNavigation) : DeleteBackward)
					: event.key == UiKey.Delete ? delegateEdit(wordNavigation ? DeleteWordForward(macWordNavigation)
					: DeleteForward) : event.key == UiKey.Enter && multiline ? delegateEdit(Insert("\n")) : false;
				if (consumed) {
					event.preventDefault();
					return;
				}
			}
			var handled = true;
			var changed = false;
			var textEdited = false;
			var previousRevision = editor.documentRevision();
			// Select-all is exactly Ctrl+A (Cmd+A on macOS); Shift/Alt variants belong to the application keymap.
			if (command && event.key == UiKey.A && (!event.modifiers.contains(UiModifier.Shift)
				&& !event.modifiers.contains(UiModifier.Alt))) changed = editor.selectAll();
			else if (command && event.key == UiKey.C) latest().copyCurrentSelection(context, editor);
			else if (command && event.key == UiKey.X) {
				latest().copyCurrentSelection(context, editor);
				if (!readOnly && delegateEdit(Insert(""))) {
					event.preventDefault();
					return;
				}
				if (!readOnly) {
					changed = editor.replace(editor.selectionStart, editor.selectionEnd, "");
					textEdited = true;
				}
			} else if (command && event.key == UiKey.V) {
				if (readOnly) handled = false;
				else context.clipboard.readText(function(pasted) {
					if (editor.isDisposed() || !editor.focused) return;
					if (delegateEdit(Paste(pasted))) return;
					var beforePaste = editor.documentRevision();
					if (editor.insert(pasted, TextEditorHistoryKind.Paste)) {
						editor.resetCaretBlink(Sys.time());
						publishTextChange(beforePaste);
					}
				});
			}
			#if (mac || ios)
			else if (event.modifiers.contains(UiModifier.Super)
				&& event.key == UiKey.Left) changed = editor.moveCaretToLineBoundary(false,
				extend);
			else if (event.modifiers.contains(UiModifier.Super)
				&& event.key == UiKey.Right) changed = editor.moveCaretToLineBoundary(true,
				extend);
			#end
			else if (wordNavigation && event.key == UiKey.Left) changed = editor.moveCaretByWord(
				-1,
				extend,
				macWordNavigation);
			else if (wordNavigation && event.key == UiKey.Right) changed = editor.moveCaretByWord(1,
				extend,
				macWordNavigation);
			else if (wordNavigation && event.key == UiKey.Up) changed = editor.moveCaretByParagraph(
				-1,
				extend,
				macWordNavigation);
			else if (wordNavigation && event.key == UiKey.Down) changed = editor.moveCaretByParagraph(1,
				extend,
				macWordNavigation);
			else if (multiline
				&& event.key == UiKey.PageUp) changed = editor.moveCaretVertically(latest().pageStep(editor,
				editorContent, -1),
				extend);
			else if (multiline
				&& event.key == UiKey.PageDown) changed = editor.moveCaretVertically(latest().pageStep(editor,
				editorContent, 1),
				extend);
			else if (multiline && event.key == UiKey.Up) changed = editor.moveCaretVertically(-1, extend);
			else if (multiline && event.key == UiKey.Down) changed = editor.moveCaretVertically(1, extend);
			#if (mac || ios)
			else if (event.modifiers.contains(UiModifier.Super) && event.key == UiKey.Up) changed = editor.placeCaret(0,
				extend);
			else if (event.modifiers.contains(UiModifier.Super)
				&& event.key == UiKey.Down) changed = editor.placeCaret(editor.documentLength(),
				extend);
			#end
			else if (event.key == UiKey.Left) changed = editor.moveCaret(-1, extend);
			else if (event.key == UiKey.Right) changed = editor.moveCaret(1, extend);
			else if (event.key == UiKey.Home) changed = multiline && !command ? editor.moveCaretToLineBoundary(false,
				extend) : editor.placeCaret(0,
				extend);
			else if (event.key == UiKey.End) changed = multiline && !command ? editor.moveCaretToLineBoundary(true,
				extend) : editor.placeCaret(editor.documentLength(),
				extend);
			else if (event.key == UiKey.Backspace) {
				if (readOnly) handled = false;
				else {
					changed = wordNavigation ? editor.deleteWord(-1, macWordNavigation) : editor.deleteBackward();
					textEdited = true;
				}
			} else if (event.key == UiKey.Delete) {
				if (readOnly) handled = false;
				else {
					changed = wordNavigation ? editor.deleteWord(1, macWordNavigation) : editor.deleteForward();
					textEdited = true;
				}
			} else if (event.key == UiKey.Enter) {
				if (multiline) {
					if (readOnly) handled = false;
					else {
						changed = editor.insert("\n");
						textEdited = true;
					}
				} else {
					var submit = latest().onSubmit;
					if (submit != null) submit(editor.layoutText());
				}
			} else handled = false;
			if (changed) {
				if (textEdited) publishTextChange(previousRevision);
				else updateState(!(command && event.key == UiKey.A));
			}
			if (handled) {
				editor.resetCaretBlink(Sys.time());
				event.preventDefault();
			} else if (!readOnly && !command && event.key.rawValue >= 32 && event.key.rawValue <= 96) {
				// The character itself arrives through the separate text-input event.
				event.markHandled();
			}
		};
		node.on(UiEventKind.KeyDown, handleKey);
		node.on(UiEventKind.KeyRepeat, handleKey);

		if (multiline && readOnly) node.on(UiEventKind.Scroll, function(event) {
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
			if (!enabled || readOnly || event.data == null) return;
			var edit:TextEdit = cast event.data;
			// Windows sends Backspace/Delete as both a key event and a text-edit
			// transaction. handleKey owns deletion; applying this transaction too
			// would delete a second character, potentially at a stale native caret.
			if (Sys.systemName() == "Windows" && edit.action == TextEditAction.Delete) return;
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
			if (!enabled || event.data == null) return;
			var request:AccessibilityActionData = cast event.data;
			if (editor.setSelection(request.selectionStart, request.selectionEnd)) {
				editor.resetCaretBlink(Sys.time());
				updateState();
			}
		});
		return node;
	}

	/** Publishes the focused caret and visible text-input geometry. */
	function syncCursor(editor:TextEditorState,
			context:BuildContext,
			id:haxeon.ui.core.WidgetId,
			geometry:ResolvedLayoutItem):Void {
		// Resolved callbacks run on every frame: without a focused editor or a listener, nobody uses the caret.
		if (!editor.focused && onCaretRect == null && onDiagnostics == null) return;
		var caret = editor.layout.caretAt(editor.selectionFocusLayoutOffset, editor.selectionFocusAffinity);
		var topX = geometry.x + caret.x + caret.ascender * caret.slope;
		var topY = geometry.y + caret.y + caret.ascender - editor.scrollOffsetY;
		var bottomX = geometry.x + caret.x + caret.descender * caret.slope;
		var bottomY = geometry.y + caret.y + caret.descender - editor.scrollOffsetY;
		var transform:Transform2D = cast geometry.transform;
		var screenTopX = transform.a * topX + transform.c * topY + transform.tx;
		var screenTopY = transform.b * topX + transform.d * topY + transform.ty;
		var screenBottomX = transform.a * bottomX + transform.c * bottomY + transform.tx;
		var screenBottomY = transform.b * bottomX + transform.d * bottomY + transform.ty;
		var caretRect = new Rect(Math.min(screenTopX, screenBottomX),
			Math.min(screenTopY, screenBottomY),
			Math.max(1.0, absolute(screenBottomX - screenTopX)),
			Math.max(1.0, absolute(screenBottomY - screenTopY)));
		var caretHandler = onCaretRect;
		if (caretHandler != null) {
			var clip = geometry.clipBounds;
			var visible = geometry.visible && caretRect.x < clip.x + clip.width
				&& caretRect.x + caretRect.width > clip.x
				&& caretRect.y < clip.y + clip.height && caretRect.y + caretRect.height > clip.y;
			caretHandler(visible ? caretRect : null);
		}
		// Passing an optional value to a listener is an escape boundary; avoid it when no listener exists.
		if (onDiagnostics != null) publishDiagnostics(editor, context, caretRect);
		if (!editor.focused
			|| !context.textInput.isOwner(id) || context.platformSurface == null || context.platformSurface.isDisposed()
			|| (context.textInput.platformChecked && !context.textInput.platformSupported)) return;
		// The field can be document-sized inside an ancestor ScrollView. Its
		// content height is not the viewport: only publish geometry inside
		// the resolved ancestor clip, converted back into local text space.
		var visible = geometry.visibleLocalBounds();
		var visibleTop = editor.scrollOffsetY + visible.y;
		var visibleBottom = visibleTop + visible.height;
		// The selection is reported clamped into the text-input window, and its rectangles must lie within what
		// is reported: those reaching past a clamped edge are left out.
		var window = editor.surroundingText(2048, 2048);
		var selectionGeometry:Array<TextRangeRect> = [];
		if (window.selectionStart != window.selectionEnd)
			for (rect in editor.layout.selectionRangeRects(editor.anchorPosition(),
				editor.focusPosition(),
				visibleTop,
				visibleBottom)) if (rect.start >= window.selectionStart
				&& rect.end <= window.selectionEnd) selectionGeometry.push(transformTextRangeRect(rect,
				geometry,
				transform,
				editor.scrollOffsetY));
		var compositionGeometry:Array<TextRangeRect> = [];
		for (rect in editor.compositionRangeRects(visibleTop,
			visibleBottom)) compositionGeometry.push(transformTextRangeRect(rect,
			geometry,
			transform,
			editor.scrollOffsetY));
		context.textInput.update(window,
			editor.documentLength(),
			window.selectionStart,
			window.selectionEnd,
			editor.compositionStart,
			editor.compositionEnd,
			0,
			multiline
			? nativekit.ffi.NativeKitTypes.TextInputFlags.Multiline
			: nativekit.ffi.NativeKitTypes.TextInputFlags.empty(),
			caretRect,
			selectionGeometry,
			compositionGeometry,
			imeAction);
	}

	function publishSelection(editor:TextEditorState):Void {
		var handler = onSelectionChange;
		if (handler != null) handler(new TextSelection(editor.selectionAnchor,
			editor.selectionFocus,
			editor.selectionAnchorAffinity,
			editor.selectionFocusAffinity));
	}

	function copyCurrentSelection(context:BuildContext, editor:TextEditorState):Bool {
		if (selectionTextProvider != null) {
			var selectedText = selectionTextProvider();
			if (selectedText == null) return false;
			context.clipboard.writeText(selectedText);
		} else {
			if (editor.selectionStart == editor.selectionEnd) return false;
			copySelection(context.clipboard, editor);
		}
		return true;
	}

	function publishDiagnostics(editor:TextEditorState, context:BuildContext, caretRect:Null<Rect>):Void {
		// The handler is read once: building the report calls into the editor, which may replace it.
		var diagnostics = onDiagnostics;
		if (diagnostics == null) return;
		var compositionText = editor.compositionStart >= 0
			&& editor.compositionEnd >= editor.compositionStart
			? editor.documentOffsets().sliceCodepoints(editor.compositionStart,
			editor.compositionEnd) : "";
		diagnostics(new TextEditorDiagnostics(key,
			label == null ? key : label,
			editor.focused,
			editor.selectionStart,
			editor.selectionEnd,
			editor.selectionFocus,
			editor.compositionStart,
			editor.compositionEnd,
			compositionText,
			caretRect,
			context.textInput.platformSupported,
			context.textInput.platformActive));
	}

	function pageStep(editor:TextEditorState, editorContent:RenderNode, direction:Int):Int {
		var height = pageHeightProvider
			!= null ? pageHeightProvider() : editorContent.resolved == null ? 0.0 : editorContent.resolved.height;
		var caret = editor.layout.caretAt(editor.selectionFocusLayoutOffset, editor.selectionFocusAffinity);
		var lineHeight = editor.layout.paragraphStyle.lineHeight;
		var step = lineHeight == null ? Math.abs(caret.descender - caret.ascender) : lineHeight;
		// Keep one line of overlap between consecutive pages.
		return direction * (Math.isFinite(height) && height > 0 ? Std.int(Math.max(1,
			Math.floor(height / Math.max(1.0, step)) - 1)) : 1);
	}

	/** Applies a wheel delta and re-pins to the tail when the view reaches the end again. */
	static function scrollReadOnly(editor:TextEditorState, deltaY:Float):Bool {
		var changed = editor.scrollBy(deltaY);
		if (changed) editor.tailFollowing = editor.isScrolledToEnd();
		return changed;
	}

	static function acquireState(context:BuildContext,
			id:haxeon.ui.core.WidgetId,
			value:String,
			textStyle:TextStyle,
			paragraphStyle:ParagraphStyle,
			document:Null<TextDocument>):State<TextEditorState> {
		if (context.fonts == null
			|| context.fonts.isDisposed()) throw "Text fields require fonts on their build context";
		if (context.stateStore.contains(id)) return context.existingState(id);
		var fonts = context.fonts;
		return context.resourceState(id, function() {
			return new TextEditorState(cast fonts, value, textStyle, paragraphStyle, document);
		}, function(editor:TextEditorState) {
			editor.dispose();
		});
	}

	static function copySelection(clipboard:haxeon.ui.core.ClipboardService, editor:TextEditorState):Void {
		if (editor.selectionStart != editor.selectionEnd)
			clipboard.writeText(editor.documentOffsets().sliceCodepoints(editor.selectionStart,
				editor.selectionEnd));
	}

	static function paintSelection(canvas:Canvas,
			editor:TextEditorState,
			active:Bool,
			theme:haxeon.ui.theme.Theme,
			additional:Array<TextSelection>,
			minY:Float,
			maxY:Float):Void {
		canvas.translate(0.0, -editor.scrollOffsetY);
		for (selection in additional)
			for (rect in editor.layout.selectionRects(new TextPosition(selection.anchor, selection.anchorAffinity),
				new TextPosition(selection.focus, selection.focusAffinity),
				minY,
				maxY)) canvas.fillRectIfPositive(rect,
				active ? theme.textSelection : theme.textSelectionInactive);
		if (editor.selectionStart != editor.selectionEnd) {
			for (rect in editor.layout.selectionRects(editor.anchorPosition(),
				editor.focusPosition(), minY, maxY)) canvas.fillRectIfPositive(rect,
				active ? theme.textSelection : theme.textSelectionInactive);
		}
	}

	static function paintEditorDecorations(canvas:Canvas,
			editor:TextEditorState,
			active:Bool,
			theme:haxeon.ui.theme.Theme,
			timeSeconds:Float,
			showCaret:Bool = true,
			?additional:Array<TextSelection>):Void {
		if (editor.scrollOffsetY != 0.0) canvas.translate(0.0, -editor.scrollOffsetY);
		if (active && editor.compositionStart >= 0 && editor.compositionStart != editor.compositionEnd) {
			for (rect in editor.compositionRects()) canvas.fillRectIfPositive(new Rect(rect.x,
				rect.y + rect.height - 1.0, rect.width, 1.0),
				Color.rgba(0.95, 0.75, 0.24, 1.0));
		}
		if (showCaret && active && additional != null
			&& editor.isCaretVisible(timeSeconds)) for (selection in additional) if (selection.anchor
			== selection.focus) {
			var caret = editor.layout.caretAt(selection.focus, selection.focusAffinity);
			var topX = caret.x + caret.ascender * caret.slope;
			var bottomX = caret.x + caret.descender * caret.slope;
			canvas.fillRectIfPositive(new Rect(Math.min(topX, bottomX),
				caret.y + Math.min(caret.ascender, caret.descender),
				Math.max(1.0, absolute(bottomX - topX)),
				Math.max(1.0, absolute(caret.descender - caret.ascender))),
				theme.textCaret);
		}
		if (showCaret && active && editor.selectionStart == editor.selectionEnd && editor.isCaretVisible(timeSeconds)) {
			var caret = editor.layout.caretAt(editor.selectionFocusLayoutOffset, editor.selectionFocusAffinity);
			var topX = caret.x + caret.ascender * caret.slope;
			var topY = caret.y + caret.ascender;
			var bottomX = caret.x + caret.descender * caret.slope;
			var bottomY = caret.y + caret.descender;
			var x = Math.min(topX, bottomX);
			var y = Math.min(topY, bottomY);
			var height = Math.max(1.0, absolute(bottomY - topY));
			canvas.fillRectIfPositive(new Rect(x, y, Math.max(1.0, absolute(bottomX - topX)), height), theme.textCaret);
		}
	}

	static inline function absolute(value:Float):Float return value < 0.0 ? -value : value;

	static function transformTextRangeRect(rect:TextRangeRect,
			geometry:ResolvedLayoutItem,
			transform:Transform2D,
			scrollOffsetY:Float):TextRangeRect {
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
		return new TextRangeRect(rect.start, rect.end, minX, minY, maxX - minX, maxY - minY, rect.visualLeftIsStart);
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

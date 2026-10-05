package haxeon.ui.widgets.text;

import haxeon.ui.TextLayout.TextCaret;
import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.TextLayout.TextRangeRect;

import nativekit.ffi.NativeKitTypes.TextEditAction;
import haxeon.ui.FontCollection;
import haxeon.ui.editing.EditHistory;
import haxeon.ui.editing.EditOperation;
import haxeon.ui.Color;
import haxeon.ui.TextColorRange;
import haxeon.ui.LayoutMeasureConstraints;
import haxeon.ui.LayoutMeasureResult;
import haxeon.ui.LayoutMeasuredContent;
import haxeon.ui.LayoutRenderableContent;
import haxeon.platform.NativeKitEventValue.NativeKitTextEdit;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.Rect;
import haxeon.ui.TextStyle;
import haxeon.editor.TextDocument;
import haxeon.editor.TextOffsetMap;

/** Persistent editable text, selection and IME composition state for one widget ID. */
class TextEditorState {
	static inline var caretBlinkHalfPeriod:Float = 0.5;
	// Real width arrives during measurement. Avoid a one-pixel provisional
	// layout that creates a visual line per character across large documents.
	static inline var initialLayoutWidth:Float = 1.0e30;

	public var text(get, never):String;
	public var selectionStart(default, null):Int;
	public var selectionEnd(default, null):Int;
	public var compositionStart(default, null):Int;
	public var compositionEnd(default, null):Int;
	public var selectionAnchor(default, null):Int;
	public var selectionFocus(default, null):Int;
	public var selectionAnchorLayoutOffset(default, null):Int;
	public var selectionFocusLayoutOffset(default, null):Int;
	public var selectionAnchorAffinity(default, null):Int;
	public var selectionFocusAffinity(default, null):Int;
	public var lastEditTransaction(default, null):Null<EditTransaction>;
	/** Vertical scroll offset in the editor's content coordinate space. */
	public var scrollOffsetY(default, null):Float;
	/** Read-only logs keep the newest text in view until the user scrolls away from the end. */
	public var tailFollowing:Bool = false;
	var tailEnabled:Bool = false;
	public var focused:Bool;
	public var draggingSelection:Bool;
	public final layout:TextEditorLayout;
	public final renderContent:LayoutRenderableContent;
	var presentationRevision:Int = -1;
	var surroundingWindow:Null<TextInputWindow>;
	var surroundingRevision:Int = -1;
	var surroundingDocument:Null<TextDocument>;
	public final textStyle:TextStyle;
	public final paragraphStyle:ParagraphStyle;
	/** Cached conversions between document code points, UTF-8 bytes and UTF-16 units. */
	var offsets:TextDocument;
	/** Measurement-only provider for widgets that place painting in separate layers. */
	public final renderMeasurement:LayoutMeasuredContent;
	var renderColor:Color;
	var lastLayoutWidth:Float;
	var lastLayoutRevision:Int;
	var lastPointerClickTime:Float;
	var lastPointerClickX:Float;
	var lastPointerClickY:Float;
	var lastPointerWordStart:Int;
	var lastPointerWordEnd:Int;
	var lastPointerClickCount:Int;
	var lastPointerClickArmed:Bool;
	var pointerClickPending:Bool;
	var viewportHeight:Float;
	var desiredVerticalX:Float;
	var hasDesiredVerticalX:Bool;
	var caretBlinkResetTime:Float;
	var disposed:Bool;
	var pointerGranularity:Int = 1;
	var pointerRangeStart:Int = 0;
	var pointerRangeEnd:Int = 0;
	public var historyEnabled:Bool = true;
	final history = new EditHistory(256, 2097152);
	var replayingHistory:Bool = false;
	var lastHistoryEdit:Null<FieldHistoryEdit>;

	public function configureHistory(enabled:Bool):Void {
		if (historyEnabled != enabled) { history.clear(); lastHistoryEdit = null; historyEnabled = enabled; }
	}

	public function breakHistoryGroup():Void { history.breakCoalescing(); lastHistoryEdit = null; }
	public function undo():Bool {
		ensureLive();
		if (offsets.revision != lastLayoutRevision) syncDocument(offsets);
		lastHistoryEdit = null;
		return historyEnabled && history.undo();
	}
	public function redo():Bool {
		ensureLive();
		if (offsets.revision != lastLayoutRevision) syncDocument(offsets);
		lastHistoryEdit = null;
		return historyEnabled && history.redo();
	}

	function replayHistory(edit:FieldHistoryEdit, backwards:Bool):Void {
		var removed = backwards ? edit.inserted : edit.removed;
		var inserted = backwards ? edit.removed : edit.inserted;
		var selection = backwards ? edit.before : edit.after;
		replayingHistory = true;
		try {
			applyTransaction(new EditTransaction(edit.start, edit.start + TextOffsetMap.countCodepoints(removed), inserted,
				Std.int(Math.min(selection.anchor, selection.focus)), Std.int(Math.max(selection.anchor, selection.focus)),
				false, -1, -1, selection.focusAffinity));
			setAnchoredSelection(selection);
		} catch (error:Dynamic) { replayingHistory = false; throw error; }
		replayingHistory = false;
	}

	function recordHistory(transaction:EditTransaction, before:TextSelection):Void {
		if (!historyEnabled || replayingHistory) return;
		var edit = new FieldHistoryEdit(transaction, before,
			new TextSelection(selectionAnchor, selectionFocus, selectionAnchorAffinity, selectionFocusAffinity));
		var previous = lastHistoryEdit;
		var compositionJoin = previous != null && previous.composing && edit.composition &&
			edit.start == previous.start && edit.removed == previous.inserted;
		var join = transaction.historyKind == TextEditorHistoryKind.Typing && previous != null &&
			previous.typing && edit.removed == "" && previous.removed == "" &&
			edit.start == previous.start + TextOffsetMap.countCodepoints(previous.inserted) &&
			edit.time - previous.time < 1.0 && previous.inserted.length + edit.inserted.length < 4096 &&
			previous.inserted.indexOf(" ") < 0 && edit.inserted.indexOf(" ") < 0 &&
			previous.inserted.indexOf("\n") < 0 && edit.inserted.indexOf("\n") < 0;
		join = join || compositionJoin;
		if (!join) history.breakCoalescing();
		var bytes = 256 + (edit.removed.length + edit.inserted.length) * 4;
		if (join && previous != null) bytes += 256 + (previous.removed.length + previous.inserted.length) * 4;
		if (bytes > history.maxEstimatedBytes) { history.clear(); lastHistoryEdit = null; return; }
		history.record(new EditOperation("Edit text", function() replayHistory(edit, false),
			function() replayHistory(edit, true), edit.typing ? "typing" : edit.composition ? "composition" : null, function(next) {
				var following:FieldHistoryEdit = cast next.mergeData;
				edit.inserted = edit.composition ? following.inserted : edit.inserted + following.inserted;
				edit.composing = following.composing;
				edit.after = following.after;
				edit.time = following.time;
				return true;
			}, edit, bytes));
		lastHistoryEdit = join ? previous : edit;
	}


	public function new(fonts:FontCollection, text:String, ?textStyle:TextStyle,
			?paragraphStyle:ParagraphStyle, ?document:TextDocument) {
		if (fonts == null || fonts.isDisposed())
			throw "Text editor requires a live font collection";
		var initialText = text == null ? "" : text;
		offsets = document == null ? new TextDocument(initialText) : document;
		this.textStyle = copyTextStyle(textStyle == null ? new TextStyle() : textStyle);
		this.paragraphStyle = copyParagraphStyle(paragraphStyle == null ? new ParagraphStyle() : paragraphStyle);
		var end = offsets.codepointCount;
		selectionStart = end;
		selectionEnd = end;
		selectionAnchor = end;
		selectionFocus = end;
		selectionAnchorLayoutOffset = end;
		selectionFocusLayoutOffset = end;
		selectionAnchorAffinity = 0;
		selectionFocusAffinity = 0;
		lastEditTransaction = null;
		scrollOffsetY = 0.0;
		compositionStart = -1;
		compositionEnd = -1;
		focused = false;
		draggingSelection = false;
		layout = new TextEditorLayout(fonts, initialText, initialLayoutWidth, this.textStyle,
			this.paragraphStyle, offsets);
		renderColor = Color.rgba(1.0, 1.0, 1.0, 1.0);
		renderMeasurement = new LayoutMeasuredContent(function(constraints:LayoutMeasureConstraints) {
			if (Math.isFinite(constraints.maxWidth) && constraints.maxWidth > 0.0)
				updateLayout(constraints.maxWidth);
			return layout.measureForConstraints(constraints);
		});
		renderContent = new LayoutRenderableContent(renderMeasurement, function(canvas, geometry) {
			var visible = geometry.visibleLocalBounds();
			canvas.translate(0.0, -scrollOffsetY);
			layout.paint(canvas, renderColor, scrollOffsetY + visible.y,
				scrollOffsetY + visible.y + visible.height, visible.x, visible.x + visible.width, false);
		});
		lastLayoutWidth = initialLayoutWidth;
		lastLayoutRevision = offsets.revision;
		lastPointerClickTime = -1.0;
		lastPointerClickX = 0.0;
		lastPointerClickY = 0.0;
		lastPointerWordStart = -1;
		lastPointerWordEnd = -1;
		lastPointerClickCount = 0;
		lastPointerClickArmed = false;
		pointerClickPending = false;
		viewportHeight = 0.0;
		desiredVerticalX = 0.0;
		hasDesiredVerticalX = false;
		caretBlinkResetTime = 0.0;
		disposed = false;
	}

	public function syncExternal(value:String):Bool {
		ensureLive();
		var next = value == null ? "" : value;
		if (next == offsets.text)
			return false;
		history.clear(); lastHistoryEdit = null;
		cancelPointerClick();
		offsets.replace(0, offsets.codepointCount, next);
		var caret = offsets.codepointCount;
		selectionStart = caret;
		selectionEnd = caret;
		selectionAnchor = caret;
		selectionFocus = caret;
		selectionAnchorLayoutOffset = caret;
		selectionFocusLayoutOffset = caret;
		selectionAnchorAffinity = 0;
		selectionFocusAffinity = 0;
		resetVerticalNavigation();
		clearComposition();
		layout.updateDocument(offsets, Math.max(1.0, lastLayoutWidth), textStyle, paragraphStyle);
		renderMeasurement.invalidate();
		lastLayoutRevision = offsets.revision;
		return true;
	}

	/** Uses a caller-owned document as the source of truth for this editor. */
	/** Presentation callbacks may change without text or measurement changing. */
	public function configurePresentation(foreground:Null<(Int, Int)->Array<TextColorRange>>,
			decorations:Null<(Int, Int)->Array<TextDecoration>>, revision:Int):Void {
		ensureLive();
		if (revision != presentationRevision || foreground != layout.colorRangeProvider ||
			decorations != layout.decorationProvider)
			renderContent.invalidatePaint();
		layout.colorRangeProvider = foreground;
		layout.decorationProvider = decorations;
		presentationRevision = revision;
	}

	public function syncDocument(document:TextDocument):Bool {
		ensureLive();
		if (document == null)
			throw "Text editor document cannot be null";
		if (offsets == document && offsets.revision == lastLayoutRevision)
			return false;
		history.clear(); lastHistoryEdit = null;
		cancelPointerClick();
		if (offsets != document) {
			offsets = document;
			var caret = offsets.codepointCount;
			setSelection(caret, caret);
			clearComposition();
		} else {
			setSelection(clamp(selectionStart, 0, offsets.codepointCount),
				clamp(selectionEnd, 0, offsets.codepointCount));
			clearComposition();
		}
		layout.updateDocument(offsets, Math.max(1.0, lastLayoutWidth), textStyle, paragraphStyle);
		renderMeasurement.invalidate();
		lastLayoutRevision = offsets.revision;
		clampScrollOffset();
		return true;
	}

	public function updateLayout(width:Float):Void {
		ensureLive();
		var nextWidth = Math.max(1.0, width);
		if (nextWidth != lastLayoutWidth || offsets.revision != lastLayoutRevision) {
			layout.updateDocument(offsets, nextWidth, textStyle, paragraphStyle);
			renderMeasurement.invalidate();
			lastLayoutWidth = nextWidth;
			lastLayoutRevision = offsets.revision;
		}
		clampScrollOffset();
	}

	/** Updates inherited typography without replacing the retained editor state. */
	public function updateStyle(nextTextStyle:TextStyle, nextParagraphStyle:ParagraphStyle):Bool {
		ensureLive();
		if (nextTextStyle == null || nextParagraphStyle == null)
			throw "Text editor styles cannot be null";
		var changed = textStyle.font != nextTextStyle.font ||
			textStyle.fontSize != nextTextStyle.fontSize ||
			textStyle.letterSpacing != nextTextStyle.letterSpacing ||
			paragraphStyle.wrap != nextParagraphStyle.wrap ||
			paragraphStyle.alignment != nextParagraphStyle.alignment ||
			paragraphStyle.lineHeight != nextParagraphStyle.lineHeight ||
			paragraphStyle.direction != nextParagraphStyle.direction;
		if (!changed)
			return false;
		textStyle.font = nextTextStyle.font;
		textStyle.fontSize = nextTextStyle.fontSize;
		textStyle.letterSpacing = nextTextStyle.letterSpacing;
		paragraphStyle.wrap = nextParagraphStyle.wrap;
		paragraphStyle.alignment = nextParagraphStyle.alignment;
		paragraphStyle.lineHeight = nextParagraphStyle.lineHeight;
		paragraphStyle.direction = nextParagraphStyle.direction;
		layout.updateDocument(offsets, Math.max(1.0, lastLayoutWidth), textStyle, paragraphStyle);
		renderMeasurement.invalidate();
		lastLayoutRevision = offsets.revision;
		clampScrollOffset();
		return true;
	}

	/** Inserts committed text over the current selection. */
	public function insert(value:String, kind:TextEditorHistoryKind = TextEditorHistoryKind.Typing):Bool {
		if (value == null || value.length == 0)
			return false;
		return replace(selectionStart, selectionEnd, value, kind);
	}

	/** Replaces a code-point range and places a collapsed caret after the insertion. */
	public function replace(start:Int, end:Int, value:String, kind:TextEditorHistoryKind = TextEditorHistoryKind.Generic):Bool {
		ensureLive();
		var count = offsets.codepointCount;
		var first = clamp(start, 0, count);
		var last = clamp(end, 0, count);
		if (last < first) {
			var swap = first;
			first = last;
			last = swap;
		}
		var caret = first + TextOffsetMap.countCodepoints(value == null ? "" : value);
		return applyTransaction(new EditTransaction(first, last, value, caret, caret, false, -1, -1, 0, null, kind));
	}

	/** Applies one replacement and its resulting selection and composition together. */
	public function applyTransaction(transaction:EditTransaction):Bool {
		ensureLive();
		if (transaction == null) return false;
		lastEditTransaction = null;
		var historyBefore = new TextSelection(selectionAnchor, selectionFocus, selectionAnchorAffinity, selectionFocusAffinity);
		var count = offsets.codepointCount;
		var first = clamp(transaction.replacementStart, 0, count);
		var last = clamp(transaction.replacementEnd, 0, count);
		if (last < first) {
			var swap = first;
			first = last;
			last = swap;
		}
		var replacement = transaction.replacementText == null ? "" : transaction.replacementText;
		var replacedText = offsets.sliceCodepoints(first, last);
		var textChanged = replacedText != replacement;
		var previousStart = selectionStart;
		var previousEnd = selectionEnd;
		var previousCompositionStart = compositionStart;
		var previousCompositionEnd = compositionEnd;
		var previousAnchorAffinity = selectionAnchorAffinity;
		var previousFocusAffinity = selectionFocusAffinity;
		if (textChanged) {
			var oldDocumentLength = offsets.codepointCount;
			cancelPointerClick();
			offsets.replace(first, last, replacement);
			var newEnd = first + TextOffsetMap.countCodepoints(replacement);
			layout.setTextAfterEdit(offsets, first, last, first, newEnd,
				oldDocumentLength);
			renderMeasurement.invalidate();
			lastLayoutRevision = offsets.revision;
		}
		setSelection(transaction.selectionStart, transaction.selectionEnd,
			transaction.selectionAffinity);
		if (transaction.hasComposition && transaction.compositionStart >= 0 &&
			transaction.compositionEnd >= transaction.compositionStart)
			setComposition(transaction.compositionStart, transaction.compositionEnd);
		else
			clearComposition();
		if (textChanged)
			lastEditTransaction = new EditTransaction(first, last, replacement,
				selectionStart, selectionEnd, compositionStart >= 0, compositionStart,
				compositionEnd, selectionFocusAffinity, transaction.compositionAttributes,
				transaction.historyKind, replacedText);
		var appliedEdit = lastEditTransaction;
		if (textChanged && appliedEdit != null) recordHistory(appliedEdit, historyBefore);
		if (!transaction.hasComposition && transaction.historyKind == TextEditorHistoryKind.Composition) breakHistoryGroup();
		return textChanged || previousStart != selectionStart || previousEnd != selectionEnd ||
			previousAnchorAffinity != selectionAnchorAffinity ||
			previousFocusAffinity != selectionFocusAffinity ||
			previousCompositionStart != compositionStart || previousCompositionEnd != compositionEnd;
	}

	public function documentOffsets():TextDocument {
		ensureLive();
		return offsets;
	}

	public function setRenderColor(color:Color):Void {
		ensureLive();
		if (color == null)
			return;
		if (renderColor.red == color.red && renderColor.green == color.green &&
			renderColor.blue == color.blue && renderColor.alpha == color.alpha)
			return;
		renderColor = color;
		renderMeasurement.invalidate();
	}

	public function documentLength():Int {
		ensureLive();
		return offsets.codepointCount;
	}

	public function documentRevision():Int {
		ensureLive();
		return offsets.revision;
	}

	/** Returns surrounding text while keeping selection and composition in the window. */
	public function surroundingText(maxBefore:Int, maxAfter:Int):TextInputWindow {
		ensureLive();
		var first = selectionStart;
		var last = selectionEnd;
		if (compositionStart >= 0 && compositionEnd >= compositionStart) {
			first = Std.int(Math.min(first, compositionStart));
			last = Std.int(Math.max(last, compositionEnd));
		}
		var start = Std.int(Math.max(0, first - Std.int(Math.max(0, maxBefore))));
		var end = Std.int(Math.min(offsets.codepointCount, last + Std.int(Math.max(0, maxAfter))));
		if (surroundingWindow != null && surroundingDocument == offsets && surroundingRevision == offsets.revision &&
			surroundingWindow.start == start && surroundingWindow.end == end) return surroundingWindow;
		surroundingDocument = offsets;
		surroundingRevision = offsets.revision;
		surroundingWindow = new TextInputWindow(offsets.sliceCodepoints(start, end), start, end);
		return surroundingWindow;
	}

	/** Applies one transactional NativeKit composition/edit update. */
	public function applyTextEdit(edit:NativeKitTextEdit):Bool {
		ensureLive();
		if (edit == null)
			return false;
		var historyKind = textEditHistoryKind(edit.historyKind);
		if (historyKind == TextEditorHistoryKind.Generic &&
			(edit.action == TextEditAction.Compose ||
				(edit.action == TextEditAction.Commit && compositionStart >= 0)))
			historyKind = TextEditorHistoryKind.Composition;
		var previousStart = selectionStart;
		var previousEnd = selectionEnd;
		var previousCompositionStart = compositionStart;
		var previousCompositionEnd = compositionEnd;
		var previousAnchorAffinity = selectionAnchorAffinity;
		var previousFocusAffinity = selectionFocusAffinity;
		switch (edit.action) {
			case TextEditAction.Compose | TextEditAction.Commit | TextEditAction.Delete:
				return applyTransaction(new EditTransaction(edit.replaceStart, edit.replaceEnd,
					edit.action == TextEditAction.Delete ? "" : edit.text,
					edit.selectionStart, edit.selectionEnd, edit.action == TextEditAction.Compose,
					edit.compositionStart, edit.compositionEnd, edit.selectionAffinity,
					null, historyKind));
			case TextEditAction.SetSelection:
				setSelection(edit.selectionStart, edit.selectionEnd, edit.selectionAffinity);
				setComposition(edit.compositionStart, edit.compositionEnd);
			case TextEditAction.SetComposition:
				setComposition(edit.compositionStart, edit.compositionEnd);
			case TextEditAction.FinishComposition:
				breakHistoryGroup();
				clearComposition();
				setSelection(edit.selectionStart, edit.selectionEnd, edit.selectionAffinity);
			case _:
				return false;
		}
		return previousStart != selectionStart || previousEnd != selectionEnd ||
			previousAnchorAffinity != selectionAnchorAffinity ||
			previousFocusAffinity != selectionFocusAffinity ||
			previousCompositionStart != compositionStart || previousCompositionEnd != compositionEnd;
	}

	/** Imports an external anchored selection only when its logical value differs. */
	public function setAnchoredSelection(value:TextSelection):Bool {
		ensureLive();
		if (value == null) throw "Anchored selection is required";
		if (value.anchor == selectionAnchor && value.focus == selectionFocus &&
			value.anchorAffinity == selectionAnchorAffinity && value.focusAffinity == selectionFocusAffinity)
			return false;
		placeCaret(value.anchor, false, value.anchorAffinity);
		placeCaret(value.focus, true, value.focusAffinity);
		resetCaretBlink(Sys.time());
		return true;
	}

	public function setSelection(start:Int, end:Int, ?focusAffinity:Int = 0):Bool {
		ensureLive();
		var count = offsets.codepointCount;
		var first = clamp(start, 0, count);
		var last = clamp(end, 0, count);
		if (first > last) {
			var swap = first;
			first = last;
			last = swap;
		}
		var changed = first != selectionStart || last != selectionEnd ||
			selectionAnchor != first || selectionFocus != last ||
			selectionAnchorLayoutOffset != first || selectionFocusLayoutOffset != last ||
			selectionAnchorAffinity != (first == last ? focusAffinity : 0) ||
			selectionFocusAffinity != focusAffinity;
		selectionStart = first;
		selectionEnd = last;
		selectionAnchor = first;
		selectionFocus = last;
		selectionAnchorLayoutOffset = first;
		selectionFocusLayoutOffset = last;
		selectionAnchorAffinity = first == last ? focusAffinity : 0;
		selectionFocusAffinity = focusAffinity;
		resetVerticalNavigation();
		return changed;
	}

	static function textEditHistoryKind(value:Int):TextEditorHistoryKind {
		return switch (value) {
			case 1: TextEditorHistoryKind.Typing;
			case 2: TextEditorHistoryKind.DeleteBackward;
			case 3: TextEditorHistoryKind.DeleteForward;
			case 4: TextEditorHistoryKind.Paste;
			case 5: TextEditorHistoryKind.Autocorrect;
			case 6: TextEditorHistoryKind.Composition;
			case _: TextEditorHistoryKind.Generic;
		};
	}

	public function selectAll():Bool {
		breakHistoryGroup();
		var first = selectionStart != 0 || selectionEnd != offsets.codepointCount ||
			selectionAnchor != 0 || selectionFocus != offsets.codepointCount ||
			selectionAnchorLayoutOffset != 0 ||
			selectionFocusLayoutOffset != offsets.codepointCount ||
			selectionAnchorAffinity != 0 || selectionFocusAffinity != 0;
		selectionAnchor = 0;
		selectionFocus = offsets.codepointCount;
		selectionAnchorLayoutOffset = 0;
		selectionFocusLayoutOffset = selectionFocus;
		selectionStart = 0;
		selectionEnd = selectionFocus;
		selectionAnchorAffinity = 0;
		selectionFocusAffinity = 0;
		resetVerticalNavigation();
		return first;
	}

	/** Places a caret and optionally extends the existing anchored selection. */
	public function placeCaret(offset:Int, extend:Bool, affinity:Int = 0):Bool {
		ensureLive();
		breakHistoryGroup();
		resetVerticalNavigation();
		var next = clamp(layout.alignGrapheme(clamp(offset, 0, offsets.codepointCount)),
			0, offsets.codepointCount);
		var previousFocusLayoutOffset = selectionFocusLayoutOffset;
		var previousAnchorLayoutOffset = selectionAnchorLayoutOffset;
		if (!extend) {
			selectionAnchor = next;
			selectionAnchorLayoutOffset = next;
			selectionAnchorAffinity = affinity;
		} else if (selectionStart == selectionEnd) {
			selectionAnchor = selectionFocus;
			selectionAnchorLayoutOffset = previousFocusLayoutOffset;
			selectionAnchorAffinity = selectionFocusAffinity;
		}
		selectionFocus = next;
		selectionFocusLayoutOffset = next;
		var changed = selectionAnchorLayoutOffset != previousAnchorLayoutOffset ||
			selectionFocusLayoutOffset != previousFocusLayoutOffset ||
			selectionAnchorAffinity != affinity || selectionFocusAffinity != affinity;
		selectionFocusAffinity = affinity;
		var first = selectionAnchor < next ? selectionAnchor : next;
		var last = selectionAnchor > next ? selectionAnchor : next;
		changed = changed || first != selectionStart || last != selectionEnd;
		selectionStart = first;
		selectionEnd = last;
		return changed;
	}

	/** Moves by grapheme; a non-extended move collapses an existing selection first. */
	public function moveCaret(direction:Int, extend:Bool):Bool {
		ensureLive();
		if (direction == 0)
			return false;
		resetVerticalNavigation();
		var next:Int;
		if (!extend && selectionStart != selectionEnd)
			next = direction < 0 ? selectionStart : selectionEnd;
		else
			next = direction < 0 ? layout.previousGrapheme(selectionFocus) : layout.nextGrapheme(selectionFocus);
		cancelPointerClick();
		return moveFocusTo(next, extend);
	}

	/** Moves by Skribidi word boundaries; direction is -1 or +1. */
	public function moveCaretByWord(direction:Int, extend:Bool, macStyle:Bool = false):Bool {
		ensureLive();
		if (direction == 0)
			return false;
		resetVerticalNavigation();
		var next = !extend && selectionStart != selectionEnd
			? (direction < 0 ? selectionStart : selectionEnd)
			: layout.moveWord(selectionFocus, direction, macStyle);
		cancelPointerClick();
		return moveFocusTo(next, extend);
	}

	/** Moves by paragraph for Control+Up/Down or macOS Option+Up/Down. */
	public function moveCaretByParagraph(direction:Int, extend:Bool,
			macStyle:Bool = false):Bool {
		ensureLive();
		if (direction == 0)
			return false;
		resetVerticalNavigation();
		var next = !extend && selectionStart != selectionEnd
			? (direction < 0 ? selectionStart : selectionEnd)
			: layout.moveParagraph(selectionFocus, direction, macStyle);
		cancelPointerClick();
		return moveFocusTo(next, extend);
	}

	/** Moves to the nearest visual line while preserving the requested x column. */
	public function moveCaretVertically(direction:Int, extend:Bool):Bool {
		ensureLive();
		if (direction == 0)
			return false;
		if (!extend && selectionStart != selectionEnd) {
			resetVerticalNavigation();
			return moveFocusTo(direction < 0 ? selectionStart : selectionEnd, false);
		}

		var current = focusPosition();
		var currentCaret = layout.caret(current);
		if (!hasDesiredVerticalX) {
			desiredVerticalX = currentCaret.x;
			hasDesiredVerticalX = true;
		}
		var lineStep = paragraphStyle.lineHeight == null ?
			absolute(currentCaret.descender - currentCaret.ascender) : paragraphStyle.lineHeight;
		lineStep = Math.max(1.0, lineStep);

		var candidate:TextPosition = null;
		var candidateCaret:TextCaret = null;
		// Hit testing at the next baseline handles wrapped visual lines and keeps
		// the shaping engine's bidi affinity. A small widening probe is useful at
		// line boundaries where hit testing deliberately favors the current line.
		for (probe in 0...5) {
			var distance = lineStep * (1.0 + probe * 0.25);
			var hit = layout.hitTest(desiredVerticalX, currentCaret.y + direction * distance);
			var hitCaret = layout.caret(hit);
			if ((direction < 0 && hitCaret.y < currentCaret.y - 0.01) ||
				(direction > 0 && hitCaret.y > currentCaret.y + 0.01)) {
				candidate = hit;
				candidateCaret = hitCaret;
				break;
			}
		}
		if (candidate == null || candidateCaret == null)
			return false;

		var currentRange = layout.lineRangeAt(current.offset);
		var candidateRange = layout.lineRangeAt(candidate.offset);
		if (currentRange.start == candidateRange.start && currentRange.end == candidateRange.end)
			return false;
		cancelPointerClick();
		var changed = placeCaretAt(candidate, extend);
		// placeCaretAt resets navigation state as a normal horizontal/pointer
		// move would. Restore the column for a continued up/down sequence.
		hasDesiredVerticalX = true;
		return changed;
	}

	/** Moves to the start or end of the current visual line. */
	public function moveCaretToLineBoundary(endOfLine:Bool, extend:Bool):Bool {
		ensureLive();
		var range = layout.lineRangeAt(selectionFocusLayoutOffset);
		var target = endOfLine ? trimLineBreak(range.end, range.start) : range.start;
		resetVerticalNavigation();
		return placeCaret(target, extend);
	}

	/** Enables or disables tail following; enabling it starts pinned to the end. */
	public function configureTail(enabled:Bool):Void {
		if (enabled == tailEnabled)
			return;
		tailEnabled = enabled;
		tailFollowing = enabled;
	}

	/** Records the viewport height without moving the scroll position to reveal the caret. */
	public function setViewportHeight(height:Float):Void {
		ensureLive();
		if (!Math.isFinite(height) || height <= 0.0 || viewportHeight == height)
			return;
		viewportHeight = height;
		renderMeasurement.invalidate();
		clampScrollOffset();
	}

	/** Scrolls the viewport by a wheel delta, without disturbing the selection. */
	public function scrollBy(delta:Float):Bool {
		ensureLive();
		if (viewportHeight <= 0.0)
			return false;
		var maximum = Math.max(0.0, layout.measure().height - viewportHeight);
		var next = clampFloat(scrollOffsetY + delta, 0.0, maximum);
		if (next == scrollOffsetY)
			return false;
		scrollOffsetY = next;
		renderMeasurement.invalidate();
		return true;
	}

	public function isScrolledToEnd():Bool {
		ensureLive();
		if (viewportHeight <= 0.0)
			return true;
		return scrollOffsetY >= Math.max(0.0, layout.measure().height - viewportHeight) - 0.5;
	}

	public function scrollToEnd():Bool {
		ensureLive();
		if (viewportHeight <= 0.0)
			return false;
		var maximum = Math.max(0.0, layout.measure().height - viewportHeight);
		if (scrollOffsetY == maximum)
			return false;
		scrollOffsetY = maximum;
		renderMeasurement.invalidate();
		return true;
	}

	/** Adjusts internal scrolling so the active caret or selection remains in the viewport. */
	public function ensureCaretVisible(height:Float):Bool {
		ensureLive();
		if (!Math.isFinite(height) || height <= 0.0)
			return false;
		if (viewportHeight != height)
			renderMeasurement.invalidate();
		viewportHeight = height;
		var metrics = layout.measure();
		var contentHeight = Math.max(height, metrics.height);
		var caret = layout.caret(focusPosition());
		var top = caret.y + Math.min(caret.ascender, caret.descender);
		var bottom = caret.y + Math.max(caret.ascender, caret.descender);
		if (selectionStart != selectionEnd) {
			var selectionTop = top;
			var selectionBottom = bottom;
			for (rect in layout.selectionRects(anchorPosition(), focusPosition())) {
				selectionTop = Math.min(selectionTop, rect.y);
				selectionBottom = Math.max(selectionBottom, rect.y + rect.height);
			}
			// A selection can be taller than the viewport. In that case both
			// endpoints cannot be shown simultaneously, so keep the active focus
			// visible instead of jumping away from it.
			if (selectionBottom - selectionTop <= height) {
				top = selectionTop;
				bottom = selectionBottom;
			}
		}
		var next = scrollOffsetY;
		if (top < next)
			next = top;
		else if (bottom > next + height)
			next = bottom - height;
		var maximum = Math.max(0.0, contentHeight - height);
		next = clampFloat(next, 0.0, maximum);
		if (next == scrollOffsetY)
			return false;
		scrollOffsetY = next;
		renderMeasurement.invalidate();
		return true;
	}

	function moveFocusTo(next:Int, extend:Bool):Bool {
		breakHistoryGroup();
		var previousFocusLayoutOffset = selectionFocusLayoutOffset;
		var wasCollapsed = selectionStart == selectionEnd;
		if (!extend) {
			selectionAnchor = next;
			selectionAnchorLayoutOffset = next;
		} else if (wasCollapsed) {
			selectionAnchor = selectionFocus;
			selectionAnchorLayoutOffset = previousFocusLayoutOffset;
		}
		var first = extend ? (selectionAnchor < next ? selectionAnchor : next) : next;
		var last = extend ? (selectionAnchor > next ? selectionAnchor : next) : next;
		var changed = first != selectionStart || last != selectionEnd ||
			selectionFocusLayoutOffset != next || selectionFocusAffinity != 0;
		selectionFocus = next;
		selectionFocusLayoutOffset = next;
		selectionFocusAffinity = 0;
		if (!extend) {
			selectionAnchorAffinity = 0;
		}
		selectionStart = first;
		selectionEnd = last;
		return changed;
	}

	public function deleteBackward():Bool {
		if (selectionStart != selectionEnd)
			return replace(selectionStart, selectionEnd, "");
		if (selectionStart == 0)
			return false;
		var previous = layout.previousGrapheme(selectionStart);
		return replace(previous, selectionStart, "");
	}

	/** Deletes a selection or one shaped word as a single edit. */
	public function deleteWord(direction:Int, macStyle:Bool = false):Bool {
		ensureLive();
		if (direction != -1 && direction != 1) throw "Word deletion direction must be -1 or 1";
		if (selectionStart != selectionEnd) return replace(selectionStart, selectionEnd, "");
		var other = layout.moveWord(selectionFocus, direction, macStyle);
		return replace(Std.int(Math.min(other, selectionFocus)),
			Std.int(Math.max(other, selectionFocus)), "");
	}

	public function deleteForward():Bool {
		var length = offsets.codepointCount;
		if (selectionStart != selectionEnd)
			return replace(selectionStart, selectionEnd, "");
		if (selectionEnd >= length)
			return false;
		var next = layout.nextGrapheme(selectionEnd);
		return replace(selectionEnd, next, "");
	}

	public function hitTest(x:Float, y:Float):TextPosition {
		ensureLive();
		var hit = layout.hitTest(x, y);
		return new TextPosition(layout.alignGrapheme(hit.offset), hit.affinity);
	}

	/** Places the caret from a shaping-engine hit while keeping its visual affinity. */
	public function placeCaretAt(position:TextPosition, extend:Bool):Bool {
		ensureLive();
		resetVerticalNavigation();
		if (position == null)
			return false;
		var previousFocusLayoutOffset = selectionFocusLayoutOffset;
		var previousFocusAffinity = selectionFocusAffinity;
		var wasCollapsed = selectionStart == selectionEnd;
		var next = layout.offsetFromPosition(position);
		var changed = placeCaret(next, extend, position.affinity);
		selectionFocusLayoutOffset = position.offset;
		if (!extend)
			selectionAnchorLayoutOffset = position.offset;
		else if (wasCollapsed) {
			selectionAnchorLayoutOffset = previousFocusLayoutOffset;
			selectionAnchorAffinity = previousFocusAffinity;
		}
		return changed || previousFocusLayoutOffset != selectionFocusLayoutOffset;
	}

	public function focusPosition():TextPosition
		return new TextPosition(selectionFocusLayoutOffset, selectionFocusAffinity);

	public function anchorPosition():TextPosition
		return new TextPosition(selectionAnchorLayoutOffset, selectionAnchorAffinity);

	/** Restarts the caret blink after keyboard, pointer, or text-edit activity. */
	public function resetCaretBlink(timeSeconds:Float):Void {
		if (finite(timeSeconds))
			caretBlinkResetTime = Math.max(0.0, timeSeconds);
	}

	/** Returns whether the focused caret should be painted at the given UI time. */
	public function isCaretVisible(timeSeconds:Float):Bool {
		if (!focused || !finite(timeSeconds))
			return false;
		var elapsed = Math.max(0.0, timeSeconds - caretBlinkResetTime);
		return Std.int(elapsed / caretBlinkHalfPeriod) % 2 == 0;
	}

	/** Wall-clock deadline for the next caret visibility change. */
	public function nextCaretBlinkTime(timeSeconds:Float):Float {
		if (!focused || !finite(timeSeconds)) return -1.0;
		var elapsed = Math.max(0.0, timeSeconds - caretBlinkResetTime);
		return caretBlinkResetTime + (Math.floor(elapsed / caretBlinkHalfPeriod) + 1.0)
			* caretBlinkHalfPeriod;
	}

	/** Returns the shaped rectangles used to paint the active IME preedit underline. */
	public function compositionRects():Array<Rect> {
		if (compositionStart < 0 || compositionEnd <= compositionStart)
			return [];
		return layout.selectionRects(new TextPosition(compositionStart, 0),
			new TextPosition(compositionEnd, 0));
	}

	/** Returns active composition rectangles paired with absolute document ranges. */
	public function compositionRangeRects(minY:Float = -1.0e30,
			maxY:Float = 1.0e30):Array<TextRangeRect> {
		ensureLive();
		if (compositionStart < 0 || compositionEnd <= compositionStart)
			return [];
		return layout.selectionRangeRects(new TextPosition(compositionStart, 0),
			new TextPosition(compositionEnd, 0), minY, maxY);
	}

	/** Selects the word under a pointer position using the shaped text engine's boundaries. */
	public function selectWordAt(position:TextPosition):Bool {
		ensureLive();
		if (position == null || offsets.codepointCount == 0)
			return false;
		var range = layout.wordRange(position);
		return setSelection(range[0], range[1]);
	}

	/** Selects the visual line under a pointer position. */
	public function selectLineAt(position:TextPosition):Bool {
		ensureLive();
		if (position == null || offsets.codepointCount == 0)
			return false;
		var range = layout.lineRangeAt(position.offset);
		return setSelection(range.start, range.end);
	}

	/** Retains the original word/line so dragging extends whole semantic units. */
	public function beginPointerSelection(position:TextPosition, clicks:Int, extend:Bool):Bool {
		pointerGranularity = extend ? 1 : clicks;
		var changed = switch pointerGranularity {
			case 2: selectWordAt(position);
			case 3: selectLineAt(position);
			case _: placeCaretAt(position, extend);
		};
		pointerRangeStart = selectionStart;
		pointerRangeEnd = selectionEnd;
		return changed;
	}

	public function extendPointerSelection(position:TextPosition):Bool {
		if (pointerGranularity == 1) return placeCaretAt(position, true);
		var first:Int; var last:Int;
		if (pointerGranularity == 2) {
			var word = layout.wordRange(position); first = word[0]; last = word[1];
		} else {
			var line = layout.lineRangeAt(position.offset); first = line.start; last = line.end;
		}
		return setAnchoredSelection(first < pointerRangeStart
			? new TextSelection(pointerRangeEnd, first)
			: new TextSelection(pointerRangeStart, last));
	}

	/** Returns 1 for a single click, 2 for a double click, and 3 for a triple click. */
	public function registerPointerClick(position:TextPosition, timestamp:Float,
			x:Float, y:Float):Int {
		ensureLive();
		if (position == null || !finite(timestamp) || !finite(x) || !finite(y)) {
			cancelPointerClick();
			return 1;
		}
		var range = layout.wordRange(position);
		var dx = x - lastPointerClickX;
		var dy = y - lastPointerClickY;
		var sameSequence = lastPointerClickTime >= 0.0 && timestamp >= lastPointerClickTime &&
			timestamp - lastPointerClickTime <= 0.5 && range[0] == lastPointerWordStart &&
			range[1] == lastPointerWordEnd && dx * dx + dy * dy <= 36.0 && lastPointerClickArmed;
		lastPointerClickCount = sameSequence
			? (lastPointerClickCount >= 3 ? 1 : lastPointerClickCount + 1)
			: 1;
		lastPointerClickTime = timestamp;
		lastPointerClickX = x;
		lastPointerClickY = y;
		lastPointerWordStart = range[0];
		lastPointerWordEnd = range[1];
		lastPointerClickArmed = false;
		pointerClickPending = true;
		return lastPointerClickCount;
	}

	/** Arms a click for a possible double click only after a nearby pointer release. */
	public function completePointerClick(x:Float, y:Float):Void {
		if (!pointerClickPending || !finite(x) || !finite(y)) {
			cancelPointerClick();
			return;
		}
		var dx = x - lastPointerClickX;
		var dy = y - lastPointerClickY;
		if (dx * dx + dy * dy > 36.0) {
			cancelPointerClick();
			return;
		}
		pointerClickPending = false;
		lastPointerClickArmed = true;
	}

	/** Cancels click recognition once movement exceeds the platform-independent slop. */
	public function cancelPointerClickIfMoved(x:Float, y:Float):Void {
		if (!pointerClickPending)
			return;
		var dx = x - lastPointerClickX;
		var dy = y - lastPointerClickY;
		if (dx * dx + dy * dy > 36.0)
			cancelPointerClick();
	}

	public function cancelPointerClick():Void {
		lastPointerClickTime = -1.0;
		lastPointerClickX = 0.0;
		lastPointerClickY = 0.0;
		lastPointerWordStart = -1;
		lastPointerWordEnd = -1;
		lastPointerClickCount = 0;
		lastPointerClickArmed = false;
		pointerClickPending = false;
	}

	public function dispose():Void {
		history.clear(); lastHistoryEdit = null;
		if (disposed)
			return;
		renderContent.dispose();
		layout.dispose();
		disposed = true;
	}

	public function isDisposed():Bool
		return disposed;

	function setComposition(start:Int, end:Int):Bool {
		var count = offsets.codepointCount;
		if (start < 0 || end < start || start > count || end > count) {
			return clearComposition();
		}
		if (start == compositionStart && end == compositionEnd)
			return false;
		compositionStart = start;
		compositionEnd = end;
		return true;
	}

	function clearComposition():Bool {
		if (compositionStart == -1 && compositionEnd == -1)
			return false;
		compositionStart = -1;
		compositionEnd = -1;
		return true;
	}

	function trimLineBreak(offset:Int, lineStart:Int):Int {
		var result = offset;
		while (result > lineStart) {
			var value = offsets.sliceCodepoints(result - 1, result);
			if (value != "\n" && value != "\r")
				break;
			result--;
		}
		return result;
	}

	function resetVerticalNavigation():Void
		hasDesiredVerticalX = false;

	function clampScrollOffset():Void {
		if (viewportHeight <= 0.0)
			return;
		var maximum = Math.max(0.0, layout.measure().height - viewportHeight);
		scrollOffsetY = clampFloat(scrollOffsetY, 0.0, maximum);
	}

	function ensureLive():Void {
		if (disposed)
			throw "Text editor state has been disposed";
	}

	static inline function finite(value:Float):Bool
		return value == value && value - value == 0.0;

	/** Native text services interpret Haxeon's null representation of empty strings as empty UTF-8. */
	public function layoutText():String
		return text == null ? "" : text;

	function get_text():String
		return offsets.text;

	static function copyTextStyle(value:TextStyle):TextStyle
		return new TextStyle(value.fontSize, value.font, value.letterSpacing);

	static function copyParagraphStyle(value:ParagraphStyle):ParagraphStyle
		return new ParagraphStyle(value.wrap, value.alignment, value.lineHeight, value.direction);

	static inline function clamp(value:Int, minimum:Int, maximum:Int):Int
		return value < minimum ? minimum : value > maximum ? maximum : value;

	static inline function absolute(value:Float):Float
		return value < 0.0 ? -value : value;

	static inline function clampFloat(value:Float, minimum:Float, maximum:Float):Float
		return value < minimum ? minimum : value > maximum ? maximum : value;
}

private class FieldHistoryEdit {
	public final start:Int;
	public final removed:String;
	public var inserted:String;
	public final before:TextSelection;
	public var after:TextSelection;
	public var time:Float;
	public final typing:Bool;
	public final composition:Bool;
	public var composing:Bool;
	public function new(edit:EditTransaction, before:TextSelection, after:TextSelection) {
		start = edit.replacementStart;
		removed = edit.replacedText == null ? "" : edit.replacedText;
		inserted = edit.replacementText == null ? "" : edit.replacementText;
		this.before = before; this.after = after; time = Sys.time();
		typing = edit.historyKind == TextEditorHistoryKind.Typing;
		composition = edit.historyKind == TextEditorHistoryKind.Composition;
		composing = edit.hasComposition;
	}
}

import haxeon.ui.FontCollection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutFrame;
import haxeon.ui.TextLayout.TextPosition;
import haxeon.ui.core.UiContext;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.UiModifier;
import haxeon.ui.widgets.text.TextArea;
import haxeon.ui.widgets.text.TextEditorState;
import haxeon.ui.widgets.text.Utf8Text;

/** Drag boundaries and selection synchronization after scroll layout. */
class SelectionDragTests {
	/** Exercise real shaping hits, including two edges sharing a glyph offset. */
	static function firstCharacterHighlightValid(fonts:FontCollection, text:String, laterLine:Int):Void {
		var editor = new TextEditorState(fonts, text);
		editor.updateLayout(200.0);
		var first = editor.layout.caret(new TextPosition(0, 0));
		var next = editor.layout.caret(new TextPosition(editor.layout.nextGrapheme(0), 0));
		var firstY = first.y + (first.ascender + first.descender) * 0.5;
		var firstX = first.x + (next.x - first.x) * 0.1;
		var expected = editor.layout.selectionRects(new TextPosition(0, 0),
			new TextPosition(editor.layout.nextGrapheme(0), 0));
		if (expected.length == 0) throw "First-character geometry fixture is empty";
		for (startOffset in [0, laterLine]) {
			var caret = editor.layout.caret(new TextPosition(startOffset, 0));
			var after = editor.layout.caret(new TextPosition(editor.layout.nextGrapheme(startOffset), 0));
			var hit = editor.hitTest(caret.x + (after.x - caret.x) * 0.75,
				caret.y + (caret.ascender + caret.descender) * 0.5);
			for (top in [-1.0, 0.0, firstY]) {
				editor.beginPointerSelection(hit, 1, false);
				editor.extendPointerSelection(editor.hitTestSelectionDrag(firstX, top, top));
				if (editor.selectionFocus != 0 || editor.selectionAnchor != editor.layout.nextGrapheme(startOffset))
					throw "Dragging from a glyph edge changed the logical selection";
				var anchor = editor.anchorPosition(), focus = editor.focusPosition();
				var rectangles = editor.layout.selectionRects(anchor, focus);
				var reversed = editor.layout.selectionRects(focus, anchor);
				if (rectangles.length == 0 || rectangles.length != reversed.length)
					throw "A nonempty backward drag lost its selection highlight";
				for (index in 0...rectangles.length) {
					var a = rectangles[index], b = reversed[index];
					if (a.x != b.x || a.y != b.y || a.width != b.width || a.height != b.height)
						throw "Selection paint geometry depended on drag direction";
				}
				for (glyph in expected) {
					var x = glyph.x + glyph.width / 2, y = glyph.y + glyph.height / 2;
					var covered = false;
					for (rect in rectangles)
						if (rect.x <= x && x < rect.x + rect.width && rect.y <= y && y < rect.y + rect.height)
							covered = true;
					if (!covered) throw "Backward drag omitted the first grapheme from its highlight";
				}
			}
		}
		// Starting at insertion zero and returning there is still an empty range.
		editor.beginPointerSelection(editor.hitTest(firstX, firstY), 1, false);
		editor.extendPointerSelection(editor.hitTestSelectionDrag(firstX, -1.0, 0.0));
		if (editor.selectionStart != editor.selectionEnd ||
			editor.layout.selectionRects(editor.anchorPosition(), editor.focusPosition()).length != 0)
			throw "An empty drag acquired an artificial character selection";
		editor.dispose();
	}

	public static function run(fonts:FontCollection, context:UiContext):Void {
		var code = new TextEditorState(fonts, "platform.HostFileDialogs\nfoo_bar->value");
		code.layout.codeWordBoundaries = true;
		code.updateLayout(600.0);
		// Exercise real glyph hits on both halves of the dot and adjacent letters.
		for (offset in [7, 8, 9]) {
			var before = code.layout.caret(new TextPosition(offset, 1));
			var after = code.layout.caret(new TextPosition(offset + 1, 1));
			for (fraction in [0.25, 0.75]) {
				var hit = code.hitTest(before.x + (after.x - before.x) * fraction,
					before.y + (before.ascender + before.descender) * 0.5);
				code.beginPointerSelection(hit, 2, false);
				var start = offset == 7 ? 0 : offset;
				var end = offset == 7 ? 8 : (offset == 8 ? 9 : 24);
				if (code.selectionStart != start || code.selectionEnd != end)
					throw "Code double-click crossed a dot boundary: glyph " + offset + " fraction " + fraction +
						" hit " + hit.offset + "/" + hit.affinity + " selected " + code.selectionStart + ":" + code.selectionEnd;
			}
		}
		code.beginPointerSelection(new TextPosition(2, 2), 2, false);
		code.extendPointerSelection(new TextPosition(12, 2));
		if (code.selectionStart != 0 || code.selectionEnd != 24) throw "Code word drag lost identifier boundaries";
		code.beginPointerSelection(new TextPosition(12, 2), 2, false);
		code.extendPointerSelection(new TextPosition(2, 2));
		if (code.selectionAnchor != 24 || code.selectionFocus != 0) throw "Code backward word drag lost anchor";
		code.beginPointerSelection(new TextPosition(12, 2), 3, false);
		if (code.selectionStart != 0 || code.selectionEnd != 25) throw "Code triple-click lost whole line";
		code.placeCaret(9, false);
		code.moveCaretByWord(-1, true);
		if (code.selectionStart != 8 || code.selectionEnd != 9) throw "Word extension did not isolate dot";
		code.placeCaret(9, false);
		if (!code.deleteWord(-1) || code.text != "platformHostFileDialogs\nfoo_bar->value")
			throw "Backward word deletion crossed identifier boundary";
		code.dispose();
		var deletion = new TextEditorState(fonts, "foo_bar->value");
		deletion.layout.codeWordBoundaries = true;
		deletion.placeCaret(7, false);
		if (!deletion.deleteWord(1) || deletion.text != "foo_barvalue")
			throw "Forward word deletion did not preserve identifiers";
		deletion.dispose();
		firstCharacterHighlightValid(fonts, "ABC\nDEF", 4);
		firstCharacterHighlightValid(fonts, "é🙂\nDEF", 4);
		firstCharacterHighlightValid(fonts, "אבג\nDEF", 4);
		var semanticDrag = new TextEditorState(fonts, "first second\nthird fourth\nfifth");
		for (x in [-100.0, 0.0, 40.0, 1000.0]) {
			semanticDrag.beginPointerSelection(new TextPosition(15, 0), 1, false);
			semanticDrag.extendPointerSelection(semanticDrag.hitTestSelectionDrag(x, -1.0, 0.0));
			if (semanticDrag.selectionAnchor != 15 || semanticDrag.selectionFocus != 0)
				throw "drag above document depended on horizontal position";
			semanticDrag.extendPointerSelection(semanticDrag.hitTestSelectionDrag(x, 0.0, 0.0));
			if (semanticDrag.selectionFocus != 0)
				throw "drag at document top depended on horizontal position";
			semanticDrag.extendPointerSelection(semanticDrag.hitTestSelectionDrag(x, semanticDrag.layout.measure().height + 1.0, 0.0));
			if (semanticDrag.selectionAnchor != 15 || semanticDrag.selectionFocus != Utf8Text.length(semanticDrag.text))
				throw "drag below document depended on horizontal position";
			var insideY = semanticDrag.layout.measure().height * 0.5;
			if (semanticDrag.hitTestSelectionDrag(x, insideY, 0.0).offset != semanticDrag.hitTest(x, 0.0).offset)
				throw "drag within document ignored viewport clamping";
		}
		semanticDrag.beginPointerSelection(new TextPosition(2, 0), 2, false);
		semanticDrag.extendPointerSelection(new TextPosition(8, 0));
		if (semanticDrag.selectionStart != 0 || semanticDrag.selectionEnd != 12) throw "word drag lost whole-word selection";
		semanticDrag.beginPointerSelection(new TextPosition(8, 0), 2, false);
		semanticDrag.extendPointerSelection(new TextPosition(2, 0));
		if (semanticDrag.selectionAnchor != 12 || semanticDrag.selectionFocus != 0) throw "backward word drag lost its anchor";
		semanticDrag.beginPointerSelection(new TextPosition(2, 0), 3, false);
		semanticDrag.extendPointerSelection(new TextPosition(15, 0));
		if (semanticDrag.selectionStart != 0 || semanticDrag.selectionEnd != 26) throw "line drag lost whole-line selection";
		semanticDrag.placeCaret(3, false);
		semanticDrag.beginPointerSelection(new TextPosition(8, 0), 1, true);
		semanticDrag.extendPointerSelection(new TextPosition(10, 0));
		if (semanticDrag.selectionAnchor != 3 || semanticDrag.selectionFocus != 10) throw "shift drag changed its original anchor";
		semanticDrag.dispose();
		var edgeStyle = new LayoutStyle();
		edgeStyle.width = LayoutAxis.fixed(200.0); edgeStyle.height = LayoutAxis.fixed(64.0);
		var edgeText = [for (line in 0...80) "row " + line].join("\n");
		var edgeArea = new TextArea("selection-edge-scroll", edgeText, null, edgeStyle);
		var edgeFrame = new LayoutFrame(200.0, 64.0);
		var edgeRoot = context.submit(edgeArea, edgeFrame);
		var edgeState:State<TextEditorState> = context.buildContext.existingState(edgeRoot.id);
		var edgeEditor:TextEditorState = cast edgeState.value;
		edgeEditor.placeCaret(0, false);
		edgeEditor.scrollBy(-100000.0);
		context.submit(edgeArea, edgeFrame);
		var edgeBounds = edgeRoot.globalBounds();
		context.pointerDown(edgeBounds.x + 15.0, edgeBounds.y + 12.0, 0);
		context.pointerMove(edgeBounds.x + 15.0, edgeBounds.y + edgeBounds.height + 20.0);
		var scrollBeforeTick = edgeEditor.scrollOffsetY;
		edgeFrame.deltaSeconds = 0.05;
		for (tick in 0...6) context.submit(edgeArea, edgeFrame);
		if (edgeEditor.scrollOffsetY <= scrollBeforeTick || edgeEditor.selectionEnd <= edgeEditor.selectionStart)
			throw "stationary edge drag did not scroll and extend selection";
		context.pointerUp(edgeBounds.x + 15.0, edgeBounds.y + edgeBounds.height + 20.0, 0);
		var stoppedScroll = edgeEditor.scrollOffsetY;
		for (tick in 0...3) context.submit(edgeArea, edgeFrame);
		if (edgeEditor.scrollOffsetY != stoppedScroll) throw "edge scroll continued after pointer release";
		// A stationary pointer must reach character zero as scrolling settles.
		context.pointerDown(edgeBounds.x + 15.0, edgeBounds.y + 24.0, 0);
		context.pointerMove(edgeBounds.x + 15.0, edgeBounds.y - 20.0);
		for (tick in 0...100) context.submit(edgeArea, edgeFrame);
		if (edgeEditor.scrollOffsetY != 0.0 || edgeEditor.selectionFocus != 0)
			throw "stationary top drag did not include the first character";
		context.pointerUp(edgeBounds.x + 15.0, edgeBounds.y - 20.0, 0);
		// Model an ancestor scroll whose transform is published by a later layout pass.
		var delayedDrag = new haxeon.ui.widgets.text.SelectionDragController();
		var delayedScheduler = new haxeon.ui.animation.AnimationScheduler();
		var resolvedScroll = 1;
		var selectedScroll = -1;
		var canScroll = true;
		edgeEditor.draggingSelection = true;
		delayedDrag.configure(delayedScheduler, edgeEditor, function() return edgeRoot.resolved,
			function(_, _) selectedScroll = resolvedScroll, function(_) return canScroll);
		delayedDrag.update(edgeBounds.x + 15.0, edgeBounds.y - 20.0);
		delayedScheduler.advance(0.05);
		resolvedScroll = 0;
		delayedDrag.layoutResolved();
		if (selectedScroll != 0) throw "drag selection used the transform before scroll layout resolved";
		selectedScroll = -1;
		canScroll = false;
		delayedScheduler.advance(0.05);
		if (selectedScroll != 0 || delayedScheduler.activeCount != 0)
			throw "drag reaching its scroll limit skipped final selection or kept animating";
		delayedDrag.dispose();
		edgeEditor.draggingSelection = false;
		Sys.println("PASS: drag selection boundaries, stationary edge scrolling and resolved scroll transforms");
		#if (mac || ios)
		edgeEditor.placeCaret(2, false);
		context.key(UiEventKind.KeyDown, UiKey.Right, UiModifier.Super | UiModifier.Shift);
		if (edgeEditor.selectionAnchor != 2 || edgeEditor.selectionFocus != 5) throw "Cmd+Shift+Right did not select to line end";
		context.key(UiEventKind.KeyDown, UiKey.Left, UiModifier.Super);
		if (edgeEditor.selectionFocus != 0) throw "Cmd+Left did not move to line start";
		#end
	}
}

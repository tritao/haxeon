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
	public static function run(fonts:FontCollection, context:UiContext):Void {
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

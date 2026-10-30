import haxeon.ui.Color;
import haxeon.ui.FontCollection;
import haxeon.ui.Image;
import haxeon.ui.ImageFormat;
import haxeon.ui.LayoutAlignmentX;
import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDistribution;
import haxeon.ui.LayoutFrame;
import haxeon.ui.LayoutChanges;
import haxeon.ui.LayoutImageContent;
import haxeon.ui.LayoutMeasureConstraints;
import haxeon.ui.LayoutMeasureResult;
import haxeon.ui.LayoutMeasuredContent;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutRenderableContent;
import haxeon.ui.LayoutSession;
import haxeon.ui.LayoutTransaction;
import haxeon.ui.LayoutWrapMode;
import haxeon.ui.ParagraphStyle;
import haxeon.ui.Rect;
import haxeon.ui.ResolvedLayoutItem;
import haxeon.ui.TextStyle;
import haxeon.ui.Transform2D;

import haxe.io.Bytes;
import haxeon.ui.TextLayout;
import haxeon.ui.TextLayout.TextPosition;

class LayoutSessionSmoke {
	static function rejectsTransaction(node:LayoutNode):Bool {
		try {
			LayoutTransaction.encode(node);
			return false;
		} catch (_:Dynamic) {
			return true;
		}
	}

	static function incremental(fonts:FontCollection):Void {
		var session = LayoutSession.create();
		session.setFonts(fonts);
		session.verifyTransactions = true;
		var root = LayoutNode.box(10000);
		root.style.width = LayoutAxis.fixed(240);
		root.style.height = LayoutAxis.fixed(160);
		for (index in 0...1100) {
			var child = LayoutNode.box(10001 + index);
			child.style.width = LayoutAxis.fixed(20);
			child.style.height = LayoutAxis.fixed(1);
			root.add(child);
		}
		var frame = new LayoutFrame(240, 160);
		var changes = new LayoutChanges();
		var first = session.submit(root, frame, changes)[10];
		var next = session.submit(root, frame, changes);
		if (next[10] != first) throw "An empty patch replaced unchanged geometry";
		root.children[900].style.width = LayoutAxis.fixed(30);
		changes.inputs.set(root.children[900].id, 0);
		next = session.submit(root, frame, changes);
		if (next[10] != first || next[901].width != 30) throw "An input patch did not preserve unchanged items";
		changes.clear();
		var moved = root.children[0];
		root.remove(moved); root.add(moved);
		changes.children.set(root.id, 0);
		next = session.submit(root, frame, changes);
		if (next[next.length - 1].id != moved.id) throw "Child reordering did not reach native";
		root.remove(root.children[10]);
		var added = LayoutNode.textNode(15000, "new text");
		root.add(added);
		next = session.submit(root, frame, changes);
		if (next.length != 1101 || next[next.length - 1].id != added.id) throw "Added or removed identity was lost";
		changes.clear();
		session.submit(root, frame, changes, true);
		session.submit(root, frame, changes);
		added.text = "日本語🙂 changed";
		changes.inputs.set(added.id, 0);
		session.submit(root, frame, changes);
		changes.clear();
		var oldFirst = root.children[0];
		root.remove(added); root.remove(oldFirst); root.add(added); root.add(oldFirst);
		changes.children.set(root.id, 0);
		session.submit(root, frame, changes);
		changes.clear();
		added.style.background = Color.rgba(0.3, 0.4, 0.5, 1);
		changes.inputs.set(added.id, 0);
		session.submit(root, frame, changes);
		changes.clear();
		var wrapper = LayoutNode.box(17000);
		wrapper.add(root);
		next = session.submit(wrapper, frame, changes);
		if (next[0].id != wrapper.id || next.length != 1102) throw "Changing the layout root was lost";
		next = session.submit(root, frame, changes);
		if (next[0].id != root.id || next.length != 1101) throw "Removing the old layout root was lost";
		// Omitting an actual input change must fail verification, even when native can retain its old geometry.
		root.children[20].style.width = LayoutAxis.fixed(31);
		var caught = false;
		try session.submit(root, frame, changes) catch (error:Dynamic)
			caught = Std.string(error).indexOf("layoutSession.verifyIncrementalTree") >= 0;
		if (!caught) throw "Verification accepted an unreported native input change";
		session.dispose();
		Sys.println("PASS: incremental layout, stable geometry, reorder, add/remove, full reset and missing-delta detection on 1101 nodes");
	}

	static function measuredVersion(fonts:FontCollection):Void {
		var measurement:Null<LayoutMeasuredContent> = null;
		var calls = 0;
		measurement = new LayoutMeasuredContent(function(_) {
			calls++;
			var current = measurement;
			if (current != null) current.invalidate();
			return new LayoutMeasureResult(20, 10);
		});
		var node = LayoutNode.custom(18000, measurement);
		var session = LayoutSession.create();
		session.setFonts(fonts);
		session.verifyTransactions = true;
		var changes = new LayoutChanges();
		var frame = new LayoutFrame(240, 160);
		session.submit(node, frame, changes);
		var before = calls;
		session.submit(node, frame, changes);
		if (calls <= before) throw "A measurement's new version was not submitted";
		session.verifyTree(node);
		session.dispose();
		Sys.println("PASS: an intrinsic version changed by measurement is captured as an input, verified, and resubmitted");
	}

	static function main():Int {
		var fontPath = Sys.getEnv("NKUI_TEST_FONT_PATH");
		if (fontPath == null)
			return 2;

		var fonts = FontCollection.create();
		fonts.add(fontPath);
		incremental(fonts);
		measuredVersion(fonts);
		var duplicateRoot = LayoutNode.box(80);
		var sharedChild = LayoutNode.box(81);
		duplicateRoot.add(sharedChild);
		duplicateRoot.add(sharedChild);
		if (!rejectsTransaction(duplicateRoot))
			return 47;
		var repeatedIdRoot = LayoutNode.box(82);
		repeatedIdRoot.add(LayoutNode.box(83));
		repeatedIdRoot.add(LayoutNode.box(83));
		if (!rejectsTransaction(repeatedIdRoot)) return 48;
		var infinity = Math.pow(2.0, 1024.0);
		var infiniteFontSize = LayoutNode.textNode(90, "font size");
		infiniteFontSize.textStyle.fontSize = infinity;
		var infiniteLetterSpacing = LayoutNode.textNode(91, "letter spacing");
		infiniteLetterSpacing.textStyle.letterSpacing = -infinity;
		var infiniteLineHeight = LayoutNode.textNode(92, "line height");
		infiniteLineHeight.paragraphStyle.lineHeight = infinity;
		if (!rejectsTransaction(infiniteFontSize) ||
			!rejectsTransaction(infiniteLetterSpacing) ||
			!rejectsTransaction(infiniteLineHeight))
			return 5;
		var session = LayoutSession.create();
		session.setFonts(fonts);
		var textLayout = TextLayout.createStyled(fonts, "NativeKit selection", 220.0,
			new TextStyle(18.0), new ParagraphStyle());
		var selection = textLayout.selectionRects(new TextPosition(0, 0), new TextPosition(9, 0));
		var collapsedSelection = textLayout.selectionRects(new TextPosition(4, 0), new TextPosition(4, 0));
		if (selection.length == 0 || selection[0].width <= 0.0 ||
			collapsedSelection.length != 0 || textLayout.nextGrapheme(1) != 2 ||
			textLayout.previousGrapheme(2) != 1 || textLayout.alignGrapheme(2) != 2)
			return 6;
		textLayout.dispose();

		var root = LayoutNode.box(100);
		root.style.width = LayoutAxis.fixed(256.0);
		root.style.height = LayoutAxis.fixed(192.0);
		root.style.clipHorizontal = true;
		root.style.clipVertical = true;
		var panel = LayoutNode.box(101);
		panel.style.width = LayoutAxis.fixed(160.0);
		panel.style.height = LayoutAxis.fixed(64.0);
		panel.style.childAlignX = LayoutAlignmentX.Center;
		panel.style.childAlignY = LayoutAlignmentY.Center;
		panel.style.childDistribution = LayoutDistribution.Center;
		panel.style.wrapMode = LayoutWrapMode.Wrap;
		panel.style.rowGap = 6.5;
		panel.style.columnGap = 4.25;
		panel.style.transform = Transform2D.identity().translated(100.0, 20.0);
		panel.add(LayoutNode.textNode(102, "Press"));
		root.add(panel);
		var frame = new LayoutFrame(256.0, 192.0);

		var resolved = session.submit(root, frame);
		if (resolved.length != 3 || resolved[1].id != 101 || resolved[1].width != 160.0 ||
			!resolved[1].visible || resolved[1].transform.tx != 100.0 || resolved[1].transform.ty != 20.0 ||
			!resolved[1].hitTest(120.0, 30.0) || resolved[1].hitTest(258.0, 30.0) ||
			resolved[0].contentBounds.width != 160.0 || resolved[0].contentBounds.height != 64.0)
			return 3;
		frame.deltaSeconds = 1.0 / 60.0;
		resolved = session.submit(root, frame);
		if (resolved.length != 3 || resolved[2].id != 102 || resolved[2].width <= 0.0 ||
			resolved[2].transform.tx != 100.0 || resolved[2].clipBounds.width != 256.0 ||
			!resolved[2].hasBaseline ||
			resolved[2].x < resolved[1].x + (resolved[1].width - resolved[2].width) * 0.5 - 0.1 ||
			resolved[2].x > resolved[1].x + (resolved[1].width - resolved[2].width) * 0.5 + 0.1 ||
			resolved[2].y < resolved[1].y + (resolved[1].height - resolved[2].height) * 0.5 - 0.1 ||
			resolved[2].y > resolved[1].y + (resolved[1].height - resolved[2].height) * 0.5 + 0.1)
			return 4;
		var floatingText = panel.children[0];
		floatingText.style.positioning = LayoutPositioning.Absolute;
		floatingText.style.positionX = 20.0;
		floatingText.style.positionY = 10.0;
		floatingText.style.zIndex = 9;
		resolved = session.submit(root, frame);
		if (resolved[2].x != resolved[1].x + 20.0 || resolved[2].y != resolved[1].y + 10.0)
			return 7;

		var measureCalls = 0;
		var measureContent = new LayoutMeasuredContent(function(constraints:LayoutMeasureConstraints) {
			measureCalls++;
			if (constraints.maxWidth < constraints.minWidth || constraints.maxHeight < constraints.minHeight)
				throw "Invalid intrinsic measurement constraints";
			return new LayoutMeasureResult(48.0, 20.0, 15.0, true);
		});
		var measuredNode = LayoutNode.custom(103, measureContent);
		panel.add(measuredNode);
		resolved = session.submit(root, frame);
		var measuredItem:Null<ResolvedLayoutItem> = null;
		for (item in resolved)
			if (item.id == 103)
				measuredItem = item;
		var callsAfterFirst = measureCalls;
		if (callsAfterFirst == 0 || measuredItem == null || measuredItem.width != 48.0 ||
			measuredItem.height != 20.0 || !measuredItem.hasBaseline)
			return 41;
		resolved = session.submit(root, frame);
		if (measureCalls != callsAfterFirst)
			return 42;
		measureContent.invalidate();
		resolved = session.submit(root, frame);
		if (measureCalls <= callsAfterFirst)
			return 43;
		var stats = session.measureStats();
		if (stats.requests < 2 || stats.cacheHits == 0 || stats.cacheMisses == 0 ||
			stats.callbackCalls != measureCalls || stats.cacheEntries == 0 ||
			stats.cacheEntries > stats.cacheCapacity)
			return 46;

		var paintCalls = 0;
		var renderable = new LayoutRenderableContent(measureContent, function(canvas, geometry) {
			paintCalls++;
			canvas.fillRect(new Rect(0.0, 0.0, geometry.width, geometry.height),
				Color.rgba(0.2, 0.4, 0.8, 1.0));
		});
		if (measureContent.asRenderable() != null || renderable.asRenderable() != renderable)
			return 53;
		measuredNode.intrinsicContent = renderable;
		resolved = session.submit(root, frame);
		measuredItem = null;
		for (item in resolved)
			if (item.id == 103)
				measuredItem = item;
		if (measuredItem == null)
			return 47;
		var paintedList = renderable.paint(measuredItem);
		if (paintCalls != 1 || paintedList.info().commandCount == 0)
			return 48;
		renderable.paint(measuredItem);
		if (paintCalls != 1)
			return 49;
		measuredNode.style.transform = Transform2D.identity().translated(12.0, 6.0);
		resolved = session.submit(root, frame);
		if (paintCalls != 1)
			return 50;
		measuredNode.style.transform = Transform2D.identity();
		resolved = session.submit(root, frame);
		if (paintCalls != 1)
			return 51;
		measureContent.invalidate();
		renderable.paint(measuredItem);
		if (paintCalls != 2)
			return 52;
		renderable.dispose();

		var image = Image.create(8, 6, ImageFormat.RGBA8, Bytes.alloc(8 * 6 * 4));
		panel.add(LayoutNode.custom(104, new LayoutImageContent(image)));
		resolved = session.submit(root, frame);
		var imageItem:Null<ResolvedLayoutItem> = null;
		for (item in resolved)
			if (item.id == 104)
				imageItem = item;
		if (imageItem == null || imageItem.width != 8.0 || imageItem.height != 6.0)
			return 44;
		image.dispose();

		measuredNode.intrinsicContent = null;
		measuredNode.measureVersion = 2;
		var fallbackCalls = 0;
		session.setMeasureCallback(function(nodeId:Int, constraints:LayoutMeasureConstraints) {
			fallbackCalls++;
			if (nodeId != 103)
				throw "Unexpected fallback measurement request";
			return new LayoutMeasureResult(32.0, 12.0);
		});
		resolved = session.submit(root, frame);
		measuredItem = null;
		for (item in resolved)
			if (item.id == 103)
				measuredItem = item;
		if (fallbackCalls == 0 || measuredItem == null || measuredItem.width != 32.0 ||
			measuredItem.height != 12.0)
			return 45;
		session.setMeasureCallback(null);

		session.dispose();
		fonts.dispose();
		Sys.println("PASS: Haxeon layout session transaction");
		return 0;
	}
}

package haxeon.ui.widgets.controls;
import haxeon.ui.widgets.scroll.ScrollController;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutPositioning;
import haxeon.ui.LayoutStyle;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.Rect;
import haxeon.ui.TextLayout;
import haxeon.ui.TextWrap;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.theme.TextRole;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.widgets.scroll.ScrollView;
import haxeon.ui.widgets.scroll.ScrollAxis;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiEventKind;
import haxeon.ui.core.UiKey;
import haxeon.ui.semantics.AccessibilityAction;
import haxeon.ui.semantics.AccessibilityOrientation;
import haxeon.ui.semantics.AccessibilityRole;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.DecorationChain;
import haxeon.ui.style.ShadowDecoration;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.StyleSource;
import haxeon.ui.style.StyleTarget;

/** Mutable bridge for active-option visibility across rebuilt render trees. */
class SelectionPopupVisibility {
	public var ensure:Int->Void;

	public function new() {
		ensure = function(_:Int) {};
	}
}

/** Result of building a shared selection popup. */
class SelectionPopupResult {
	public final node:RenderNode;
	public final optionNodes:Array<RenderNode>;
	public final ensureActiveVisible:Int->Void;

	public function new(node:RenderNode, optionNodes:Array<RenderNode>,
			ensureActiveVisible:Int->Void) {
		this.node = node;
		this.optionNodes = optionNodes;
		this.ensureActiveVisible = ensureActiveVisible;
	}
}

/** Internal popup/list kernel shared by Select and ComboBox. */
class SelectionPopup {
	final options:Array<SelectOption<Dynamic>>;
	final visibleIndices:Array<Int>;
	public var selectedValue:Dynamic;
	public var activeIndex(default, null):Int;
	final rootX:Float;
	final rootY:Float;
	final triggerX:Float;
	final triggerY:Float;
	final triggerWidth:Float;
	final triggerHeight:Float;
	final fallbackWidth:Float;
	final fallbackHeight:Float;
	final onSelect:Int->Void;
	final onClose:Void->Void;
	final onActive:Int->Void;
	final isEnabled:Int->Bool;
	final nextEnabled:Int->Int->Int;

	public function new(options:Array<SelectOption<Dynamic>>, visibleIndices:Array<Int>,
			selectedValue:Dynamic, activeIndex:Int, rootX:Float, rootY:Float,
			triggerX:Float, triggerY:Float, triggerWidth:Float, triggerHeight:Float,
			fallbackWidth:Float, fallbackHeight:Float, onSelect:Int->Void,
			onClose:Void->Void, onActive:Int->Void, isEnabled:Int->Bool,
			nextEnabled:Int->Int->Int) {
		this.options = options;
		this.visibleIndices = visibleIndices;
		this.selectedValue = selectedValue;
		this.activeIndex = activeIndex;
		this.rootX = rootX;
		this.rootY = rootY;
		this.triggerX = triggerX;
		this.triggerY = triggerY;
		this.triggerWidth = triggerWidth;
		this.triggerHeight = triggerHeight;
		this.fallbackWidth = fallbackWidth;
		this.fallbackHeight = fallbackHeight;
		this.onSelect = onSelect == null ? function(_:Int) {} : onSelect;
		this.onClose = onClose == null ? function() {} : onClose;
		this.onActive = onActive == null ? function(_:Int) {} : onActive;
		this.isEnabled = isEnabled == null ? function(_:Int) return true : isEnabled;
		this.nextEnabled = nextEnabled == null ? function(index:Int, _:Int) return index : nextEnabled;
	}

	public function build(context:BuildContext, root:RenderNode):SelectionPopupResult {
		var dropdownId = context.id("options");
		var valueState = context.state(dropdownId, selectedValue);
		var optionNodes:Array<RenderNode> = [];
		var visibility = new SelectionPopupVisibility();
		var request = function() {
			valueState.updateQuietly(selectedValue);
			if (!context.updateInPlace || !context.requestPatch(dropdownId)) valueState.update(selectedValue);
		};
		var ensure = function(index:Int) {
			activeIndex = index;
			visibility.ensure(index);
			request();
		};
		var dropdown = context.selfUpdating(dropdownId,
			function() return buildControl(context, dropdownId, optionNodes, visibility, ensure, request), false);
		root.add(dropdown);
		root.onPointerDownOutside(function(event) {
			if (event.button == 0) onClose();
		});
		return new SelectionPopupResult(dropdown, optionNodes, ensure);
	}

	function buildControl(context:BuildContext, dropdownId:WidgetId, optionNodes:Array<RenderNode>,
			visibility:SelectionPopupVisibility, ensure:Int->Void, request:Void->Void):RenderNode {
		optionNodes.resize(0);
		var scrollController:Null<ScrollController> = null;
		visibility.ensure = function(_:Int) {};
		var width = triggerWidth > 0.0 ? triggerWidth : fallbackWidth;
		var height = triggerHeight > 0.0 ? triggerHeight : fallbackHeight;
		var edge = Math.min(8.0, context.viewportWidth * 0.5);
		var availableWidth = Math.max(1.0, context.viewportWidth - edge * 2.0);
		var popupWidth = Math.min(Math.max(Math.max(1.0, width), contentWidth(context)), availableWidth);
		var popupX = clamp(triggerX, edge, Math.max(edge,
			context.viewportWidth - edge - popupWidth));
		var rowHeight = 32.0;
		var popupPadding = 8.0;
		var popupGap = visibleIndices.length > 0 ? (visibleIndices.length - 1) * 2.0 : 0.0;
		var naturalHeight = popupPadding + visibleIndices.length * rowHeight + popupGap;
		var placementGap = 4.0;
		var below = Math.max(0.0, context.viewportHeight - (triggerY + height) - placementGap);
		var above = Math.max(0.0, triggerY - placementGap);
		var opensBelow = below >= naturalHeight || below >= above;
		var availableHeight = opensBelow ? below : above;
		var popupHeight = Math.min(Math.max(1.0, naturalHeight), Math.max(1.0, availableHeight));
		var popupGlobalY = opensBelow ? triggerY + height + placementGap :
			triggerY - popupHeight - placementGap;
		var needsScroll = popupHeight + 0.001 < naturalHeight;
		var optionViewportHeight = Math.max(1.0, popupHeight - popupPadding);

		var dropdownStyle = new LayoutStyle();
		dropdownStyle.width = LayoutAxis.fixed(popupWidth);
		dropdownStyle.height = LayoutAxis.fixed(popupHeight);
		dropdownStyle.direction = LayoutDirection.TopToBottom;
		dropdownStyle.positioning = LayoutPositioning.Absolute;
		dropdownStyle.positionX = popupX - rootX;
		dropdownStyle.positionY = popupGlobalY - rootY;
		dropdownStyle.overlay = true;
		dropdownStyle.clipToParent = false;
		dropdownStyle.padding = new Insets(4.0, 4.0, 4.0, 4.0);
		dropdownStyle.childGap = 2.0;
		dropdownStyle.radiusTopLeft = dropdownStyle.radiusTopRight = 5.0;
		dropdownStyle.radiusBottomLeft = dropdownStyle.radiusBottomRight = 5.0;
		var dropdownComputed = context.resolveStyle(new StyleTarget("selection-popup", "options",
			"options", null, ["selection-popup"], context.interactionStates.get(dropdownId)), dropdownStyle);
		var dropdown = new RenderNode(dropdownId, LayoutVisualKind.Custom,
			dropdownComputed.toLayoutStyle());
		dropdown.setStyleIdentity("selection-popup", "options", "options", null, ["selection-popup"]);
		dropdown.states = context.interactionStates.get(dropdownId);
		dropdown.computedStyle = dropdownComputed;
		var popupDecorations = dropdownComputed.get(StyleProperty.Decorations);
		var popupDecorationSource = dropdownComputed.source(StyleProperty.Decorations);
		if ((popupDecorations == null || popupDecorations.decorations.length == 0) &&
			popupDecorationSource != null && popupDecorationSource.stylesheet == "framework" &&
			popupDecorationSource.selector == "default")
			dropdownComputed.set(StyleProperty.Decorations, DecorationChain.of([
				new ShadowDecoration()
			]), new StyleSource("framework", "selection-popup", -1, "default"));
		dropdown.onPaint(function(canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height),
				context.theme.panelBackground);
			var border = context.theme.tokens.selectionBorder;
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, 1.0), border);
			canvas.fillRectIfPositive(new Rect(0.0, geometry.height - 1.0, geometry.width, 1.0), border);
			canvas.fillRectIfPositive(new Rect(0.0, 1.0, 1.0, geometry.height - 2.0), border);
			canvas.fillRectIfPositive(new Rect(geometry.width - 1.0, 1.0, 1.0,
				geometry.height - 2.0), border);
		}, "selection-popup-surface");
		var listSemantics = new Semantics(AccessibilityRole.List, "Options");
		listSemantics.orientation = AccessibilityOrientation.Vertical;
		if (needsScroll)
			listSemantics.actions = AccessibilityAction.ScrollForward |
				AccessibilityAction.ScrollBackward;
		dropdown.semantics = listSemantics;
		// A menu owns wheel input even at its limits or when all options fit.
		// Otherwise its enclosing scroll view moves underneath the open popup.
		var ownWheel = function(event:UiEvent) {
			if (!event.defaultPrevented && scrollController != null)
				scrollController.scrollBy(0.0, event.deltaY);
			event.preventDefault();
			event.stopPropagation();
		};
		dropdown.on(UiEventKind.Scroll, ownWheel);
		var optionParent = dropdown;
		if (needsScroll) {
			var scrollState = context.resourceState(context.id("option-scroll"),
				function() return new SelectionPopupScrollState(activeIndex), function(_) {}).value;
			if (scrollState.activeIndex != activeIndex) {
				scrollState.activeIndex = activeIndex;
				scrollState.revealPending = true;
			}
			scrollController = scrollState.controller;
			var controller:ScrollController = scrollController;
			var viewportStyle = new LayoutStyle();
			viewportStyle.width = LayoutAxis.grow();
			viewportStyle.height = LayoutAxis.fixed(optionViewportHeight);
			viewportStyle.clipVertical = true;
			var contentStyle = new LayoutStyle();
			contentStyle.width = LayoutAxis.grow();
			contentStyle.height = LayoutAxis.fit();
			contentStyle.direction = LayoutDirection.TopToBottom;
			contentStyle.childGap = 2.0;
			optionParent = new RenderNode(context.id("option-content"), LayoutVisualKind.Box, contentStyle);
			var scroll = new ScrollView("option-viewport", new SelectionPopupContent(optionParent),
				viewportStyle, ScrollAxis.Vertical, controller);
			scroll.showScrollbar = false;
			scroll.onScroll = ownWheel;
			dropdown.add(scroll.build(context));
			visibility.ensure = function(index:Int) {
				scrollState.activeIndex = index;
				scrollState.revealPending = true;
				if (controller.viewportHeight <= 0.0) return;
				var position = visiblePosition(index);
				scrollState.revealPending = false;
				if (position < 0) return;
				var optionTop = position * (rowHeight + 2.0);
				var optionBottom = optionTop + rowHeight;
				var target = controller.offsetY;
				if (optionTop < target) target = optionTop;
				else if (optionBottom > target + optionViewportHeight) target = optionBottom - optionViewportHeight;
				if (target != controller.offsetY && controller.jumpTo(controller.offsetX, target)) context.requestLayoutFeedback();
			};
			// ScrollView updates metrics on its translated content before this child resolves.
			optionParent.onResolved(function(_) { if (scrollState.revealPending) visibility.ensure(scrollState.activeIndex); });
		}

		for (position in 0...visibleIndices.length) {
			var originalIndex = visibleIndices[position];
			var option:SelectOption<Dynamic> = options[originalIndex];
			var optionStyle = new LayoutStyle();
			optionStyle.width = LayoutAxis.grow();
			optionStyle.height = LayoutAxis.fixed(rowHeight);
			// The selection check is painted in the first 20 px of the row; the label starts after it
			// on every row, so the text lines up whether or not that row is the selected one.
			optionStyle.padding = new Insets(26.0, 5.0, 9.0, 5.0);
			var optionButton = new Button(option.label, optionStyle,
				function() { selectedValue = option.value; activeIndex = originalIndex; onSelect(originalIndex); request(); }, option.key);
			optionButton.classes = ["selection-option"];
			optionButton.ellipsizeLabel = true;
			optionButton.variant = ButtonVariant.Navigation;
			optionButton.enabled = isEnabled(originalIndex);
			optionButton.selected = sameValue(option.value, selectedValue);
			optionButton.semanticRole = AccessibilityRole.ListItem;
			optionButton.semanticActions = optionButton.enabled ? AccessibilityAction.Select : 0;
			var optionNode = context.withScope(new haxeon.ui.core.Key("option-" + option.key),
				function() return optionButton.build(context));
			var optionSemantics:Semantics = cast optionNode.semantics;
			if (optionButton.selected)
				SelectionIndicator.check(context, optionNode, "option-check-" + originalIndex,
					context.theme.text);
			optionSemantics.setSize = visibleIndices.length;
			optionSemantics.positionInSet = position + 1;
			optionNodes.push(optionNode);
			optionParent.add(optionNode);
		}

		for (position in 0...optionNodes.length) {
			var optionPosition = position;
			optionNodes[position].on(UiEventKind.KeyDown, function(event) {
				if (event.key == UiKey.Escape) {
					onClose();
					event.preventDefault();
					return;
				}
				var next = -1;
				if (event.key == UiKey.Home)
					next = firstEnabledVisible();
				else if (event.key == UiKey.End)
					next = lastEnabledVisible();
				else if (event.key == UiKey.Down || event.key == UiKey.Right)
					next = nextEnabled(visibleIndices[optionPosition], 1);
				else if (event.key == UiKey.Up || event.key == UiKey.Left)
					next = nextEnabled(visibleIndices[optionPosition], -1);
				if (next < 0)
					return;
				onActive(next);
				ensure(next);
				var nextPosition = visiblePosition(next);
				if (nextPosition >= 0 && nextPosition < optionNodes.length)
					context.requestFocus(optionNodes[nextPosition].id);
				event.preventDefault();
			});
		}
		return dropdown;
	}

	/** Include the check gutter, row padding and popup padding in the natural width. */
	function contentWidth(context:BuildContext):Float {
		if (context.fonts == null || visibleIndices.length == 0)
			return 0.0;
		var resolved = context.resolveTextRole(TextRole.Button,
			TextStyleOverride.paragraph(TextWrap.None));
		var layout = TextLayout.createStyled(context.fonts, "", 100000.0,
			resolved.textStyle, resolved.paragraphStyle);
		var widest = 0.0;
		for (index in visibleIndices) {
			layout.setText(options[index].label);
			widest = Math.max(widest, layout.measure().width);
		}
		layout.dispose();
		return Math.ceil(widest) + 26.0 + 9.0 + 8.0;
	}

	function firstEnabledVisible():Int {
		for (index in visibleIndices)
			if (isEnabled(index))
				return index;
		return -1;
	}

	function lastEnabledVisible():Int {
		var position = visibleIndices.length - 1;
		while (position >= 0) {
			var index = visibleIndices[position];
			if (isEnabled(index))
				return index;
			position--;
		}
		return -1;
	}

	function visiblePosition(index:Int):Int {
		for (position in 0...visibleIndices.length)
			if (visibleIndices[position] == index)
				return position;
		return -1;
	}

	static inline function clamp(value:Float, minimum:Float, maximum:Float):Float
		return Math.max(minimum, Math.min(maximum, value));

	static function sameValue(left:Dynamic, right:Dynamic):Bool
		return left == right;
}


private class SelectionPopupContent implements View {
	final node:RenderNode;
	public function new(node:RenderNode) this.node = node;
	public function build(context:BuildContext):RenderNode return node;
}

private class SelectionPopupScrollState {
	public final controller = new ScrollController();
	public var activeIndex:Int;
	public var revealPending = true;
	public function new(activeIndex:Int) this.activeIndex = activeIndex;
}

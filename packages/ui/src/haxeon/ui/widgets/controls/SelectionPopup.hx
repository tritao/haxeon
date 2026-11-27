package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.widgets.scroll.ScrollController;

import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.TextStyle;
import haxeon.ui.LayoutStyle;
import haxeon.ui.Rect;
import haxeon.ui.TextLayout;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.TextStyleOverride;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.semantics.Semantics;
import haxeon.ui.style.Decoration;
import haxeon.ui.style.StyleProperty;
import haxeon.ui.style.ComputedStyle;
import haxeon.ui.theme.TextRole;
import haxeon.ui.widgets.scroll.ScrollView;

import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Select;
/** What a popup's caller reads back from its last build: the IDs of its option rows, to move focus to them. */
internal class SelectionPopupLink {
	public final optionIds:Array<WidgetId> = [];

	public function new() {}
}

/**
 * The popup list shared by Select and ComboBox, as a controlled component: the caller owns the selected value and the
 * active option, and moving through the list or choosing an option reports to it.
 */
internal class SelectionPopup implements ScopeView {
	final options:Array<SelectOption<Dynamic>>;
	final visibleIndices:Array<Int>;
	final selectedValue:Dynamic;
	final activeIndex:Int;
	final rootX:Float;
	final rootY:Float;
	final triggerX:Float;
	final triggerY:Float;
	final triggerWidth:Float;
	final triggerHeight:Float;
	final fallbackWidth:Float;
	final fallbackHeight:Float;
	final link:SelectionPopupLink;
	final onSelect:Int->Void;
	final onClose:Void->Void;
	final onActive:Int->Void;

	public function new(options:Array<SelectOption<Dynamic>>,
			visibleIndices:Array<Int>,
			selectedValue:Dynamic,
			activeIndex:Int,
			rootX:Float,
			rootY:Float,
			triggerX:Float,
			triggerY:Float,
			triggerWidth:Float,
			triggerHeight:Float,
			fallbackWidth:Float,
			fallbackHeight:Float,
			link:SelectionPopupLink,
			onSelect:Int->Void,
			onClose:Void->Void,
			onActive:Int->Void) {
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
		this.link = link;
		this.onSelect = onSelect;
		this.onClose = onClose;
		this.onActive = onActive;
	}

	public function scopeKey():String return "options";

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, SelectionPopup)) return false;
		var other:SelectionPopup = cast previous;
		if (link != other.link || !sameValue(selectedValue, other.selectedValue) || activeIndex != other.activeIndex
			|| rootX != other.rootX || rootY != other.rootY || triggerX != other.triggerX || triggerY != other.triggerY
			|| triggerWidth != other.triggerWidth || triggerHeight != other.triggerHeight
			|| fallbackWidth != other.fallbackWidth || fallbackHeight != other.fallbackHeight
			|| options.length != other.options.length || visibleIndices.length != other.visibleIndices.length)
			return false;
		for (index in 0...options.length) if (options[index] != other.options[index]) return false;
		for (index in 0...visibleIndices.length) if (visibleIndices[index] != other.visibleIndices[index]) return false;
		return true;
	}

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);

	public function buildBody(context:BuildContext):ViewRoot {
		return buildControl(context, context.rootId("selection-popup"));
	}

	function buildControl(context:BuildContext, dropdownId:WidgetId):RenderNode {
		var latest = context.latestOf(this);
		link.optionIds.resize(0);
		var scrollController:Null<ScrollController> = null;
		var width = triggerWidth > 0.0 ? triggerWidth : fallbackWidth;
		var height = triggerHeight > 0.0 ? triggerHeight : fallbackHeight;
		var edge = Math.min(8.0, context.viewportWidth * 0.5);
		var availableWidth = Math.max(1.0, context.viewportWidth - edge * 2.0);
		var popupWidth = Math.min(Math.max(Math.max(1.0, width), contentWidth(context)), availableWidth);
		var popupX = clamp(triggerX, edge, Math.max(edge, context.viewportWidth - edge - popupWidth));
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
		var popupGlobalY = opensBelow ? triggerY + height + placementGap : triggerY - popupHeight - placementGap;
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
		var dropdownComputed = context.resolveStyle(context.styleTarget(dropdownId, "selection-popup",
			"options",
			"options",
			null,
			["selection-popup"]),
			dropdownStyle);
		var dropdown = context.createNode(dropdownId, LayoutVisualKind.Custom, dropdownComputed.toLayoutStyle());
		dropdown.setStyleIdentity("selection-popup", "options", "options", null, ["selection-popup"]);
		dropdown.states = context.interactionStates.peek(dropdownId);
		dropdown.computedStyle = dropdownComputed;
		var popupDecorations = dropdownComputed.getDecorations();
		var popupDecorationSource = dropdownComputed.source(StyleProperty.Decorations);
		if ((popupDecorations == null || popupDecorations.decorations.length == 0)
			&& popupDecorationSource != null && popupDecorationSource.stylesheet == "framework"
			&& popupDecorationSource.selector == "default")
			dropdownComputed.setDecorations(DecorationChain.of([new ShadowDecoration()]),
				new StyleSource("framework", "selection-popup", -1, "default"));
		dropdown.onPaint(function(canvas, geometry) {
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, geometry.height),
				context.theme.tokens.surface);
			var border = context.theme.tokens.border;
			canvas.fillRectIfPositive(new Rect(0.0, 0.0, geometry.width, 1.0), border);
			canvas.fillRectIfPositive(new Rect(0.0, geometry.height - 1.0, geometry.width, 1.0), border);
			canvas.fillRectIfPositive(new Rect(0.0, 1.0, 1.0, geometry.height - 2.0), border);
			canvas.fillRectIfPositive(new Rect(geometry.width - 1.0, 1.0, 1.0, geometry.height - 2.0), border);
		}, "selection-popup-surface");
		var listSemantics = new Semantics(AccessibilityRole.List, "Options");
		listSemantics.orientation = AccessibilityOrientation.Vertical;
		if (needsScroll) listSemantics.actions = AccessibilityAction.ScrollForward | AccessibilityAction.ScrollBackward;
		dropdown.semantics = listSemantics;
		// A menu owns wheel input even at its limits or when all options fit.
		// Otherwise its enclosing scroll view moves underneath the open popup.
		var ownWheel = function(event:UiEvent) {
			if (!event.defaultPrevented && scrollController != null) scrollController.scrollBy(0.0, event.deltaY);
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
			optionParent = context.createNode(context.rootId("option-content"), LayoutVisualKind.Box, contentStyle);
			var scroll = new ScrollView("option-viewport",
				new SelectionPopupContent(optionParent),
				viewportStyle,
				ScrollAxis.Vertical,
				controller);
			scroll.showScrollbar = false;
			scroll.onScroll = ownWheel;
			dropdown.add(scroll.build(context));
			var reveal = function(index:Int) {
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
				if (target != controller.offsetY && controller.jumpTo(controller.offsetX,
					target)) context.requestLayoutFeedback();
			};
			// ScrollView updates metrics on its translated content before this child resolves.
			optionParent.onResolved(function(_) {
				if (scrollState.revealPending) reveal(scrollState.activeIndex);
			});
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
			var optionEnabled = isEnabled(originalIndex);
			var optionSelected = sameValue(option.value, selectedValue);
			var optionSemantics = new Semantics(AccessibilityRole.ListItem, option.label);
			optionSemantics.actions = optionEnabled ? AccessibilityAction.Select : AccessibilityAction.empty();
			optionSemantics.setSize = visibleIndices.length;
			optionSemantics.positionInSet = position + 1;
			var optionButton = new Button(option.label, optionStyle, function() {
				var handler = latest().onSelect;
				if (handler != null) handler(originalIndex);
			}, option.key, optionEnabled, ButtonVariant.Navigation,
				optionSelected, ["selection-option"], null, null, null,
				optionSelected ? SelectionIndicator.check("option-check-" + originalIndex,
				context.theme.tokens.textPrimary) : null, null, true, null, null, null, optionSemantics);
			var optionPosition = position;
			var optionModifier = new RootModifier();
			optionModifier.on(UiEventKind.KeyDown, function(event) {
				if (event.key == UiKey.Escape) {
					var close = latest().onClose;
					if (close != null) close();
					event.preventDefault();
					return;
				}
				var next = -1;
				if (event.key == UiKey.Home) next = firstEnabledVisible();
				else if (event.key == UiKey.End) next = lastEnabledVisible();
				else if (event.key == UiKey.Down
					|| event.key == UiKey.Right) next = nextEnabled(visibleIndices[optionPosition], 1);
				else if (event.key == UiKey.Up
					|| event.key == UiKey.Left) next = nextEnabled(visibleIndices[optionPosition],
					-1);
				if (next < 0) return;
				var popup = latest();
				if (popup.onActive != null) popup.onActive(next);
				var nextPosition = visiblePosition(next);
				if (nextPosition >= 0 && nextPosition < popup.link.optionIds.length)
					context.requestFocus(popup.link.optionIds[nextPosition]);
				event.preventDefault();
			});
			var optionNode = context.withScope(new haxeon.ui.core.Key("option-" + option.key),
				function() return context.build(optionButton, optionModifier));
			link.optionIds.push(optionNode.id);
			optionParent.add(optionNode);
		}

		return dropdown;
	}

	/** Include the check gutter, row padding and popup padding in the natural width. */
	function contentWidth(context:BuildContext):Float {
		if (context.fonts == null || visibleIndices.length == 0) return 0.0;
		var resolved = context.resolveTextRole(TextRole.Button, TextStyleOverride.paragraph(TextWrap.None));
		var layout = TextLayout.create(context.fonts, "", 100000.0, resolved.textStyle, resolved.paragraphStyle);
		var widest = 0.0;
		for (index in visibleIndices) {
			layout.setText(options[index].label);
			widest = Math.max(widest, layout.measure().width);
		}
		layout.dispose();
		return Math.ceil(widest) + 26.0 + 9.0 + 8.0;
	}

	function isEnabled(index:Int):Bool return index >= 0 && index < options.length && options[index].enabled;

	/** The next enabled visible option after `index` in `direction`, wrapping; `index` itself when there is none. */
	function nextEnabled(index:Int, direction:Int):Int {
		var position = visiblePosition(index);
		if (position < 0 || visibleIndices.length == 0) return index;
		for (_ in 0...visibleIndices.length) {
			position = (position + direction + visibleIndices.length) % visibleIndices.length;
			if (isEnabled(visibleIndices[position])) return visibleIndices[position];
		}
		return index;
	}

	function firstEnabledVisible():Int {
		for (index in visibleIndices) if (isEnabled(index)) return index;
		return -1;
	}

	function lastEnabledVisible():Int {
		var position = visibleIndices.length - 1;
		while (position >= 0) {
			var index = visibleIndices[position];
			if (isEnabled(index)) return index;
			position--;
		}
		return -1;
	}

	function visiblePosition(index:Int):Int {
		for (position in 0...visibleIndices.length) if (visibleIndices[position] == index) return position;
		return -1;
	}

	static inline function clamp(value:Float, minimum:Float, maximum:Float):Float return Math.max(minimum,
		Math.min(maximum, value));

	static function sameValue(left:Dynamic, right:Dynamic):Bool return left == right;
}


private class SelectionPopupContent implements View {
	final node:RenderNode;
	public function new(node:RenderNode) this.node = node;
	public function build(context:BuildContext):ViewRoot return node;
}

private class SelectionPopupScrollState {
	public final controller = new ScrollController();
	public var activeIndex:Int;
	public var revealPending = true;
	public function new(activeIndex:Int) this.activeIndex = activeIndex;
}

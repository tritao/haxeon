package haxeon.ui.widgets.controls;
import haxeon.ui.widgets.text.TextField;

import haxeon.ui.Color;
import haxeon.ui.Insets;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RootModifier;
import haxeon.ui.core.State;
import haxeon.ui.core.UiEvent;
import haxeon.ui.core.UiKey;
import haxeon.ui.core.View;
import haxeon.ui.semantics.Semantics;

import haxeon.ui.widgets.controls.Button;
import haxeon.ui.widgets.controls.Select;
/** Typed editable selection control with filtered, keyboard-navigable options. */
class ComboBox<T> implements View {
	final key:Key;
	/** The choices, each with a unique key, in the order the list shows them. */
	public final options:Array<SelectOption<T>>;

	/** The selected option's value. */
	public var value:T;

	/** Whether the field reacts to input; true unless set otherwise. */
	public var enabled:Bool;

	/** The field's box; 40 pixels high unless it sets a height. */
	public var style:LayoutStyle;

	/** The hint shown while the query is empty; "Search" by default. */
	public var placeholder:String;

	/** Called with the value of the option the user picks. */
	public var onChange:T->Void;

	/** Called with the query each time the user edits it, for a caller that loads its options as the user types. */
	public var onQueryChange:String->Void;

	/** Whether the caller passed `onChange`, which otherwise does nothing. */
	var hasChangeHandler:Bool;

	/** Whether the caller passed `onQueryChange`, which otherwise does nothing. */
	var hasQueryChangeHandler:Bool;
	final usesDefaultStyle:Bool;

	/**
	 * A field that filters `options` by what the user types and selects one, showing `value` to start with. Throws when
	 * `key` is empty or two options share a key.
	 */
	public function new(key:String,
			options:Array<SelectOption<T>>,
			value:T,
			?onChange:T->Void,
			?style:LayoutStyle,
			?placeholder:String,
			?onQueryChange:String->Void) {
		if (key == null || key.length == 0) throw "ComboBox requires a stable non-empty key";
		this.key = new Key(key);
		this.options = options == null ? [] : options.copy();
		var keys:Map<String, Bool> = new Map();
		for (option in this.options) {
			if (option == null || keys.exists(option.key)) throw "ComboBox option keys must be unique";
			keys.set(option.key, true);
		}
		this.value = value;
		hasChangeHandler = onChange != null;
		this.onChange = onChange == null ? function(_:T) {}
			: onChange;
		usesDefaultStyle = style == null;
		this.style = style == null ? defaultStyle() : style;
		if (this.style.height.sizing == LayoutSizing.Fit) this.style.height = LayoutAxis.fixed(40.0);
		this.placeholder = placeholder == null || placeholder.length == 0 ? "Search" : placeholder;
		this.onQueryChange = onQueryChange == null ? function(_:String) {}
			: onQueryChange;
		hasQueryChangeHandler = onQueryChange != null;
		enabled = true;
	}

	public function build(context:BuildContext):RenderNode {
		return context.withScope(key, function() {
			var rootStyle = style.copy();
			rootStyle.direction = LayoutDirection.TopToBottom;
			rootStyle.padding = new Insets(0.0, 0.0, 0.0, 0.0);
			rootStyle.childGap = 0.0;
			rootStyle.background = Color.rgba(0.0, 0.0, 0.0, 0.0);
			rootStyle.clipToParent = false;
			var root = context.createNode(context.rootId("combo-box"), LayoutVisualKind.Box, rootStyle);
			root.hitTestSelf = false;

			var rootXState:State<Float> = context.state(context.id("root-x"), 0.0);
			var rootYState:State<Float> = context.state(context.id("root-y"), 0.0);
			var triggerXState:State<Float> = context.state(context.id("trigger-x"), 0.0);
			var triggerYState:State<Float> = context.state(context.id("trigger-y"), 0.0);
			var triggerWidthState:State<Float> = context.state(context.id("trigger-width"), triggerHeightFallback());
			var triggerHeightState:State<Float> = context.state(context.id("trigger-height"), triggerHeightFallback());
			var anchorKnownState:State<Bool> = context.state(context.id("anchor-known"), false);
			var rememberFloat = function(state:State<Float>, value:Float) {
				var current:Float = state.value;
				if (!finite(current) || Math.abs(current - value) > 0.001) state.update(value);
			};
			root.onResolved(function(geometry) {
				if (finite(geometry.x) && finite(geometry.y)) {
					rememberFloat(rootXState, geometry.x);
					rememberFloat(rootYState, geometry.y);
				}
			});

			// The selected signal schedules an uncontrolled change; the view value remains the input.
			var selectedState:State<T> = context.state(context.id("value"), value);
			selectedState.value;
			var selectedIndex = enabledValueIndex(value);
			if (selectedIndex < 0) selectedIndex = firstEnabledIndex();
			if (selectedIndex >= 0 && !sameValue(value, options[selectedIndex].value)) {
				value = options[selectedIndex].value;
			}
			var selectedLabel = selectedIndex >= 0 ? options[selectedIndex].label : "";
			var labelState:State<String> = context.state(context.id("value-label"), selectedLabel);
			var queryState:State<String> = context.state(context.id("query"), selectedLabel);
			var storedLabel:String = labelState.value;
			var query:String = queryState.value;
			var followsSelection = query == storedLabel;
			if (storedLabel != selectedLabel && followsSelection) query = selectedLabel;
			if (storedLabel != selectedLabel) {
				var nextLabel = selectedLabel;
				root.onResolved(function(_) {
					labelState.update(nextLabel);
					if (followsSelection) queryState.update(nextLabel);
				});
			}

			var filteredIndices:Array<Int> = [];
			var loweredQuery = query == selectedLabel ? "" : query.toLowerCase();
			for (index in 0...options.length) {
				var label = options[index].label.toLowerCase();
				if (loweredQuery.length == 0 || label.indexOf(loweredQuery) >= 0) filteredIndices.push(index);
			}

			var openState:State<Bool> = context.state(context.id("open"), false);
			var isOpen:Bool = openState.value;
			if (!enabled || filteredIndices.length == 0) {
				if (isOpen) root.onResolved(function(_) openState.update(false));
				isOpen = false;
			}
			root.layout.style.zIndex = isOpen ? 10 : 0;
			var initialActive = filteredIndices.length == 0 ? -1 : filteredIndices[0];
			if (selectedIndex >= 0 && contains(filteredIndices, selectedIndex)) initialActive = selectedIndex;
			var activeState:State<Int> = context.state(context.id("active"), initialActive);
			var active:Int = activeState.value;
			if (!contains(filteredIndices, active)) active = initialActive;
			var storedActive:Int = activeState.value;
			if (active != storedActive) root.onResolved(function(_) activeState.update(active));

			var inputNode:RenderNode = null;
			// The open popup's option rows, so the trigger's keys can move focus into the list.
			var popupLink = context.lazyState(context.id("popup-link"),
				function() return new SelectionPopupLink()).value;
			var close = function() {
				if (openState.value == true) openState.update(false);
				if (inputNode != null) context.requestFocus(inputNode.id);
			};
			var setActive = function(index:Int) {
				if (contains(filteredIndices, index)) {
					var current:Int = activeState.value;
					if (index != current) {
						activeState.update(index);
						if (!context.updateInPlace) activeState.update(index);
					}
				}
			};
			var focusOption = function(index:Int) {
				if (index >= 0 && index < popupLink.optionIds.length) context.requestFocus(popupLink.optionIds[index]);
			};
			var selectOption = function(index:Int) {
				if (!enabled || !isEnabledIndex(index)) return;
				var option = options[index];
				var changed = !sameValue(value, option.value);
				value = option.value;
				selectedState.update(value);
				query = option.label;
				queryState.update(query);
				labelState.update(query);
				setActive(index);
				close();
				if (changed && hasChangeHandler) onChange(value);
			};
			var open = function() {
				if (!enabled || filteredIndices.length == 0) return;
				if (openState.value != true) openState.update(true);
				setActive(contains(filteredIndices, selectedIndex) ? selectedIndex : filteredIndices[0]);
			};
			var submitActive = function() {
				var submittedIndex:Int = activeState.value;
				if (contains(filteredIndices, submittedIndex)) selectOption(submittedIndex);
				else close();
			};

			var inputStyle = style.copy();
			if (usesDefaultStyle) inputStyle.background = context.theme.tokens.surface;
			inputStyle.width = LayoutAxis.grow();
			var input = new TextField("input", query, function(next) {
				query = next == null ? "" : next;
				queryState.update(query);
				if (hasQueryChangeHandler) onQueryChange(query);
				open();
			}, inputStyle, placeholder);
			input.classes = ["combo-trigger"];
			input.enabled = enabled;
			input.semanticRole = AccessibilityRole.ComboBox;
			input.semanticActions = AccessibilityAction.SetValue | AccessibilityAction.SetSelection | (isOpen
				? AccessibilityAction.Collapse : AccessibilityAction.Expand);
			input.semanticStates = AccessibilityState.HasPopup
				| (isOpen ? AccessibilityState.Expanded : AccessibilityState.empty());
			input.onSubmit = function(_) {
				if (openState.value != true) open();
				else submitActive();
			};
			inputNode = context.withScope(new Key("input"), function() return input.build(context));
			context.withStyleParent(inputNode.computedStyle, function() {
				inputNode.add(SelectionIndicator.fieldFrame("input-frame").build(context));
				inputNode.add(SelectionIndicator.search("input-search",
					enabled ? context.theme.tokens.textSecondary : context.theme.tokens.textDisabled).build(context));
			});
			inputNode.on(UiEventKind.PointerDown, function(event) {
				if (enabled && event.button == 0) open();
			});
			inputNode.on(UiEventKind.Activate, function(event) {
				if (!enabled) return;
				if (openState.value != true) open();
				else submitActive();
				event.preventDefault();
			});
			inputNode.on(UiEventKind.AccessibilitySetValue, function(event) {
				if (!enabled || event.text == null) return;
				for (index in 0...options.length) if (options[index].enabled
					&& (options[index].key == event.text || options[index].label == event.text)) {
					selectOption(index);
					event.preventDefault();
					return;
				}
			});
			inputNode.on(UiEventKind.KeyDown, function(event) {
				if (!enabled) return;
				if (event.key == UiKey.Escape && openState.value == true) {
					close();
					event.preventDefault();
					return;
				}
				if (event.key != UiKey.Down
					&& event.key != UiKey.Up && event.key != UiKey.Home && event.key != UiKey.End) return;
				if (filteredIndices.length == 0) return;
				var wasOpen:Bool = openState.value;
				if (!wasOpen) open();
				var next:Int = activeState.value;
				if (event.key == UiKey.Home) next = firstEnabledIn(filteredIndices);
				else if (event.key == UiKey.End) next = lastEnabledIn(filteredIndices);
				else if (wasOpen) {
					var currentActive:Int = activeState.value;
					next = nextEnabled(filteredIndices, currentActive, event.key == UiKey.Down ? 1 : -1);
				}
				setActive(next);
				if (wasOpen) focusOption(filteredPosition(filteredIndices, next));
				event.preventDefault();
			});
			// The arrow is a sibling of the editor, so its events cannot edit the
			// selection or bubble into the editor's open-on-click handler.
			var rowStyle = new LayoutStyle();
			rowStyle.width = LayoutAxis.grow();
			rowStyle.height = style.height;
			rowStyle.direction = LayoutDirection.LeftToRight;
			var triggerRow = context.createNode(context.rootId("trigger-row"), LayoutVisualKind.Box, rowStyle);
			triggerRow.hitTestSelf = false;
			triggerRow.add(inputNode);
			var anchorStyle = new LayoutStyle();
			anchorStyle.width = LayoutAxis.percent(0);
			anchorStyle.height = LayoutAxis.grow();
			var arrowAnchor = context.createNode(context.rootId("toggle-anchor"), LayoutVisualKind.Box, anchorStyle);
			arrowAnchor.hitTestSelf = false;
			var arrowStyle = new LayoutStyle();
			arrowStyle.width = LayoutAxis.fixed(32);
			arrowStyle.height = LayoutAxis.grow();
			arrowStyle.padding = new Insets(0, 0, 0, 0);
			var arrowSemantics = new Semantics(AccessibilityRole.Button, isOpen ? "Hide options" : "Show options");
			arrowSemantics.actions = AccessibilityAction.Activate | (isOpen
				? AccessibilityAction.Collapse : AccessibilityAction.Expand);
			arrowSemantics.states |= AccessibilityState.HasPopup;
			if (isOpen) arrowSemantics.states |= AccessibilityState.Expanded;
			var arrow = new Button("", arrowStyle, function() {
				if (openState.value == true) close();
				else {
					open();
					context.requestFocus(inputNode.id);
				}
			}, "toggle", enabled, ButtonVariant.Navigation, null, null, null, null, null,
				SelectionIndicator.chevron("toggle-indicator",
				enabled ? context.theme.tokens.textPrimary : context.theme.tokens.textDisabled,
				isOpen), null, null, null, isOpen ? "Hide options" : "Show options", null, arrowSemantics);
			var arrowModifier = new RootModifier();
			arrowModifier.positioning = haxeon.ui.LayoutStyle.LayoutPositioning.Absolute;
			arrowModifier.positionX = -32;
			arrowModifier.zIndex = 3;
			arrowModifier.clipToParent = false;
			arrowModifier.on(UiEventKind.KeyDown, function(event) {
				if (event.key == UiKey.Escape && openState.value == true) {
					close();
					event.preventDefault();
				}
			});
			var arrowNode = context.withScope(new Key("toggle"), function() return context.build(arrow, arrowModifier));
			arrowAnchor.add(arrowNode);
			triggerRow.add(arrowAnchor);
			root.add(triggerRow);
			inputNode.onResolved(function(geometry) {
				if (finite(geometry.x) && finite(geometry.y)
					&& finite(geometry.width) && finite(geometry.height) && geometry.width >= 0.0
					&& geometry.height >= 0.0) {
					rememberFloat(triggerXState, geometry.x);
					rememberFloat(triggerYState, geometry.y);
					rememberFloat(triggerWidthState, geometry.width);
					rememberFloat(triggerHeightState, geometry.height);
					if (anchorKnownState.value != true) anchorKnownState.update(true);
				}
			});

			root.focusTrap = isOpen;
			if (isOpen && filteredIndices.length > 0) {
				var anchorKnown:Bool = anchorKnownState.value;
				var popupRootX:Float = rootXState.value;
				var popupRootY:Float = rootYState.value;
				var popupTriggerX:Float = triggerXState.value;
				var popupTriggerY:Float = triggerYState.value;
				var popupTriggerWidth:Float = triggerWidthState.value;
				var popupTriggerHeight:Float = triggerHeightState.value;
				if (!anchorKnown) {
					popupRootX = 0.0;
					popupRootY = 0.0;
					popupTriggerX = 0.0;
					popupTriggerY = 0.0;
					popupTriggerWidth = fallbackWidth();
					popupTriggerHeight = triggerHeightFallback();
				}
				var popupOptions:Array<SelectOption<Dynamic>> = [];
				for (option in options) popupOptions.push(cast option);
				var popup = new SelectionPopup(popupOptions,
					filteredIndices, value, active, popupRootX, popupRootY, popupTriggerX, popupTriggerY,
					popupTriggerWidth, popupTriggerHeight, fallbackWidth(), triggerHeightFallback(), popupLink,
					function(index:Int) {
						selectOption(index);
					}, close, function(index:Int) {
					setActive(index);
				});
				root.add(context.build(popup));
				root.onPointerDownOutside(function(event) {
					if (event.button == 0) close();
				});
			}
			root.on(UiEventKind.KeyDown, function(event) {
				if (event.key == UiKey.Escape && openState.value == true) {
					close();
					event.preventDefault();
				}
			});
			return root;
		});
	}

	function enabledValueIndex(value:T):Int {
		for (index in 0...options.length) if (options[index].enabled && sameValue(options[index].value,
			value)) return index;
		return -1;
	}

	function firstEnabledIndex():Int {
		for (index in 0...options.length) if (options[index].enabled) return index;
		return -1;
	}

	function firstEnabledIn(indices:Array<Int>):Int {
		for (index in indices) if (isEnabledIndex(index)) return index;
		return -1;
	}

	function lastEnabledIn(indices:Array<Int>):Int {
		var position = indices.length - 1;
		while (position >= 0) {
			if (isEnabledIndex(indices[position])) return indices[position];
			position--;
		}
		return -1;
	}

	function isEnabledIndex(index:Int):Bool return index >= 0 && index < options.length && options[index].enabled;

	function filteredPosition(indices:Array<Int>, index:Int):Int {
		for (position in 0...indices.length) if (indices[position] == index) return position;
		return -1;
	}

	function nextEnabled(indices:Array<Int>, index:Int, direction:Int):Int {
		var position = filteredPosition(indices, index);
		if (position < 0 || indices.length == 0) return -1;
		for (_ in 0...indices.length) {
			position = (position + direction + indices.length) % indices.length;
			if (isEnabledIndex(indices[position])) return indices[position];
		}
		return index;
	}

	function triggerHeightFallback():Float return style.height.sizing == LayoutSizing.Fixed
		&& style.height.value > 0.0 ? style.height.value : 40.0;

	function fallbackWidth():Float return style.width.sizing == LayoutSizing.Fixed
		&& style.width.value > 0.0 ? style.width.value : 240.0;

	static function contains(values:Array<Int>, value:Int):Bool {
		for (entry in values) if (entry == value) return true;
		return false;
	}

	static inline function finite(value:Float):Bool return value == value && value - value == 0.0;

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.fixed(240.0);
		result.height = LayoutAxis.fixed(40.0);
		result.clipHorizontal = true;
		return result;
	}

	static function sameValue(left:Dynamic, right:Dynamic):Bool return left == right;
}

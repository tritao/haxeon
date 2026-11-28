package haxeon.ui.widgets.controls;
import haxeon.ui.core.ViewRoot;

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
import haxeon.ui.widgets.controls.SelectionPopup;

/** Typed single-selection control with a positioned, keyboard-navigable option list. */
class Select<T> implements View {
	final key:Key;
	/** The choices, each with a unique key, in the order the list shows them. */
	public final options:Array<SelectOption<T>>;

	/** The selected option's value. */
	public final value:T;

	/** Whether the control reacts to input. */
	public final enabled:Bool;

	/** The control's box; 36 pixels high unless it sets a height. */
	public final style:LayoutStyle;

	/** Called with the value of the option the user picks. */
	public final onChange:T->Void;
	var hasChangeHandler:Bool;

	/** The control's accessible name; without one it is named by the selected option. */
	public final accessibilityLabel:Null<String>;

	/**
	 * A drop-down list of `options` showing the one whose value is `value`. Throws when `key` is empty or two options
	 * share a key.
	 */
	public function new(key:String, options:Array<SelectOption<T>>, value:T, ?onChange:T->Void, ?style:LayoutStyle,
			enabled:Bool = true, ?accessibilityLabel:String) {
		if (key == null || key.length == 0) throw "Select requires a stable non-empty key";
		this.key = new Key(key);
		this.options = options == null ? [] : options.copy();
		this.value = value;
		hasChangeHandler = onChange != null;
		this.onChange = onChange == null ? (_:T) -> {}
			: onChange;
		this.style = style == null ? defaultStyle() : style.copy();
		if (this.style.height.sizing == LayoutSizing.Fit) this.style.height = LayoutAxis.fixed(36.0);

		var keys:Map<String, Bool> = new Map();
		for (option in this.options) {
			if (option == null || keys.exists(option.key)) throw "Select option keys must be unique";
			keys.set(option.key, true);
		}
		this.enabled = enabled;
		this.accessibilityLabel = accessibilityLabel;
	}

	public function build(context:BuildContext):ViewRoot {
		// What the user picks while this build is shown; the field stays the caller's input.
		var value = this.value;
		return context.withScope(key, () -> {
			var rootStyle = style.copy();
			rootStyle.direction = LayoutDirection.TopToBottom;
			rootStyle.padding = new Insets(0.0, 0.0, 0.0, 0.0);
			rootStyle.childGap = 0.0;
			rootStyle.background = Color.rgba(0.0, 0.0, 0.0, 0.0);
			rootStyle.clipToParent = false;
			var root = context.createNode(context.rootId("select"), LayoutVisualKind.Box, rootStyle);
			root.hitTestSelf = false;

			// The user's last choice, until the caller gives a different value.
			var chosen = context.adopted("value", value);
			value = chosen.value;
			var selectedIndex = enabledValueIndex(value);
			if (selectedIndex < 0) selectedIndex = firstEnabledIndex();
			if (selectedIndex >= 0 && !sameValue(value, options[selectedIndex].value)) {
				value = options[selectedIndex].value;
			}

			var openState:State<Bool> = context.state(context.id("open"), false);
			var isOpen:Bool = openState.value;
			var firstEnabled = firstEnabledIndex();
			if (!enabled || firstEnabled < 0) {
				if (isOpen) context.afterBuild(() -> openState.update(false));
				isOpen = false;
			}
			root.layout.style.zIndex = isOpen ? 10 : 0;

			var initialActive = selectedIndex >= 0 ? selectedIndex : firstEnabled;
			var activeState:State<Int> = context.state(context.id("active"), initialActive);
			var active:Int = activeState.value;
			if (!isEnabledIndex(active)) active = initialActive;
			var storedActive:Int = activeState.value;
			if (active != storedActive) context.afterBuild(() -> activeState.update(active));

			var triggerNode:Null<ViewRoot> = null;
			// The open popup's option rows, so the trigger's keys can move focus into the list.
			var popupLink = context.lazyState(context.id("popup-link"),
				() -> new SelectionPopupLink()).value;
			var close = () -> {
				if (openState.value == true) openState.update(false);
				if (triggerNode != null) context.requestFocus(triggerNode.id);
			};
			var setActive = (index:Int) -> {
				var current:Int = activeState.value;
				if (isEnabledIndex(index)) {
					if (index != current) {
						activeState.update(index);
						if (!context.updateInPlace) activeState.update(index);
					}
				}
			};
			var focusOption = (index:Int) -> {
				if (index >= 0 && index < popupLink.optionIds.length) context.requestFocus(popupLink.optionIds[index]);
			};
			var nextEnabled = (index:Int, direction:Int) -> {
				if (options.length == 0) return -1;
				var candidate = index;
				for (_ in 0...options.length) {
					candidate = (candidate + direction + options.length) % options.length;
					if (isEnabledIndex(candidate)) return candidate;
				}
				return index;
			};
			var selectOption = (index:Int) -> {
				if (!enabled || !isEnabledIndex(index)) return;
				var option = options[index];
				var changed = !sameValue(value, option.value);
				value = option.value;
				chosen.set(value);
				setActive(index);
				close();
				if (changed && hasChangeHandler) onChange(value);
			};
			var toggleOpen = () -> {
				if (!enabled || firstEnabled < 0) return;
				if (openState.value == true) close();
				else {
					openState.update(true);
					setActive(selectedIndex >= 0 ? selectedIndex : firstEnabled);
				}
			};

			var selectedLabel = selectedIndex >= 0 ? options[selectedIndex].label : "Select";
			if (selectedLabel.length == 0) selectedLabel = "Select";
			var triggerStyle = style.copy();
			triggerStyle.width = LayoutAxis.grow();
			var triggerSemantics = new Semantics(AccessibilityRole.ComboBox,
				accessibilityLabel == null ? selectedLabel : accessibilityLabel,
				selectedLabel);
			triggerSemantics.actions = AccessibilityAction.Activate | AccessibilityAction.SetValue | (isOpen
				? AccessibilityAction.Collapse : AccessibilityAction.Expand);
			triggerSemantics.states |= AccessibilityState.HasPopup;
			if (isOpen) triggerSemantics.states |= AccessibilityState.Expanded;
			var trigger = new Button(selectedLabel,
				triggerStyle,
				toggleOpen,
				"trigger",
				enabled && firstEnabled >= 0,
				null,
				null,
				["select-trigger"],
				null,
				null,
				null,
				SelectionIndicator.chevron("trigger-indicator",
				enabled ? context.theme.tokens.textPrimary : context.theme.tokens.textDisabled,
				isOpen,
				true),
				null,
				true,
				null,
				null,
				null,
				triggerSemantics);
			var triggerModifier = new RootModifier();
			triggerModifier.on(UiEventKind.KeyDown, event -> {
				if (!enabled || firstEnabled < 0) return;
				if (event.key == UiKey.Escape && openState.value == true) {
					close();
					event.preventDefault();
					return;
				}
				if (event.key != UiKey.Down
					&& event.key != UiKey.Up && event.key != UiKey.Home && event.key != UiKey.End) return;
				var wasOpen:Bool = openState.value;
				if (!wasOpen) openState.update(true);
				var base = selectedIndex >= 0 ? selectedIndex : firstEnabled;
				var next:Int = base;
				if (event.key == UiKey.Home) next = firstEnabled;
				else if (event.key == UiKey.End) next = lastEnabledIndex();
				else if (wasOpen) next = nextEnabled(activeState.value, event.key == UiKey.Down ? 1 : -1);
				setActive(next);
				if (wasOpen) focusOption(next);
				event.preventDefault();
			});
			triggerModifier.on(UiEventKind.AccessibilitySetValue, event -> {
				if (!enabled || event.text == null) return;
				for (index in 0...options.length) if (options[index].enabled
					&& (options[index].key == event.text || options[index].label == event.text)) {
					selectOption(index);
					event.preventDefault();
					return;
				}
			});
			var builtTrigger = context.withScope(new Key("trigger"),
				() -> context.build(trigger, triggerModifier));
			triggerNode = builtTrigger;
			root.add(builtTrigger);

			root.focusTrap = isOpen;
			if (isOpen) {
				var visibleIndices:Array<Int> = [];
				for (index in 0...options.length) visibleIndices.push(index);
				var popupOptions:Array<SelectOption<Dynamic>> = [];
				for (option in options) popupOptions.push(cast option);
				var popup = new SelectionPopup(popupOptions,
					visibleIndices, value, active, builtTrigger.id, popupLink,
					(index:Int) -> {
						selectOption(index);
					}, close, (index:Int) -> {
					setActive(index);
				});
				root.add(context.build(popup));
				root.onPointerDownOutside(event -> {
					if (event.button == 0) close();
				});
			}
			root.on(UiEventKind.KeyDown, event -> {
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

	function lastEnabledIndex():Int {
		var index = options.length - 1;
		while (index >= 0) {
			if (options[index].enabled) return index;
			index--;
		}
		return -1;
	}

	function isEnabledIndex(index:Int):Bool return index >= 0 && index < options.length && options[index].enabled;

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.fixed(240.0);
		result.height = LayoutAxis.fixed(40.0);
		return result;
	}

	static function sameValue(left:Dynamic, right:Dynamic):Bool return left == right;
}

/** Immutable typed option used by Select. */
class SelectOption<T> {
	/** Identifies the option within its list. */
	public final key:String;

	/** The text the list shows for it. */
	public final label:String;

	/** The value choosing it selects. */
	public final value:T;

	/** Whether it can be chosen. */
	public final enabled:Bool;

	/** An option for a `Select` or `ComboBox`. Throws when `key` is empty. */
	public function new(key:String, label:String, value:T, enabled:Bool = true) {
		if (key == null || key.length == 0)
			throw "Select options require stable non-empty keys";
		this.key = key;
		this.label = label == null ? "" : label;
		this.value = value;
		this.enabled = enabled;
	}
}

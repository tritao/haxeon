package haxeon.ui.widgets.properties;

import Observable;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.IconButton;
import haxeon.ui.widgets.controls.Select;
import haxeon.ui.widgets.controls.SelectOption;
import haxeon.ui.widgets.controls.Slider;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;

import haxeon.ui.LayoutAlignmentY;
import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutDirection;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.CommandContext;
import haxeon.ui.core.Key;
import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyBinding;
import haxeon.ui.properties.PropertyEditResult;
import haxeon.ui.properties.PropertyEditorRegistry;
import haxeon.ui.properties.PropertyType;
import haxeon.ui.properties.PropertyValue;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.WidgetId;
import haxeon.ui.core.View;
import haxeon.ui.icons.IconName;
import haxeon.ui.LayoutVisualKind;
import haxeon.ui.style.StyleTarget;

/** Descriptor-driven inspector that routes edits through the active document. */
class PropertyEditor implements View implements Observable {
	/** Private input templates: their consumers copy the style before exposing it. */
	static final GrowInputStyle:LayoutStyle = makeInputStyle(0.0);
	static final FieldInputStyle:LayoutStyle = makeInputStyle(64.0);
	static final NumericRowStyle:LayoutStyle = makeNumericRowStyle();

	static function makeInputStyle(min:Float):LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow(min);
		return result;
	}

	static function makeNumericRowStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.direction = LayoutDirection.LeftToRight;
		result.childAlignY = LayoutAlignmentY.Center;
		result.childGap = 6.0;
		return result;
	}

	/** Used only by privately built text views, which read rather than expose or mutate it. */
	@:allow(haxeon.ui.widgets.properties.PropertyEditorRowContent)
	function labelStyle():LayoutStyle {
		var cached = options.cachedLabelStyle;
		if (cached == null || options.cachedLabelStacked != options.stackedRows || options.cachedLabelWidth != options.labelWidth) {
			cached = new LayoutStyle();
			cached.width = options.stackedRows ? LayoutAxis.grow() : LayoutAxis.fixed(options.labelWidth);
			options.cachedLabelStyle = cached;
			options.cachedLabelWidth = options.labelWidth;
			options.cachedLabelStacked = options.stackedRows;
		}
		return cached;
	}
	static var nextGeneration:Int = 0;
	public final key:String;
	public final descriptors:Array<PropertyDescriptor>;
	public final style:LayoutStyle;
	public final registry:PropertyEditorRegistry;
	final generation:Int;
	@:unobservable public var revision(default, null):Int;
	@:allow(haxeon.ui.widgets.properties.PropertyEditorRow)
	final rowIds:Map<String, WidgetId> = new Map();
	final options:PropertyEditorOptions;
	final drafts:Map<String, String>;
	final errors:Map<String, String>;
	final pending:Map<String, haxeon.ui.properties.PropertyPendingEdit> = new Map();

	public function new(key:String, descriptors:Array<PropertyDescriptor>, ?style:LayoutStyle,
		?registry:PropertyEditorRegistry) {
		if (key == null || key.length == 0)
			throw "Property editors require a stable key";
		nextGeneration++;
		generation = nextGeneration;
		this.key = key;
		this.descriptors = descriptors == null ? [] : descriptors.copy();
		var ids:Map<String, Bool> = new Map();
		for (descriptor in this.descriptors) {
			if (descriptor == null || ids.exists(descriptor.id))
				throw "Property descriptor IDs must be unique";
			ids.set(descriptor.id, true);
		}
		this.style = style == null ? defaultStyle() : style.copy();
		this.registry = registry == null ? new PropertyEditorRegistry() : registry;
		options = new PropertyEditorOptions();
		revision = 0;
		drafts = new Map();
		errors = new Map();
	}

	public function configure(enabled:Bool, labelWidth:Float, stackedRows:Bool, searchQuery:String):Void {
		options.enabled = enabled;
		options.labelWidth = labelWidth;
		options.stackedRows = stackedRows;
		options.searchQuery = searchQuery;
	}

	public function showCategoryHeaders(value:Bool):Void
		options.showCategories = value;

	/** Applies through the document or external transaction owner. Pending returns false. */
	public function applyValue(context:BuildContext, descriptor:PropertyDescriptor,
			next:PropertyValue, ?coalesceKey:String):Bool {
			if (!options.enabled || context == null || descriptor == null || pending.exists(descriptor.id))
			return false;
		var commandContext = context.commandContext == null ? new CommandContext() : context.commandContext;
		var result = new PropertyBinding(descriptor, commandContext, registry).apply(next, coalesceKey);
		switch result {
			case Pending(edit):
				pending.set(descriptor.id, edit); revision++;
				requestRowPatch(context, descriptor.id);
				edit.onComplete(done -> {
					if (pending.get(descriptor.id) != edit) return;
					pending.remove(descriptor.id);
					finishValue(context, descriptor, done);
				});
				return false;
			default: return finishValue(context, descriptor, result);
		}
	}

	function finishValue(context:BuildContext, descriptor:PropertyDescriptor, result:PropertyEditResult):Bool {
		revision++;
		requestRowPatch(context, descriptor.id);
		switch result {
			case Rejected(message): errors.set(descriptor.id, message);
			case Applied | Unchanged:
				drafts.remove(descriptor.id); errors.remove(descriptor.id);
			case Pending(_): throw "Expected a completed edit";
		}
		return switch result { case Applied: true; default: false; };
	}

	public function resetValue(context:BuildContext, descriptor:PropertyDescriptor):Void {
		var reset = descriptor.reset;
		if (reset == null) {
			applyValue(context, descriptor, descriptor.defaultValue);
			return;
		}
		reset();
		drafts.remove(descriptor.id);
		errors.remove(descriptor.id);
		revision++;
		requestRowPatch(context, descriptor.id);
	}

	public function build(context:BuildContext):RenderNode {
		if (options.cachedColumn == null || options.cachedShowCategories != options.showCategories) {
			var children:Array<KeyedView> = [];
			var categoryKeys:Map<String, Bool> = new Map();
			for (descriptor in descriptors) {
				var category = descriptor.category;
				if (options.showCategories && category.length > 0 && !categoryKeys.exists(category)) {
					categoryKeys.set(category, true);
					children.push(new KeyedView("category:" + category,
						new Text(category)));
				}
				children.push(new KeyedView("property:" + descriptor.id,
					new PropertyEditorRow(this, descriptor)));
			}
			options.cachedChildren = children;
			options.cachedShowCategories = options.showCategories;
			options.cachedColumn = new Column(key, children, style);
		}
		return options.cachedColumn.build(context);
	}

	function setDraft(descriptor:PropertyDescriptor, value:String):Void
		{
			var next = value == null ? "" : value;
			if (drafts.exists(descriptor.id) && drafts.get(descriptor.id) == next) return;
			drafts.set(descriptor.id, next);
			revision++;
		}

	/** A detached inspector may reuse this editor only if no draft, error, or edit has occurred. */
	@:allow(haxeon.ui.widgets.properties.PropertyInspector)
	function isPristine():Bool
		return revision == 0 && !drafts.keys().hasNext() && !errors.keys().hasNext() && !pending.keys().hasNext();

	function draftOrValue(descriptor:PropertyDescriptor, value:PropertyValue):String
		return drafts.exists(descriptor.id) ? drafts.get(descriptor.id) :
			registry.editableText(value);

	function commitText(context:BuildContext, descriptor:PropertyDescriptor, text:String):Void {
		var parsed = registry.parse(descriptor.type, text);
		if (parsed == null) {
			if (errors.get(descriptor.id) != "Value is not valid")
				revision++;
			errors.set(descriptor.id, "Value is not valid");
			requestRowPatch(context, descriptor.id);
			return;
		}
		applyValue(context, descriptor, parsed);
	}

	function requestRowPatch(context:BuildContext, id:String):Void {
		var row = rowIds.get(id);
		if (row != null) context.requestPatch(row);
	}

	/** The row's visible label, which also names its control for assistive technology. */
	public static function accessibleName(descriptor:PropertyDescriptor):String
		return descriptor.unit == null ? descriptor.label : descriptor.label + " (" + descriptor.unit + ")";

	public function errorFor(id:String):Null<String>
		return errors.get(id);

	function editorView(context:BuildContext, descriptor:PropertyDescriptor,
			value:PropertyValue):View {
		var editorKey = "editor:" + descriptor.id;
		var writable = options.enabled && !descriptor.readOnly && !pending.exists(descriptor.id);
		if (isMixed(value)) {
			if (descriptor.type == PropertyType.Bool || descriptor.type == PropertyType.Enum)
				return mixedChoice(context, descriptor, editorKey, writable);
			return textField(context, descriptor, value, editorKey, writable);
		}
		var result:View = null;
		switch (descriptor.type) {
			case PropertyType.Bool:
				var checked = false;
				switch (value) {
					case Bool(data): checked = data;
					default: checked = false;
				}
				var checkbox = new Checkbox(editorKey, "", checked, function(next) {
					applyValue(context, descriptor, PropertyValue.Bool(next));
				});
				checkbox.enabled = writable;
				checkbox.accessibilityLabel = accessibleName(descriptor);
				result = checkbox;
			case PropertyType.Enum:
				var selected = descriptor.options.length == 0 ? "" : descriptor.options[0].key;
				switch (value) {
					case Enum(data): selected = data;
					default: selected = selected;
				}
				var enumOptions:Array<SelectOption<String>> = [];
				for (option in descriptor.options)
					enumOptions.push(new SelectOption<String>(option.key, option.label,
						option.key, option.enabled));
				var select = new Select<String>(editorKey, enumOptions, selected, function(next) {
					applyValue(context, descriptor, PropertyValue.Enum(next));
				}, GrowInputStyle);
				select.enabled = writable;
				select.accessibilityLabel = accessibleName(descriptor);
				result = select;
			case PropertyType.Int | PropertyType.Float:
				result = numericEditor(context, descriptor, value, editorKey, writable);
			case PropertyType.Text:
				result = textField(context, descriptor, value, editorKey, writable);
			case PropertyType.Custom(typeId):
				var extension = registry.get(typeId);
				result = extension == null ? new Text("No editor for " + typeId) :
					extension.build(editorKey, descriptor, value, context, writable,
						function(next) { applyValue(context, descriptor, next); });
		}
		return result;
	}

	function mixedChoice(context:BuildContext, descriptor:PropertyDescriptor,
			editorKey:String, writable:Bool):View {
		var choices:Array<SelectOption<String>> = [];
		if (descriptor.type == PropertyType.Bool) {
			choices.push(new SelectOption<String>("__mixed__", "Mixed", "__mixed__"));
			choices.push(new SelectOption<String>("false", "false", "false"));
			choices.push(new SelectOption<String>("true", "true", "true"));
		} else {
			choices.push(new SelectOption<String>("__mixed__", "Mixed", "__mixed__"));
			for (option in descriptor.options)
				choices.push(new SelectOption<String>(option.key, option.label,
					option.key, option.enabled));
		}
		var select = new Select<String>(editorKey, choices, "__mixed__", function(next) {
			if (next == "__mixed__")
				return;
			if (descriptor.type == PropertyType.Bool)
				applyValue(context, descriptor, PropertyValue.Bool(next == "true"));
			else
				applyValue(context, descriptor, PropertyValue.Enum(next));
		});
		select.enabled = writable;
		select.accessibilityLabel = accessibleName(descriptor);
		return select;
	}

	function numericEditor(context:BuildContext, descriptor:PropertyDescriptor,
			value:PropertyValue, editorKey:String, writable:Bool):View {
		var number:Null<Float> = null;
		switch (value) {
			case PropertyValue.Int(data): number = data;
			case PropertyValue.Float(data): number = data;
			default: number = null;
		}
		if (number == null || descriptor.minimum == null || descriptor.maximum == null)
			return textField(context, descriptor, value, editorKey, writable);
		var step = descriptor.step == null ? 0.01 : descriptor.step;
		var slider = new Slider(editorKey + ":slider", accessibleName(descriptor), number,
			descriptor.minimum, descriptor.maximum, step, function(next) {
				if (descriptor.type == PropertyType.Int)
					applyValue(context, descriptor, PropertyValue.Int(Std.int(next)));
				else
					applyValue(context, descriptor, PropertyValue.Float(next));
			}, GrowInputStyle);
		slider.enabled = writable;
		return new Row(editorKey + ":numeric", [
			new KeyedView("slider", slider),
			new KeyedView("text", textField(context, descriptor, value,
				editorKey + ":text", writable))
		], NumericRowStyle);
	}

	function textField(context:BuildContext, descriptor:PropertyDescriptor,
			value:PropertyValue, editorKey:String, writable:Bool):View {
		var field = new TextField(editorKey, draftOrValue(descriptor, value), function(next) {
			setDraft(descriptor, next);
		}, FieldInputStyle);
		field.classes = ["property-input"];
		field.enabled = writable;
		field.label = accessibleName(descriptor);
		field.placeholder = isMixed(value) ? "Mixed" : null;
		field.onSubmit = function(next) {
			commitText(context, descriptor, next);
		};
		return field;
	}

	static function isMixed(value:PropertyValue):Bool {
		var result = false;
		switch (value) {
			case Mixed: result = true;
			default: result = false;
		}
		return result;
	}

	static function defaultStyle():LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.fit();
		result.direction = LayoutDirection.TopToBottom;
		result.childGap = 6.0;
		return result;
	}
}

private class PropertyEditorRow implements View {
	final owner:PropertyEditor;
	final descriptor:PropertyDescriptor;

	public function new(owner:PropertyEditor, descriptor:PropertyDescriptor) {
		this.owner = owner;
		this.descriptor = descriptor;
	}

	public function build(context:BuildContext):RenderNode {
		var id = context.id("property-row-root");
		owner.rowIds.set(descriptor.id, id);
		return context.selfUpdating(id, function() return buildRow(context, id), false);
	}

	function buildRow(context:BuildContext, id:WidgetId):RenderNode {
		var value = descriptor.readValue();
		return new PropertyEditorRowContent(owner, descriptor, value).buildWithId(context, id);
	}
}

private class PropertyEditorRowContent implements View {
	static final RootKey:Key = new Key("row");
	/** Row and detail constructors copy these private templates; text views only read the detail template. */
	static final RowCenter:LayoutStyle = makeRow(false, false);
	static final RowStart:LayoutStyle = makeRow(false, true);
	static final ColumnCenter:LayoutStyle = makeRow(true, false);
	static final ColumnStart:LayoutStyle = makeRow(true, true);
	static final DetailTextStyle:LayoutStyle = makeDetail(false);
	static final DetailColumnStyle:LayoutStyle = makeDetail(true);

	static function makeRow(stacked:Bool, custom:Bool):LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		result.height = LayoutAxis.fit();
		result.direction = stacked ? LayoutDirection.TopToBottom : LayoutDirection.LeftToRight;
		result.childAlignY = custom ? LayoutAlignmentY.Start : LayoutAlignmentY.Center;
		result.childGap = 8.0;
		return result;
	}

	static function makeDetail(column:Bool):LayoutStyle {
		var result = new LayoutStyle();
		result.width = LayoutAxis.grow();
		if (column) {
			result.height = LayoutAxis.fit();
			result.childGap = 2.0;
		}
		return result;
	}

	final owner:PropertyEditor;
	final descriptor:PropertyDescriptor;
	final value:PropertyValue;

	public function new(owner:PropertyEditor, descriptor:PropertyDescriptor, value:PropertyValue) {
		this.owner = owner;
		this.descriptor = descriptor;
		this.value = value;
	}

	public function build(context:BuildContext):RenderNode
		return buildWithId(context, null);

	function buildRoot(context:BuildContext, id:Null<WidgetId>, children:Array<KeyedView>, style:LayoutStyle):RenderNode {
		return context.withScope(RootKey, function() {
			var rootId = id == null ? context.id("column") : id;
			var computed = context.resolveStyle(new StyleTarget("column", "row", "row", null, ["column"],
				context.interactionStates.get(rootId)), style);
			var node = new RenderNode(rootId, LayoutVisualKind.Box, computed.toLayoutStyle());
			node.setStyleIdentity("column", "row", "row", null, ["column"]);
			node.states = context.interactionStates.get(rootId);
			node.computedStyle = computed;
			for (child in children)
				node.add(context.withStyleParent(computed, function() return child.build(context)));
			return node;
		});
	}

	public function buildWithId(context:BuildContext, id:Null<WidgetId>):RenderNode {
		var observed = context.buildProbe != null;
		var started = observed ? Sys.time() : 0.0;
		var labelStyle = owner.labelStyle();
		var custom = switch descriptor.type { case Custom(_): true; default: false; };
		var rowStyle = owner.options.stackedRows ? (custom ? ColumnStart : ColumnCenter) : (custom ? RowStart : RowCenter);
		var children:Array<KeyedView> = [
			new KeyedView("label", new haxeon.ui.widgets.text.HighlightedText(PropertyEditor.accessibleName(descriptor), owner.options.searchQuery, labelStyle)),
			new KeyedView("value", owner.editorView(context, descriptor, value))
		];
		var isModified = descriptor.modified;
		var modified = isModified != null ? isModified() :
			descriptor.defaultValue != null && !owner.registry.same(value, descriptor.defaultValue);
		if (descriptor.modified != null && modified)
			children.push(new KeyedView("modified", new Text("Modified")));
		if (descriptor.defaultValue != null && !descriptor.readOnly
			&& modified) {
			var reset = new IconButton("reset", IconName.Reset, "Reset " + descriptor.label + " to default",
				function() owner.resetValue(context, descriptor), null,
				owner.options.enabled && !owner.pending.exists(descriptor.id));
			children.push(new KeyedView("reset", reset));
		}
		var error = owner.errorFor(descriptor.id);
		if (error == null && descriptor.description == null && !descriptor.restartRequired && StringTools.trim(owner.options.searchQuery).length == 0) {
			var result = buildRoot(context, id, children, rowStyle);
			if (observed) context.reportBuild("property:" + descriptor.id, 0.0, Sys.time() - started, result);
			return result;
		}
		var row:View = owner.options.stackedRows ? new Column("row", children, rowStyle) : new Row("row", children, rowStyle);
		var errorStyle = DetailTextStyle;
		var details:Array<KeyedView> = [new KeyedView("field", row)];
		if (descriptor.description != null && descriptor.description.length > 0)
			details.push(new KeyedView("description", new haxeon.ui.widgets.text.HighlightedText(descriptor.description, owner.options.searchQuery, errorStyle, context.theme.tokens.textSecondary,
				haxeon.ui.core.TextStyleOverride.paragraph(haxeon.ui.TextWrap.WordCharacter), haxeon.ui.theme.TextRole.Caption)));
		if (StringTools.trim(owner.options.searchQuery).length > 0)
			details.push(new KeyedView("path", new haxeon.ui.widgets.text.HighlightedText(descriptor.id, owner.options.searchQuery, errorStyle,
				context.theme.tokens.textSecondary, null, haxeon.ui.theme.TextRole.Caption)));
		if (descriptor.restartRequired)
			details.push(new KeyedView("restart", new Text("Requires restart", errorStyle)));
		if (error != null) details.push(new KeyedView("message", new Text(error, errorStyle)));
		var result = buildRoot(context, id, details, DetailColumnStyle);
		if (observed)
			context.reportBuild("property:" + descriptor.id, 0.0, Sys.time() - started, result);
		return result;
	}
}


/** Mutable view configuration and local caches stay outside the observable editor state. */
private class PropertyEditorOptions {
	public var enabled:Bool = true;
	public var labelWidth:Float = 140.0;
	public var stackedRows:Bool = false;
	public var searchQuery:String = "";
	public var showCategories:Bool = true;
	public var cachedLabelStyle:Null<LayoutStyle>;
	public var cachedLabelWidth:Float = 0.0;
	public var cachedLabelStacked:Bool = false;
	public var cachedChildren:Null<Array<KeyedView>>;
	public var cachedShowCategories:Null<Bool>;
	public var cachedColumn:Null<Column>;
}

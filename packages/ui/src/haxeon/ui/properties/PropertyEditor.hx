package haxeon.ui.properties;
import haxeon.ui.core.ViewRoot;
import haxeon.ui.style.StyleIdentity;

import Observable;
import haxeon.ui.widgets.KeyedView;
import haxeon.ui.widgets.controls.Checkbox;
import haxeon.ui.widgets.controls.IconButton;
import haxeon.ui.widgets.controls.Select;
import haxeon.ui.widgets.controls.Slider;
import haxeon.ui.widgets.layout.Column;
import haxeon.ui.widgets.layout.Row;
import haxeon.ui.widgets.text.Text;
import haxeon.ui.widgets.text.TextField;

import haxeon.ui.LayoutAxis;
import haxeon.ui.LayoutNode;
import haxeon.ui.LayoutStyle;
import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Command;
import haxeon.ui.core.Key;
import haxeon.ui.core.RenderNode;
import haxeon.ui.core.RenderScope;
import haxeon.ui.core.View;
import haxeon.ui.core.WidgetId;
import haxeon.ui.icons.IconName;
import haxeon.ui.properties.PropertyBinding;
import haxeon.ui.properties.PropertyDescriptor;
import haxeon.ui.properties.PropertyEditorRegistry;
import haxeon.ui.properties.PropertyValue;

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
	@:allow(haxeon.ui.properties.PropertyEditorRowContent) function labelStyle():LayoutStyle {
		var cached = options.cachedLabelStyle;
		if (cached == null
			|| options.cachedLabelStacked != options.stackedRows || options.cachedLabelWidth != options.labelWidth) {
			cached = new LayoutStyle();
			cached.width = options.stackedRows ? LayoutAxis.grow() : LayoutAxis.fixed(options.labelWidth);
			options.cachedLabelStyle = cached;
			options.cachedLabelWidth = options.labelWidth;
			options.cachedLabelStacked = options.stackedRows;
		}
		return cached;
	}
	static var nextGeneration:Int = 0;

	/** Identifies the editor among its siblings, so its state survives rebuilds: required, and never empty. */
	public final key:String;

	/** The properties edited, in order. */
	public final descriptors:Array<PropertyDescriptor>;

	/** The editor's box. */
	public final style:LayoutStyle;

	/** Which control edits each kind of value, including the application's own. */
	public final registry:PropertyEditorRegistry;
	final generation:Int;

	/** Counts the edits started and finished, so a host can tell when the editor's state changed. */
	@:unobservable public var revision(default, null):Int;
	// The rows' content, a private class of this module, reads the options, the row states and the editors it lays out.
	@:allow(haxeon.ui.properties)
	final options:PropertyEditorOptions;
	/** Each row's edit state, by descriptor ID: a row depends on what it shows of it. */
	@:allow(haxeon.ui.properties)
	final rows:Map<String, PropertyRowState>;

	/** An editor of `descriptors`, one row each. Throws when `key` is empty. */
	public function new(key:String,
			descriptors:Array<PropertyDescriptor>,
			?style:LayoutStyle,
			?registry:PropertyEditorRegistry) {
		if (key == null || key.length == 0) throw "Property editors require a stable key";
		nextGeneration++;
		generation = nextGeneration;
		this.key = key;
		this.descriptors = descriptors == null ? [] : descriptors.copy();
		rows = new Map();
		for (descriptor in this.descriptors) {
			if (descriptor == null || rows.exists(descriptor.id)) throw "Property descriptor IDs must be unique";
			rows.set(descriptor.id, new PropertyRowState());
		}
		this.style = style == null ? defaultStyle() : style.copy();
		this.registry = registry == null ? new PropertyEditorRegistry() : registry;
		options = new PropertyEditorOptions();
		revision = 0;
	}

	/**
	 * Sets whether the rows take input, the label column's width, whether labels sit above their controls, and the
	 * search text that filters the rows.
	 */
	public function configure(enabled:Bool, labelWidth:Float, stackedRows:Bool, searchQuery:String):Void {
		options.enabled = enabled;
		options.labelWidth = labelWidth;
		options.stackedRows = stackedRows;
		options.searchQuery = searchQuery;
	}

	/** Whether category headings separate the rows. */
	public function showCategoryHeaders(value:Bool):Void options.showCategories = value;

	/** Applies through the document or external transaction owner. Pending returns false. */
	public function applyValue(context:BuildContext,
			descriptor:PropertyDescriptor,
			next:PropertyValue,
			?coalesceKey:String):Bool {
		if (!options.enabled || context == null || descriptor == null) return false;
		var row = rowState(descriptor);
		if (row.pending != null) return false;
		var commandContext = context.commandContext == null ? new CommandContext() : context.commandContext;
		var result = new PropertyBinding(descriptor, commandContext, registry).apply(next, coalesceKey);
		switch result {
			case Pending(edit):
				row.pending = edit;
				revision++;
				edit.onComplete(done -> {
					if (row.pending != edit) return;
					row.pending = null;
					finishValue(context, descriptor, done);
				});
				return false;
			default:
				return finishValue(context, descriptor, result);
		}
	}

	function finishValue(context:BuildContext, descriptor:PropertyDescriptor, result:PropertyEditResult):Bool {
		revision++;
		var row = rowState(descriptor);
		switch result {
			case Rejected(message):
				row.error = message;
			case Applied | Unchanged:
				row.draft = null;
				row.error = null;
			case Pending(_):
				throw "Expected a completed edit";
		}
		return switch result {
			case Applied:
				true;
			default:
				false;
		};
	}

	/** Sets the property back to its default, through the document like an edit. */
	public function resetValue(context:BuildContext, descriptor:PropertyDescriptor):Void {
		var reset = descriptor.reset;
		if (reset == null) {
			applyValue(context, descriptor, descriptor.defaultValue);
			return;
		}
		reset();
		var row = rowState(descriptor);
		row.draft = null;
		row.error = null;
		revision++;
	}

	public function build(context:BuildContext):ViewRoot {
		var children:Array<KeyedView> = [];
		var categoryKeys:Map<String, Bool> = new Map();
		for (descriptor in descriptors) {
			var category = descriptor.category;
			if (options.showCategories && category.length > 0 && !categoryKeys.exists(category)) {
				categoryKeys.set(category, true);
				children.push(new KeyedView("category:" + category, new Text(category)));
			}
			// Each build describes the rows with the current options; a row whose inputs are unchanged keeps its body.
			children.push(new KeyedView("property:" + descriptor.id, new PropertyEditorRow(this, descriptor, options)));
		}
		return new Column(key, children, style).build(context);
	}

	function setDraft(descriptor:PropertyDescriptor, value:String):Void {
		var next = value == null ? "" : value;
		var row = rowState(descriptor);
		if (row.draft == next) return;
		row.draft = next;
		revision++;
	}

	/** A detached inspector may reuse this editor only if no draft, error, or edit has occurred. */
	@:allow(haxeon.ui.properties.PropertyInspector) function isPristine():Bool {
		if (revision != 0) return false;
		for (row in rows) if (row.draft != null || row.error != null || row.pending != null) return false;
		return true;
	}

	function draftOrValue(descriptor:PropertyDescriptor, value:PropertyValue):String {
		var draft = rowState(descriptor).draft;
		return draft != null ? draft : registry.editableText(value);
	}

	function commitText(context:BuildContext, descriptor:PropertyDescriptor, text:String):Void {
		var parsed = registry.parse(descriptor.type, text);
		if (parsed == null) {
			var row = rowState(descriptor);
			if (row.error != "Value is not valid") revision++;
			row.error = "Value is not valid";
			return;
		}
		applyValue(context, descriptor, parsed);
	}

	@:allow(haxeon.ui.properties) function rowState(descriptor:PropertyDescriptor):PropertyRowState {
		var row = rows.get(descriptor.id);
		if (row == null) throw 'Unknown property ${descriptor.id}';
		return row;
	}

	/** The row's visible label, which also names its control for assistive technology. */
	public static function accessibleName(descriptor:PropertyDescriptor):String return descriptor.unit
		== null ? descriptor.label : descriptor.label + " (" + descriptor.unit + ")";

	/** The current validation or edit error of the property `id`, or null. */
	public function errorFor(id:String):Null<String> {
		var row = rows.get(id);
		return row == null ? null : row.error;
	}

	@:allow(haxeon.ui.properties)
	function editorView(context:BuildContext, descriptor:PropertyDescriptor, value:PropertyValue):View {
		var editorKey = "editor:" + descriptor.id;
		var writable = options.enabled && !descriptor.readOnly && rowState(descriptor).pending == null;
		if (isMixed(value)) {
			if (descriptor.type == PropertyType.Bool
				|| descriptor.type == PropertyType.Enum) return mixedChoice(context,
				descriptor,
				editorKey,
				writable);
			return textField(context, descriptor, value, editorKey, writable);
		}
		var result:View = null;
		switch (descriptor.type) {
			case PropertyType.Bool:
				var checked = false;
				switch (value) {
					case Bool(data):
						checked = data;
					default:
						checked = false;
				}
				var checkbox = new Checkbox(editorKey, "", checked, function(next) {
					applyValue(context, descriptor, PropertyValue.Bool(next));
				}, accessibilityLabel: accessibleName(descriptor), enabled: writable);
				result = checkbox;
			case PropertyType.Enum:
				var selected = descriptor.options.length == 0 ? "" : descriptor.options[0].key;
				switch (value) {
					case Enum(data):
						selected = data;
					default:
						selected = selected;
				}
				var enumOptions:Array<SelectOption<String>> = [];
				for (option in descriptor.options) enumOptions.push(new SelectOption<String>(option.key,
					option.label,
					option.key,
					option.enabled));
				var select = new Select<String>(editorKey, enumOptions, selected, function(next) {
					applyValue(context, descriptor, PropertyValue.Enum(next));
				}, GrowInputStyle, enabled: writable, accessibilityLabel: accessibleName(descriptor));
				result = select;
			case PropertyType.Int | PropertyType.Float:
				result = numericEditor(context, descriptor, value, editorKey, writable);
			case PropertyType.Text:
				result = textField(context, descriptor, value, editorKey, writable);
			case PropertyType.Custom(typeId):
				var extension = registry.get(typeId);
				result = extension == null ? new Text("No editor for " + typeId) : extension.build(editorKey,
					descriptor, value, context, writable, function(next) {
						applyValue(context, descriptor, next);
					});
		}
		return result;
	}

	function mixedChoice(context:BuildContext, descriptor:PropertyDescriptor, editorKey:String, writable:Bool):View {
		var choices:Array<SelectOption<String>> = [];
		if (descriptor.type == PropertyType.Bool) {
			choices.push(new SelectOption<String>("__mixed__", "Mixed", "__mixed__"));
			choices.push(new SelectOption<String>("false", "false", "false"));
			choices.push(new SelectOption<String>("true", "true", "true"));
		} else {
			choices.push(new SelectOption<String>("__mixed__", "Mixed", "__mixed__"));
			for (option in descriptor.options) choices.push(new SelectOption<String>(option.key,
				option.label,
				option.key,
				option.enabled));
		}
		var select = new Select<String>(editorKey, choices, "__mixed__", function(next) {
			if (next == "__mixed__") return;
			if (descriptor.type == PropertyType.Bool) applyValue(context, descriptor,
				PropertyValue.Bool(next == "true"));
			else applyValue(context, descriptor, PropertyValue.Enum(next));
		}, enabled: writable, accessibilityLabel: accessibleName(descriptor));
		return select;
	}

	function numericEditor(context:BuildContext,
			descriptor:PropertyDescriptor,
			value:PropertyValue,
			editorKey:String,
			writable:Bool):View {
		var number:Null<Float> = null;
		switch (value) {
			case PropertyValue.Int(data):
				number = data;
			case PropertyValue.Float(data):
				number = data;
			default:
				number = null;
		}
		if (number == null || descriptor.minimum == null || descriptor.maximum == null) return textField(context,
			descriptor,
			value,
			editorKey,
			writable);
		var step = descriptor.step == null ? 0.01 : descriptor.step;
		var slider = new Slider(editorKey + ":slider",
			accessibleName(descriptor), number, descriptor.minimum, descriptor.maximum, step, function(next) {
				if (descriptor.type == PropertyType.Int) applyValue(context, descriptor,
					PropertyValue.Int(Std.int(next)));
				else applyValue(context, descriptor, PropertyValue.Float(next));
			}, GrowInputStyle, enabled: writable);
		return new Row(editorKey + ":numeric",
			[
				new KeyedView("slider", slider),
				new KeyedView("text", textField(context, descriptor, value, editorKey + ":text", writable))
			],
			NumericRowStyle);
	}

	function textField(context:BuildContext,
			descriptor:PropertyDescriptor,
			value:PropertyValue,
			editorKey:String,
			writable:Bool):View {
		return new TextField(editorKey, draftOrValue(descriptor, value), next -> setDraft(descriptor, next),
			FieldInputStyle, accessibleName(descriptor), placeholder: isMixed(value) ? "Mixed" : null,
			enabled: writable,
			classes: ["property-input"], onSubmit: next -> commitText(context, descriptor, next));
	}

	static function isMixed(value:PropertyValue):Bool {
		var result = false;
		switch (value) {
			case Mixed:
				result = true;
			default:
				result = false;
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

/**
 * One property's row, as a component: its inputs are the editor options it lays out with, and its body depends on the
 * property's value and on the error and pending edit of its row state.
 */
private class PropertyEditorRow implements ScopeView {
	final owner:PropertyEditor;
	final descriptor:PropertyDescriptor;
	final enabled:Bool;
	final labelWidth:Float;
	final stackedRows:Bool;
	final searchQuery:String;

	public function new(owner:PropertyEditor, descriptor:PropertyDescriptor, options:PropertyEditorOptions) {
		this.owner = owner;
		this.descriptor = descriptor;
		enabled = options.enabled;
		labelWidth = options.labelWidth;
		stackedRows = options.stackedRows;
		searchQuery = options.searchQuery;
	}

	public function scopeKey():String return descriptor.id;

	public function inputsEqual(previous:ScopeView):Bool {
		if (!Std.isOfType(previous, PropertyEditorRow)) return false;
		var other:PropertyEditorRow = cast previous;
		return owner == other.owner && descriptor == other.descriptor && enabled == other.enabled
			&& labelWidth == other.labelWidth && stackedRows == other.stackedRows && searchQuery == other.searchQuery;
	}

	public function buildBody(context:BuildContext):ViewRoot {
		var value = descriptor.readValue();
		return new PropertyEditorRowContent(owner, descriptor, value).buildWithId(context,
			context.rootId("property-row-root"));
	}

	public function build(context:BuildContext):ViewRoot return context.mountComponent(this);
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

	public function build(context:BuildContext):ViewRoot return buildWithId(context, null);

	function buildRoot(context:BuildContext, id:Null<WidgetId>, children:Array<KeyedView>,
			style:LayoutStyle):RenderNode {
		return context.withScope(RootKey, function() {
			var rootId = id == null ? context.id("column") : id;
			var node = context.styled(rootId, LayoutVisualKind.Box,
				new StyleIdentity("column", "row", "row", null, ["column"]), style);
			var computed = node.computedStyle;
			for (child in children) node.add(context.withStyleParent(computed, function() return child.build(context)));
			return node;
		});
	}

	public function buildWithId(context:BuildContext, id:Null<WidgetId>):RenderNode {
		var observed = context.buildProbe != null;
		var started = observed ? Sys.time() : 0.0;
		var labelStyle = owner.labelStyle();
		var custom = switch descriptor.type {
			case Custom(_):
				true;
			default:
				false;
		};
		var rowStyle = owner.options.stackedRows
			? (custom ? ColumnStart : ColumnCenter) : (custom ? RowStart : RowCenter);
		var children:Array<KeyedView> = [
			new KeyedView("label",
				new haxeon.ui.widgets.text.HighlightedText(PropertyEditor.accessibleName(descriptor),
				owner.options.searchQuery,
				labelStyle)),
			new KeyedView("value", owner.editorView(context, descriptor, value))
		];
		var isModified = descriptor.modified;
		var modified = isModified != null ? isModified() : descriptor.defaultValue != null
			&& !owner.registry.same(value,
			descriptor.defaultValue);
		if (descriptor.modified != null && modified) children.push(new KeyedView("modified", new Text("Modified")));
		if (descriptor.defaultValue != null && !descriptor.readOnly && modified) {
			var reset = new IconButton("reset",
				IconName.Reset,
				"Reset " + descriptor.label + " to default",
				function() owner.resetValue(context, descriptor),
				null,
				owner.options.enabled && owner.rowState(descriptor).pending == null);
			children.push(new KeyedView("reset", reset));
		}
		var error = owner.errorFor(descriptor.id);
		if (error == null && descriptor.description == null
			&& !descriptor.restartRequired && StringTools.trim(owner.options.searchQuery).length == 0) {
			var result = buildRoot(context, id, children, rowStyle);
			if (observed) context.reportBuild("property:" + descriptor.id, 0.0, Sys.time() - started, result);
			return result;
		}
		var row:View = owner.options.stackedRows ? new Column("row", children, rowStyle) : new Row("row",
			children,
			rowStyle);
		var errorStyle = DetailTextStyle;
		var details:Array<KeyedView> = [new KeyedView("field", row)];
		if (descriptor.description != null
			&& descriptor.description.length > 0) details.push(new KeyedView("description",
			new haxeon.ui.widgets.text.HighlightedText(descriptor.description,
			owner.options.searchQuery,
			errorStyle,
			context.theme.tokens.textSecondary,
			haxeon.ui.core.TextStyleOverride.paragraph(haxeon.ui.TextStyle.TextWrap.WordCharacter),
			haxeon.ui.theme.TextRole.Caption)));
		if (StringTools.trim(owner.options.searchQuery).length > 0) details.push(new KeyedView("path",
			new haxeon.ui.widgets.text.HighlightedText(descriptor.id,
			owner.options.searchQuery,
			errorStyle,
			context.theme.tokens.textSecondary,
			null,
			haxeon.ui.theme.TextRole.Caption)));
		if (descriptor.restartRequired) details.push(new KeyedView("restart",
			new Text("Requires restart", errorStyle)));
		if (error != null) details.push(new KeyedView("message", new Text(error, errorStyle)));
		var result = buildRoot(context, id, details, DetailColumnStyle);
		if (observed) context.reportBuild("property:" + descriptor.id, 0.0, Sys.time() - started, result);
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
}

/**
 * One row's edit state. The draft is what the user typed, which the row's field already shows, so no row depends on it;
 * a row shows the error and whether an edit is in flight.
 */
private class PropertyRowState implements Observable {
	@:unobservable public var draft:Null<String> = null;
	public var error:Null<String> = null;
	public var pending:Null<PropertyPendingEdit> = null;

	public function new() {}
}

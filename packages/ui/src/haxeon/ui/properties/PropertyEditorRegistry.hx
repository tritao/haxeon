package haxeon.ui.properties;

import haxeon.ui.core.BuildContext;
import haxeon.ui.core.Command;
import haxeon.ui.core.View;
import haxeon.ui.properties.PropertyValue;

/** Registry for application-defined property values and inspector controls. */
class PropertyEditorRegistry {
	final extensions:Map<String, PropertyEditorExtension>;

	/** A registry holding `initial`. */
	public function new(?initial:Array<PropertyEditorExtension>) {
		extensions = new Map();
		if (initial != null)
			for (extension in initial)
				register(extension);
	}

	/** Adds `extension`. Throws when its type id is empty or taken. */
	public function register(extension:PropertyEditorExtension):Void {
		if (extension == null || extension.typeId() == null || extension.typeId().length == 0)
			throw "Property editor extensions require a stable type ID";
		var id = extension.typeId();
		if (extensions.exists(id))
			throw 'Property editor extension already registered: $id';
		extensions.set(id, extension);
	}

	/** Removes the extension for `typeId`. Returns false when there is none. */
	public function unregister(typeId:String):Bool
		return typeId != null && extensions.remove(typeId);

	/** The extension for `typeId`, or null. */
	public function get(typeId:String):Null<PropertyEditorExtension>
		return typeId == null ? null : extensions.get(typeId);

	/** Why `value` is invalid for `descriptor`, asking its extension for custom values, or null. */
	public function validate(context:CommandContext, descriptor:PropertyDescriptor,
			value:PropertyValue):Null<String> {
		if (value == null)
			return null;
		return switch (value) {
			case Custom(typeId, data):
				var extension = get(typeId);
				if (extension == null)
					"No property editor extension is registered for " + typeId;
				else
					extension.validate(context == null ? new CommandContext() : context,
						descriptor, data);
			default: null;
		};
	}

	/** Whether two values are equal, comparing custom values through their extension. */
	public function same(first:Null<PropertyValue>, second:Null<PropertyValue>):Bool {
		if (first == null || second == null)
			return first == null && second == null;
		return switch ([first, second]) {
			case [Custom(typeA, firstData), Custom(typeB, secondData)]:
				if (typeA != typeB)
					false;
				else {
					var extension = get(typeA);
					extension == null ? PropertyValue.same(first, second) : extension.same(firstData, secondData);
				}
			default: PropertyValue.same(first, second);
		};
	}

	/** `value` as read-only text, formatting custom values through their extension. */
	public function display(value:Null<PropertyValue>, mixedText:String = "—"):String {
		if (value == null)
			return "";
		return switch (value) {
			case Custom(typeId, data):
				var extension = get(typeId);
				extension == null ? PropertyValue.display(value, mixedText) : extension.display(data);
			case Mixed: mixedText;
			default: PropertyValue.display(value, mixedText);
		};
	}

	/** `value` as editable text, through its extension for custom values. */
	public function editableText(value:Null<PropertyValue>):String {
		if (value == null)
			return "";
		return switch (value) {
			case Custom(typeId, data):
				var extension = get(typeId);
				extension == null ? PropertyValue.editableText(value) : extension.editableText(data);
			default: PropertyValue.editableText(value);
		};
	}

	/** Parses a custom value and restores the extension type tag. */
	public function parse(type:PropertyType, text:String):Null<PropertyValue> {
		return switch (type) {
			case Custom(typeId):
				var extension = get(typeId);
				if (extension == null)
					null;
				else {
					var data = extension.parse(text);
					data == null ? null : PropertyValue.Custom(typeId, data);
				}
			default: PropertyValue.parse(type, text);
		};
	}
}

/**
 * Application-owned property type integration.
 *
 * Extensions keep app model types out of the core property enum while still
 * giving the inspector one consistent read/validate/write path. The editor
 * callback must be used for mutations so the owning PropertyEditor can route
 * them through document history or an external transaction owner.
 */
interface PropertyEditorExtension {
	/** Stable ID used by PropertyType.Custom and PropertyValue.Custom. */
	function typeId():String;

	/** Equality for the extension's value payload. */
	function same(first:Dynamic, second:Dynamic):Bool;

	/** Human-readable value for labels, summaries, and accessibility. */
	function display(value:Dynamic):String;

	/** Single-line value used by text-based custom controls. */
	function editableText(value:Dynamic):String;

	/** Optional text import used by text-based custom controls. */
	function parse(text:String):Null<Dynamic>;

	/** Additional model-level validation beyond descriptor type checking. */
	function validate(context:CommandContext, descriptor:PropertyDescriptor,
			value:Dynamic):Null<String>;

	/**
	 * Builds the custom inspector control. `value` may be Mixed for a
	 * multi-selection. Call `apply` with a PropertyValue.Custom of this
	 * extension's type to commit an edit.
	 */
	function build(key:String, descriptor:PropertyDescriptor, value:PropertyValue,
			context:BuildContext, enabled:Bool, apply:PropertyValue->Void):View;
}

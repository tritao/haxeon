package haxeon.ui.properties;

import Observable;
import haxeon.ui.core.Command;
import haxeon.ui.properties.PropertyValue;

/** Stable property schema plus model read/write/validation hooks. */
class PropertyDescriptor {
	/** The shape of a structured custom value, or null. */
	public final structure:Null<PropertyStructure>;

	/** The external transaction owner, or null to edit through document history. */
	public final commit:Null<PropertyCommitter>;

	/** A stable identifier. */
	public final id:String;

	/** Its row label. */
	public final label:String;

	/** The editor family it uses. */
	public final type:PropertyType;

	/** The inspector category it is listed under. */
	public final category:String;

	/** Help text, or null. */
	public final description:Null<String>;

	/** Whether changes take effect only after a restart. */
	public final restartRequired:Bool;

	/** Whether the value differs from its default, when the model can tell. */
	public final modified:Null<Void->Bool>;

	/** Restores the default, when the model can. */
	public final reset:Null<Void->Void>;

	/** Whether it can be shown but not edited. */
	public final readOnly:Bool;

	/** Whether edits enter the undo history. */
	public final recordHistory:Bool;

	/** The lowest number accepted, or null. */
	public final minimum:Null<Float>;

	/** The highest number accepted, or null. */
	public final maximum:Null<Float>;

	/** The increment the editor steps by, or null. */
	public final step:Null<Float>;

	/** The unit shown after the value, or null. */
	public final unit:Null<String>;

	/** The default value, or null. */
	public final defaultValue:Null<PropertyValue>;

	/** The choices of an Enum property. */
	public final options:Array<PropertyOption>;
	internal final read:PropertyReader;
	internal final write:PropertyWriter;
	final validator:Null<PropertyValidator>;

	/**
	 * A property `id` that `read` reads and `write` changes. Throws for a missing id, label or callback, a bad range
	 * or step, or an Enum without options.
	 */
	public function new(id:String, label:String, type:PropertyType,
			read:PropertyReader, write:PropertyWriter, ?settings:PropertyDescriptorOptions) {
		if (id == null || id.length == 0 || label == null || label.length == 0 || read == null || write == null)
			throw "Property descriptors require an ID, label, reader, and writer";
		var config = settings == null ? new PropertyDescriptorOptions() : settings;
		if (config.minimum != null && config.maximum != null && config.minimum > config.maximum)
			throw "Property descriptor range is invalid";
		if (config.step != null && config.step <= 0.0)
			throw "Property descriptor step must be positive";
		if (type == PropertyType.Enum && (config.options == null || config.options.length == 0))
			throw "Enum properties require options";
		switch (type) {
			case PropertyType.Custom(typeId):
				if (typeId == null || typeId.length == 0)
					throw "Custom property types require a stable type ID";
			default:
		}
		this.description = config.description;
		this.restartRequired = config.restartRequired;
		this.modified = config.modified;
		this.reset = config.reset;
		this.structure = config.structure;
		this.commit = config.commit;
		this.id = id;
		this.label = label;
		this.type = type;
		this.category = config.category == null ? "" : config.category;
		this.readOnly = config.readOnly;
		this.recordHistory = config.recordHistory;
		this.minimum = config.minimum;
		this.maximum = config.maximum;
		this.step = config.step;
		this.unit = config.unit;
		this.defaultValue = config.defaultValue;
		this.options = config.options == null ? [] : config.options.copy();
		this.read = read;
		this.write = write;
		this.validator = config.validator;
		validateOptions();
	}

	/** The model's current value. */
	public function readValue():PropertyValue
		return read();

	/** Why `value` cannot be written, or null: checks read-only, type, range and the validator. */
	public function validateValue(context:CommandContext, value:PropertyValue):Null<String> {
		if (value == null)
			return "A property value is required";
		if (readOnly)
			return "Property is read-only";
		var typeError = validateType(value);
		if (typeError != null)
			return typeError;
		var number:Null<Float> = switch (value) {
			case Int(data): data;
			case Float(data): data;
			default: null;
		};
		if (number != null) {
			if (minimum != null && number < minimum)
				return "Value is below the minimum";
			if (maximum != null && number > maximum)
				return "Value is above the maximum";
		}
		return validator == null ? null : validator(context == null ? new CommandContext() : context, value);
	}

	/** The Enum option `key`, or null. */
	public function option(key:String):Null<PropertyOption> {
		for (item in options)
			if (item.key == key)
				return item;
		return null;
	}

	function validateType(value:PropertyValue):Null<String> {
		var valid = false;
		switch (type) {
			case PropertyType.Bool:
				switch (value) {
					case Bool(_): valid = true;
					default:
				}
			case PropertyType.Int:
				switch (value) {
					case Int(_): valid = true;
					default:
				}
			case PropertyType.Float:
				switch (value) {
					case Float(_) | Int(_): valid = true;
					default:
				}
			case PropertyType.Text:
				switch (value) {
					case Text(_): valid = true;
					default:
				}
			case PropertyType.Enum:
				switch (value) {
					case Enum(data): return option(data) == null ? "Unknown enum option" : null;
					default:
				}
			case PropertyType.Custom(typeId):
				switch (value) {
					case Custom(valueType, _): valid = valueType == typeId;
					default:
				}
		}
		return valid ? null : "Property value type does not match its descriptor";
	}

	function validateOptions():Void {
		var keys:Map<String, Bool> = new Map();
		for (item in options) {
			if (item == null || keys.exists(item.key))
				throw "Property option keys must be unique";
			keys.set(item.key, true);
		}
	}
}

/** Model reads track their own Observable sources; invocation context belongs to edits. */
typedef PropertyReader = Void->PropertyValue;

/** Writes a value to the model. */
typedef PropertyWriter = CommandContext->PropertyValue->Void;

/** Hands an edit to an external transaction owner; the third argument is the coalescing key. */
typedef PropertyCommitter = CommandContext->PropertyValue->Null<String>->PropertyEditResult;

/** Says why a value is invalid, or returns null. */
typedef PropertyValidator = CommandContext->PropertyValue->Null<String>;

/** Optional presentation and validation policy for one editable property. */
class PropertyDescriptorOptions {
	/** The shape of a structured custom value, for list, record and vector editors. */
	public var structure:Null<PropertyStructure>;
	/** Optional external transaction owner. Bypasses UI document history after validation.
	 * Completion and observers must run on the UI thread. */
	public var commit:Null<PropertyCommitter>;

	/** The inspector category. */
	public var category:String;

	/** Help text. */
	public var description:Null<String>;

	/** Whether changes take effect only after a restart. */
	public var restartRequired:Bool = false;

	/** Tells whether the value differs from its default. */
	public var modified:Null<Void->Bool>;

	/** Restores the default. */
	public var reset:Null<Void->Void>;

	/** Shown but not editable. */
	public var readOnly:Bool;
	/** Whether edits enter the owning editor document's undo history. */
	public var recordHistory:Bool;

	/** The lowest number accepted. */
	public var minimum:Null<Float>;

	/** The highest number accepted. */
	public var maximum:Null<Float>;

	/** The editor's increment. */
	public var step:Null<Float>;

	/** The unit shown after the value. */
	public var unit:Null<String>;

	/** The default value. */
	public var defaultValue:Null<PropertyValue>;

	/** The choices of an Enum property. */
	public var options:Array<PropertyOption>;

	/** Extra validation beyond type and range. */
	public var validator:Null<PropertyValidator>;

	/** Options for an editable, uncategorized property that records history. */
	public function new() {
		structure = null;
		commit = null;
		category = "";
		readOnly = false;
		recordHistory = true;
		minimum = null;
		maximum = null;
		step = null;
		unit = null;
		defaultValue = null;
		options = [];
		validator = null;
	}
}

/** Result of validating and applying one property binding edit. */
enum PropertyEditResult {
	/** The owning model committed the value. */
	Applied;
	/** Submitted to an external transaction owner; completion has not happened. */
	Pending(edit:PropertyPendingEdit);
	/** The requested value was already present, so no history entry was made. */
	Unchanged;
	/** The edit was rejected before it changed the application model. */
	Rejected(message:String);

	/** Whether the model committed the value. */
	public function isApplied():Bool
		return switch this {
			case Applied: true;
			default: false;
		};
}

/** One-shot completion delivered by the application on its UI thread.
 * A queued operation is not an applied edit. The owner resolves this after
 * its transaction commits or fails, including cancellation on disposal.
 */
class PropertyPendingEdit {
	/** The final result, or null while pending. */
	public var result(default, null):Null<PropertyEditResult> = null;
	final listeners:Array<PropertyEditResult->Void> = [];

	/** A pending edit. */
	public function new() {}

	/** Calls `listener` with the result when it arrives, or now if it has. */
	public function onComplete(listener:PropertyEditResult->Void):Void {
		if (result == null) listeners.push(listener);
		else listener(result);
	}

	/** Completes the edit with `next`. Throws when it is null or Pending, or the edit already completed. */
	public function resolve(next:PropertyEditResult):Void {
		if (next == null) throw "A terminal property result is required";
		switch next {
			case Pending(_): throw "Completion cannot be pending";
			default:
		}
		if (result != null) throw "Property edit already completed";
		result = next;
		var callbacks = listeners.copy();
		listeners.resize(0);
		for (callback in callbacks) callback(next);
	}
}

/** Stable grouping of descriptors rendered by a shared property inspector. */
class PropertyInspectorSection implements Observable {
	/** A stable identifier. */
	public final id:String;

	/** Its heading. */
	public final label:String;

	/** The properties it shows. */
	public final descriptors:Array<PropertyDescriptor>;

	/** Whether it is open. */
	public var expanded(default, null):Bool;

	/** A section `id` of `descriptors`. Throws for a missing id or label, or duplicate descriptor ids. */
	public function new(id:String, label:String, descriptors:Array<PropertyDescriptor>,
			expanded:Bool = true) {
		if (id == null || id.length == 0 || label == null || label.length == 0 || descriptors == null
			|| descriptors.length == 0)
			throw "Inspector sections require an ID, label, and descriptors";
		this.id = id;
		this.label = label;
		this.descriptors = descriptors.copy();
		var ids:Map<String, Bool> = new Map();
		for (descriptor in this.descriptors) {
			if (descriptor == null || ids.exists(descriptor.id))
				throw "Inspector section descriptor IDs must be unique";
			ids.set(descriptor.id, true);
		}
		this.expanded = expanded;
	}

	/** Changes the section state and reports whether it changed. */
	public function setExpanded(value:Bool):Bool {
		if (expanded == value)
			return false;
		expanded = value;
		return true;
	}
}

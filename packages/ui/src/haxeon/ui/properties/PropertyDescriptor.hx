package haxeon.ui.properties;

import Observable;
import haxeon.ui.core.CommandContext;
import haxeon.ui.properties.PropertyValue;

/** Stable property schema plus model read/write/validation hooks. */
class PropertyDescriptor {
	public final structure:Null<PropertyStructure>;
	public final commit:Null<PropertyCommitter>;
	public final id:String;
	public final label:String;
	public final type:PropertyType;
	public final category:String;
	public final description:Null<String>;
	public final restartRequired:Bool;
	public final modified:Null<Void->Bool>;
	public final reset:Null<Void->Void>;
	public final readOnly:Bool;
	public final recordHistory:Bool;
	public final minimum:Null<Float>;
	public final maximum:Null<Float>;
	public final step:Null<Float>;
	public final unit:Null<String>;
	public final defaultValue:Null<PropertyValue>;
	public final options:Array<PropertyOption>;
	public final read:PropertyReader;
	public final write:PropertyWriter;
	final validator:Null<PropertyValidator>;

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

	public function readValue():PropertyValue
		return read();

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
typedef PropertyWriter = CommandContext->PropertyValue->Void;
typedef PropertyCommitter = CommandContext->PropertyValue->Null<String>->PropertyEditResult;

typedef PropertyValidator = CommandContext->PropertyValue->Null<String>;

/** Optional presentation and validation policy for one editable property. */
class PropertyDescriptorOptions {
	/** Optional external transaction owner. Bypasses UI document history after validation.
	 * Completion and observers must run on the UI thread. */
	public var structure:Null<PropertyStructure>;
	public var commit:Null<PropertyCommitter>;
	public var category:String;
	public var description:Null<String>;
	public var restartRequired:Bool = false;
	public var modified:Null<Void->Bool>;
	public var reset:Null<Void->Void>;
	public var readOnly:Bool;
	/** Whether edits enter the owning editor document's undo history. */
	public var recordHistory:Bool;
	public var minimum:Null<Float>;
	public var maximum:Null<Float>;
	public var step:Null<Float>;
	public var unit:Null<String>;
	public var defaultValue:Null<PropertyValue>;
	public var options:Array<PropertyOption>;
	public var validator:Null<PropertyValidator>;

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
}

/** Queries the case of a property edit result without comparing its payload. */
class PropertyEditResultTools {
	public static function isApplied(result:PropertyEditResult):Bool
		return switch result {
			case Applied: true;
			default: false;
		};
}

/** One-shot completion delivered by the application on its UI thread.
 * A queued operation is not an applied edit. The owner resolves this after
 * its transaction commits or fails, including cancellation on disposal.
 */
class PropertyPendingEdit {
	public var result(default, null):Null<PropertyEditResult> = null;
	final listeners:Array<PropertyEditResult->Void> = [];
	public function new() {}
	public function onComplete(listener:PropertyEditResult->Void):Void {
		if (result == null) listeners.push(listener);
		else listener(result);
	}
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
	public final id:String;
	public final label:String;
	public final descriptors:Array<PropertyDescriptor>;
	public var expanded(default, null):Bool;

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

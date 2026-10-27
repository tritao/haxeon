package haxeon.ui.properties;

import haxeon.ui.core.CommandContext;

typedef PropertyReader = CommandContext->PropertyValue;
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

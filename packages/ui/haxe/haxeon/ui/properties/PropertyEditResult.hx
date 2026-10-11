package haxeon.ui.properties;

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

package haxeon.platform.event;

import haxeon.platform.async.Completion;

/** What one polled native event is: nothing, something that happened, which listeners see, or a request's answer. */
internal enum Delivery {
	Nothing;
	Happened(event:PlatformEvent);
	Answered(completion:Completion);
}

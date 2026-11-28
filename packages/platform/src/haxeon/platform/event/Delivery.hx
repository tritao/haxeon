package haxeon.platform.event;

import haxeon.platform.async.Completion;
import haxeon.platform.http.HttpSignal;

/**
 * What one polled native event is: nothing, something that happened, which listeners see, a request's answer, or what
 * an HTTP request reports, which goes to its exchange.
 */
internal enum Delivery {
	Nothing;
	Happened(event:PlatformEvent);
	Answered(completion:Completion);
	Exchanged(signal:HttpSignal);
}

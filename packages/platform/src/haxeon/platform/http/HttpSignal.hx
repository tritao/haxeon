package haxeon.platform.http;

import haxeon.platform.NativeKitError;

/** What NativeKit reports about an HTTP request, which the event pump hands to its exchange alone. */
internal enum HttpSignal {
	Headers(request:haxe.Int64, response:Result<HttpResponse, NativeKitError>);
	DataAvailable(request:haxe.Int64);
	Progress(request:haxe.Int64, progress:HttpProgress);
	Complete(request:haxe.Int64, response:Result<HttpResponse, NativeKitError>);
}

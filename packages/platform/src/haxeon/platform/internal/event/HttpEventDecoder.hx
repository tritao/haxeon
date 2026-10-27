package haxeon.platform.internal.event;

import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.event.PlatformEvent;
import haxeon.platform.http.HttpHeader;
import haxeon.platform.http.HttpResponse;
import haxeon.platform.internal.event.EventBytes;
import haxeon.platform.internal.event.NativeEvent;
import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitNet;
import nativekit.ffi.NativeKitNetTypes.HttpHeader as NativeHttpHeader;
import nativekit.ffi.NativeKitNetTypes.HttpProgress;
import nativekit.ffi.NativeKitNetTypes.HttpResponse as NativeHttpResponse;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.Result;

/** Copies NativeKit HTTP event views into managed values before event release. */
class HttpEventDecoder {
	public static function decode(event:NativeEvent):Null<PlatformEvent> {
		return switch event.kind {
			case EventKind.HttpHeaders:
				HttpHeaders(event.source, event.request, event.result, response(event));
			case EventKind.HttpComplete:
				HttpComplete(event.source, event.request, event.result, response(event));
			case EventKind.HttpDataAvailable:
				HttpDataAvailable(event.source, event.request);
			case EventKind.HttpProgress:
				var decoded = NativeKitNet.nk_http_event_progress(event.nativeEvent());
				check(decoded.status, "nk_http_event_progress");
				var progress:HttpProgress = decoded.out_progress;
				HttpProgressEvent(event.source, event.request, progress.get_downloaded(),
					progress.get_download_total(), progress.get_uploaded(), progress.get_upload_total());
			case _:
				null;
		};
	}

	static function response(event:NativeEvent):HttpResponse {
		var decoded = NativeKitNet.nk_http_event_response(event.nativeEvent());
		check(decoded.status, "nk_http_event_response");
		var view:NativeHttpResponse = decoded.out_response;
		var headers:Array<HttpHeader> = [];
		for (index in 0...view.get_header_count()) {
			var decodedHeader = NativeKitNet.nk_http_response_header(view, index);
			check(decodedHeader.status, "nk_http_response_header");
			var header:NativeHttpHeader = decodedHeader.out_header;
			var name = EventBytes.readUtf8Slice(header.get_name_bytes(), 0,
				header.get_name_size(), 0);
			var value = EventBytes.readUtf8Slice(header.get_value_bytes(), 0,
				header.get_value_size(), 0);
			if (name == null || value == null)
				throw BindingError.invalidData("HttpEventDecoder.response", "NativeKit HTTP response contains an invalid UTF-8 header");
			headers.push(new HttpHeader(name, value));
		}
		return new HttpResponse(view.get_status_code(), view.get_flags(),
			view.get_content_length(), headers, view.get_body_bytes());
	}

	static function check(result:Result, operation:String):Void
		if (result != Result.Ok)
			throw new NativeKitError(result, operation, NativeKit.nk_last_error());
}

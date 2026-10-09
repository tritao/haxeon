package haxeon.platform;

import nativekit.ffi.NativeKit;
import nativekit.ffi.NativeKitNet;
import nativekit.ffi.NativeKitNetTypes.HttpHeader;
import nativekit.ffi.NativeKitNetTypes.HttpProgress;
import nativekit.ffi.NativeKitNetTypes.HttpResponse;
import nativekit.ffi.NativeKitTypes.EventKind;
import nativekit.ffi.NativeKitTypes.Result;
import haxeon.platform.NativeKitEventValue;

/** Copies NativeKit HTTP event views into managed values before event release. */
class NativeKitHttpEvents {
	public static function decode(event:NativeKitEvent):Null<NativeKitEventValue> {
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

	static function response(event:NativeKitEvent):NativeKitHttpResponse {
		var decoded = NativeKitNet.nk_http_event_response(event.nativeEvent());
		check(decoded.status, "nk_http_event_response");
		var view:HttpResponse = decoded.out_response;
		var headers:Array<NativeKitHttpHeader> = [];
		for (index in 0...view.get_header_count()) {
			var decodedHeader = NativeKitNet.nk_http_response_header(view, index);
			check(decodedHeader.status, "nk_http_response_header");
			var header:HttpHeader = decodedHeader.out_header;
			var name = NativeKitEventBytes.readUtf8Slice(header.get_name_bytes(), 0,
				header.get_name_size(), 0);
			var value = NativeKitEventBytes.readUtf8Slice(header.get_value_bytes(), 0,
				header.get_value_size(), 0);
			if (name == null || value == null)
				throw "NativeKit HTTP response contains an invalid UTF-8 header";
			headers.push(new NativeKitHttpHeader(name, value));
		}
		return new NativeKitHttpResponse(view.get_status_code(), view.get_flags(),
			view.get_content_length(), headers, view.get_body_bytes());
	}

	static function check(result:Result, operation:String):Void
		if (result != Result.Ok)
			throw new NativeKitError(result, operation, NativeKit.nk_last_error());
}

package haxeon.platform.async;

import haxeon.platform.NativeKitError;
import haxeon.platform.dialog.MessageAnswer;
import haxeon.platform.resource.Resource;
import nativekit.ffi.NativeKitTypes.Handle;

/**
 * A native request's answer. The event pump hands it to `Requests`, which settles the request's future; no listener
 * sees it, so what a caller asked for reaches only the caller. Each failure is already a `NativeKitError`, a dismissed
 * dialog `Cancelled` among them.
 */
internal enum Completion {
	ClipboardText(request:haxe.Int64, text:Result<String, NativeKitError>);
	ClipboardFiles(request:haxe.Int64, paths:Result<Array<String>, NativeKitError>);
	ClipboardResources(request:haxe.Int64, items:Result<Array<Resource>, NativeKitError>);
	DialogResources(request:haxe.Int64, items:Result<Array<Resource>, NativeKitError>);
	DialogMessage(request:haxe.Int64, answer:Result<MessageAnswer, NativeKitError>);
	WebViewEvaluation(request:haxe.Int64, json:Result<String, NativeKitError>);
	ResourceCommit(request:haxe.Int64, downloadInitiated:Result<Bool, NativeKitError>);
	ResourceData(request:haxe.Int64, bytes:Result<haxe.io.Bytes, NativeKitError>);

	/** A task reported progress; its request stays open. */
	TaskProgress(task:Handle, data:haxe.io.Bytes);

	TaskComplete(task:Handle, data:haxe.io.Bytes);
	TaskFailed(task:Handle, error:NativeKitError, data:haxe.io.Bytes);
	TaskCancelled(task:Handle);
}

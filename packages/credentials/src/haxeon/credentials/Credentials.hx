package haxeon.credentials;

import haxe.io.Bytes;
import haxeon.platform.NativeKitError;
import nativekit.ffi.NativeKitCredentials;
import nativekit.ffi.NativeKitTypes.Result;

/** Synchronous access to the current user's NativeKit OS credential store. */
class Credentials {
	/** Store or replace an opaque binary secret. */
	public static function set(service:String, account:String, secret:Bytes):Void {
		if (secret == null || secret.length == 0)
			throw "credential secret must contain at least one byte";
		check(NativeKitCredentials.nk_credentials_set(service, account, secret),
			"credentials.set");
	}

	/**
	 * Retrieve a secret, or return null when no item exists. The returned bytes
	 * are caller-owned; clear them with `fill` when the secret is no longer needed.
	 */
	public static function get(service:String, account:String):Null<Bytes> {
		var loaded = NativeKitCredentials.nk_credentials_get(service, account);
		if (loaded.status == Result.ErrorNotFound)
			return null;
		check(loaded.status, "credentials.get");
		return loaded.secret;
	}

	/**
	 * `get`, but the OS never shows the user a prompt: an item it would ask for
	 * (on macOS, a keychain item whose access list does not name this program, or
	 * a locked keychain) raises `NativeKitError` with PERMISSION_DENIED instead.
	 * Unsupported (an error) on Linux, whose Secret Service cannot be told not to ask.
	 */
	public static function getWithoutAsking(service:String, account:String):Null<Bytes> {
		var loaded = NativeKitCredentials.nk_credentials_get_without_ui(service, account);
		if (loaded.status == Result.ErrorNotFound)
			return null;
		check(loaded.status, "credentials.getWithoutAsking");
		return loaded.secret;
	}

	/** Delete a secret. Missing items raise `NativeKitError` with NOT_FOUND. */
	public static function delete(service:String, account:String):Void
		check(NativeKitCredentials.nk_credentials_delete(service, account), "credentials.delete");

	static function check(status:Result, operation:String):Void {
		if (status != Result.Ok)
			throw new NativeKitError(status, operation, NativeKitCredentials.nk_credentials_last_error());
	}
}

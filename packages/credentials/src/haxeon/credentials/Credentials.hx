package haxeon.credentials;

import haxe.io.Bytes;
import haxeon.platform.BindingError;
import haxeon.platform.NativeKitError;
import haxeon.platform.NativeKitStatus;
import nativekit.ffi.NativeKitCredentials;
import nativekit.ffi.NativeKitTypes.Result as NativeResult;

/**
 * The current user's OS credential store (the Keychain, the Credential Manager, the Secret Service), synchronously.
 * Each call answers a `Result`: a machine without a store, or a store that refuses, is an `Err`.
 */
class Credentials {
	/** Stores `secret` for `service` and `account`, replacing what was there. */
	public static function set(service:String, account:String, secret:Bytes):Result<Void, NativeKitError> {
		if (secret == null || secret.length == 0)
			throw BindingError.invalidArgument("Credentials.set", "A credential secret must hold at least one byte");
		return NativeKitStatus.result(NativeKitCredentials.nk_credentials_set(service, account, secret),
			"credentials.set",
			NativeKitCredentials.nk_credentials_last_error());
	}

	/**
	 * The secret for `service` and `account`, or null when there is none. The bytes are the caller's; clear them with
	 * `fill` when the secret is no longer needed.
	 */
	public static function get(service:String, account:String):Result<Null<Bytes>, NativeKitError> {
		var loaded = NativeKitCredentials.nk_credentials_get(service, account);
		if (loaded.status == NativeResult.ErrorNotFound)
			return Ok(null);
		return NativeKitStatus.made(loaded.status, "credentials.get", NativeKitCredentials.nk_credentials_last_error(),
			() -> (loaded.secret:Null<Bytes>));
	}

	/** Deletes the secret for `service` and `account`; `NotFound` when there is none. */
	public static function delete(service:String, account:String):Result<Void, NativeKitError>
		return NativeKitStatus.result(NativeKitCredentials.nk_credentials_delete(service, account),
			"credentials.delete",
			NativeKitCredentials.nk_credentials_last_error());
}

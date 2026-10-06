package haxeon.credentials.tests;

import haxe.io.Bytes;
import haxeon.credentials.Credentials;

class CredentialsSmoke {
	static function main():Void {
		var service = 'org.nativekit.haxeon.tests.${Std.int(Sys.time() * 1000000)}';
		var account = "binary round trip";
		var secret = Bytes.alloc(5);
		secret.set(0, 0);
		secret.set(1, 0x42);
		secret.set(2, 0xff);
		secret.set(3, 0);
		secret.set(4, 0x7e);
		var stored = false;
		var read:Null<Bytes> = null;
		try {
			Credentials.set(service, account, secret);
			stored = true;
			read = Credentials.get(service, account);
			if (read == null || read.length != secret.length)
				throw "credential round trip returned the wrong size";
			for (index in 0...secret.length)
				if (read.get(index) != secret.get(index))
					throw "credential round trip changed the stored bytes";
			Credentials.delete(service, account);
			stored = false;
			if (Credentials.get(service, account) != null)
				throw "deleted credential remained available";
		} catch (error:Dynamic) {
			cleanup(service, account, stored, secret, read);
			throw error;
		}
		cleanup(service, account, stored, secret, read);
	}

	static function cleanup(service:String, account:String, stored:Bool, secret:Bytes, read:Null<Bytes>):Void {
		try {
			if (stored)
				Credentials.delete(service, account);
		} catch (error:Dynamic) {
			wipe(secret);
			wipe(read);
			throw error;
		}
		wipe(secret);
		wipe(read);
	}

	static function wipe(bytes:Null<Bytes>):Void {
		if (bytes != null)
			for (index in 0...bytes.length)
				bytes.set(index, 0);
	}
}

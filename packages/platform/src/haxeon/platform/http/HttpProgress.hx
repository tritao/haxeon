package haxeon.platform.http;

/** How far an HTTP request has got: bytes sent and received, and the totals where they are known (else 0). */
class HttpProgress {
	/** Response bytes received so far. */
	public final downloaded:haxe.Int64;

	/** The response's length, or 0 when it is not known. */
	public final downloadTotal:haxe.Int64;

	/** Request bytes sent so far. */
	public final uploaded:haxe.Int64;

	/** The request body's length, or 0 when it is not known. */
	public final uploadTotal:haxe.Int64;

	/** Progress of `downloaded` of `downloadTotal` and `uploaded` of `uploadTotal` bytes. */
	public function new(downloaded:haxe.Int64, downloadTotal:haxe.Int64, uploaded:haxe.Int64, uploadTotal:haxe.Int64) {
		this.downloaded = downloaded;
		this.downloadTotal = downloadTotal;
		this.uploaded = uploaded;
		this.uploadTotal = uploadTotal;
	}
}

/*
	Sockets for sys.net, over HashLink's socket primitives (std/socket.c in libhl). Haxeon strings and Bytes are converted
	here, and a socket's addresses come back through one call each instead of out-parameters. As there, a send or receive
	returns -1 when the operation would block and -2 when it failed.
*/
typedef struct _hl_socket hl_socket;
HL_API void hl_socket_init( void );
HL_API hl_socket *hl_socket_new( bool udp );
HL_API void hl_socket_close( hl_socket *s );
HL_API int hl_socket_send_char( hl_socket *s, int c );
HL_API int hl_socket_send( hl_socket *s, vbyte *buf, int pos, int len );
HL_API int hl_socket_recv( hl_socket *s, vbyte *buf, int pos, int len );
HL_API int hl_socket_recv_char( hl_socket *s );
HL_API int hl_host_resolve( vbyte *host );
HL_API vbyte *hl_host_to_string( int ip );
HL_API vbyte *hl_host_reverse( int ip );
HL_API vbyte *hl_host_local( void );
HL_API bool hl_socket_connect( hl_socket *s, int host, int port );
HL_API bool hl_socket_listen( hl_socket *s, int n );
HL_API bool hl_socket_bind( hl_socket *s, int host, int port );
HL_API hl_socket *hl_socket_accept( hl_socket *s );
HL_API bool hl_socket_peer( hl_socket *s, int *host, int *port );
HL_API bool hl_socket_host( hl_socket *s, int *host, int *port );
HL_API bool hl_socket_set_timeout( hl_socket *s, double t );
HL_API bool hl_socket_shutdown( hl_socket *s, bool r, bool w );
HL_API bool hl_socket_set_blocking( hl_socket *s, bool b );
HL_API bool hl_socket_set_fast_send( hl_socket *s, bool b );

static bool realtime_sockets_ready = false;

static void realtime_sockets_init( void ) {
	if( realtime_sockets_ready ) return;
	hl_socket_init();
	realtime_sockets_ready = true;
}

static vstring *realtime_socket_text( vbyte *utf8 ) {
	return utf8 == NULL ? NULL : realtime_string_from_utf8((const char *)utf8);
}

HL_PRIM hl_socket *HL_NAME(__socket_new)( bool udp ) {
	realtime_sockets_init();
	return hl_socket_new(udp);
}

HL_PRIM void HL_NAME(__socket_close)( hl_socket *s ) { hl_socket_close(s); }

HL_PRIM int HL_NAME(__socket_send_byte)( hl_socket *s, int c ) { return hl_socket_send_char(s, c); }

HL_PRIM int HL_NAME(__socket_recv_byte)( hl_socket *s ) { return hl_socket_recv_char(s); }

HL_PRIM int HL_NAME(__socket_send)( hl_socket *s, realtime_bytes *bytes, int pos, int len ) {
	realtime_bytes_bounds(bytes, pos, len);
	return hl_socket_send(s, bytes->data, pos, len);
}

HL_PRIM int HL_NAME(__socket_recv)( hl_socket *s, realtime_bytes *bytes, int pos, int len ) {
	realtime_bytes_bounds(bytes, pos, len);
	return hl_socket_recv(s, bytes->data, pos, len);
}

HL_PRIM bool HL_NAME(__socket_connect)( hl_socket *s, int host, int port ) { return hl_socket_connect(s, host, port); }
HL_PRIM bool HL_NAME(__socket_listen)( hl_socket *s, int n ) { return hl_socket_listen(s, n); }
HL_PRIM bool HL_NAME(__socket_bind)( hl_socket *s, int host, int port ) { return hl_socket_bind(s, host, port); }
HL_PRIM hl_socket *HL_NAME(__socket_accept)( hl_socket *s ) { return hl_socket_accept(s); }
HL_PRIM bool HL_NAME(__socket_set_timeout)( hl_socket *s, double t ) { return hl_socket_set_timeout(s, t); }
HL_PRIM bool HL_NAME(__socket_shutdown)( hl_socket *s, bool r, bool w ) { return hl_socket_shutdown(s, r, w); }
HL_PRIM bool HL_NAME(__socket_set_blocking)( hl_socket *s, bool b ) { return hl_socket_set_blocking(s, b); }
HL_PRIM bool HL_NAME(__socket_set_fast_send)( hl_socket *s, bool b ) { return hl_socket_set_fast_send(s, b); }

/* The local (`peer` false) or remote address of a socket: its IPv4 address, or its port with `port`. */
static int realtime_socket_address( hl_socket *s, bool peer, bool port ) {
	int host = 0, number = 0;
	if( peer ) {
		if( !hl_socket_peer(s, &host, &number) ) hl_error("Could not read the socket's peer address");
	} else if( !hl_socket_host(s, &host, &number) )
		hl_error("Could not read the socket's address");
	return port ? number : host;
}

HL_PRIM int HL_NAME(__socket_host_ip)( hl_socket *s ) { return realtime_socket_address(s, false, false); }
HL_PRIM int HL_NAME(__socket_host_port)( hl_socket *s ) { return realtime_socket_address(s, false, true); }
HL_PRIM int HL_NAME(__socket_peer_ip)( hl_socket *s ) { return realtime_socket_address(s, true, false); }
HL_PRIM int HL_NAME(__socket_peer_port)( hl_socket *s ) { return realtime_socket_address(s, true, true); }

/* The IPv4 address `name` resolves to, or -1. */
HL_PRIM int HL_NAME(__host_resolve)( vstring *name ) {
	realtime_sockets_init();
	char *utf8 = realtime_utf8_copy(name);
	int ip = hl_host_resolve((vbyte *)utf8);
	free(utf8);
	return ip;
}

HL_PRIM vstring *HL_NAME(__host_to_string)( int ip ) { return realtime_socket_text(hl_host_to_string(ip)); }

HL_PRIM vstring *HL_NAME(__host_reverse)( int ip ) {
	realtime_sockets_init();
	return realtime_socket_text(hl_host_reverse(ip));
}

HL_PRIM vstring *HL_NAME(__host_local)( void ) {
	realtime_sockets_init();
	return realtime_socket_text(hl_host_local());
}

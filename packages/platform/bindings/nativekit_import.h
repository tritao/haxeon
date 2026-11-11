#ifndef NATIVEKIT_HAXEON_IMPORT_H
#define NATIVEKIT_HAXEON_IMPORT_H

#include "nativekit.h"
#include "nativekit_task.h"
#include "nativekit_monitor.h"
#include "nativekit_window.h"
#include "nativekit_input.h"
#include "nativekit_joystick.h"
#include "nativekit_gamepad.h"
#include "nativekit_haptics.h"
#include "nativekit_sensor.h"
#include "nativekit_graphics.h"
#include "nativekit_accessibility.h"
#include "nativekit_system.h"
#include "nativekit_mobile.h"
#include "nativekit_menu.h"
#include "nativekit_resource.h"
#include "nativekit_clipboard.h"
#include "nativekit_file_watch.h"
#include "nativekit_webview.h"
#include "nativekit_view.h"
#include "nativekit_notification.h"
#include "nativekit_tray.h"
#include "nativekit_time.h"
#include "nativekit_transport.h"
#include "nativekit_pty.h"
#include "nativekit_net.h"

/* NativeKit reserves button indices through LAST (7). GTK's button_from_gdk
 * also produces 5 and 6, although the public header names only 0..4 and 7.
 * Complete this finite domain for the closed binding; no native ABI changes. */
enum __attribute__((annotate("hxi:enum:nk_pointer_button"))) {
    NK_POINTER_BUTTON_6 = 5,
    NK_POINTER_BUTTON_7 = 6
};

/* nk_result also carries the finite HTTP/transport error domains in event.result
 * and receive results. Keep the closed projection complete using header values. */
enum __attribute__((annotate("hxi:enum:nk_result"))) {
    NK_RESULT_HTTP_DNS = NK_HTTP_ERROR_DNS,
    NK_RESULT_HTTP_CONNECTION = NK_HTTP_ERROR_CONNECTION,
    NK_RESULT_HTTP_TLS = NK_HTTP_ERROR_TLS,
    NK_RESULT_HTTP_TIMEOUT = NK_HTTP_ERROR_TIMEOUT,
    NK_RESULT_HTTP_CANCELED = NK_HTTP_ERROR_CANCELED,
    NK_RESULT_HTTP_PROTOCOL = NK_HTTP_ERROR_PROTOCOL,
    NK_RESULT_HTTP_RESPONSE_LIMIT = NK_HTTP_ERROR_RESPONSE_LIMIT,
    NK_RESULT_HTTP_REDIRECT = NK_HTTP_ERROR_REDIRECT,
    NK_RESULT_HTTP_PROXY = NK_HTTP_ERROR_PROXY,
    NK_RESULT_HTTP_WOULD_BLOCK = NK_HTTP_ERROR_WOULD_BLOCK,
    NK_RESULT_TRANSPORT_DNS = NK_TRANSPORT_ERROR_DNS,
    NK_RESULT_TRANSPORT_CONNECTION = NK_TRANSPORT_ERROR_CONNECTION,
    NK_RESULT_TRANSPORT_TIMEOUT = NK_TRANSPORT_ERROR_TIMEOUT,
    NK_RESULT_TRANSPORT_PROTOCOL = NK_TRANSPORT_ERROR_PROTOCOL,
    NK_RESULT_TRANSPORT_CANCELED = NK_TRANSPORT_ERROR_CANCELED,
    NK_RESULT_TRANSPORT_WOULD_BLOCK = NK_TRANSPORT_ERROR_WOULD_BLOCK,
    NK_RESULT_TRANSPORT_CLOSED = NK_TRANSPORT_ERROR_CLOSED,
    NK_RESULT_TRANSPORT_ADDRESS_IN_USE = NK_TRANSPORT_ERROR_ADDRESS_IN_USE,
    NK_RESULT_TRANSPORT_RECEIVE_OVERFLOW = NK_TRANSPORT_ERROR_RECEIVE_OVERFLOW
};

#endif

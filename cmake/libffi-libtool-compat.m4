dnl libffi 3.8.0 references this obsolete GNU Libtool macro directly. Some
dnl libtoolize installations no longer ship it, so provide a guarded fallback.
m4_ifndef([LT_SYS_SYMBOL_USCORE], [
  AC_DEFUN([LT_SYS_SYMBOL_USCORE], [
    case "$host" in
      *-apple-* | *-darwin*) sys_symbol_underscore=yes ;;
      *) sys_symbol_underscore=no ;;
    esac
    AC_SUBST([sys_symbol_underscore])
  ])
])

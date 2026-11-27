# Security

Haxeon is pre-1.0: security fixes land on `main` and ship in the next release; older releases are not patched.

Please report a vulnerability privately, through GitHub's **Report a vulnerability** button on this repository's
[Security tab](https://github.com/tritao/haxeon/security), rather than in a public issue. Include what is affected, how
to reproduce it and the impact you see. You will get a reply in the advisory, and the fix and the advisory are published
together.

Areas where a report is especially useful: the profiler's diagnostics port (`hl --diagnostics`) and its token, the
compile server, the live-patching protocol, and code generated from C and C++ headers.

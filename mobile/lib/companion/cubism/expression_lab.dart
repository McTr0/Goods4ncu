/// Debug access to the native Doro expressions/motions on web; safe no-ops
/// elsewhere. Conditionally exported so VM tests can import chat code.
library;

export 'expression_lab_stub.dart'
    if (dart.library.js_interop) 'expression_lab_web.dart';

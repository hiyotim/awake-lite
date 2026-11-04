// AwakeLiteHelper: short-lived hook ingestion.
//
// Reads one bounded vendor payload from stdin, normalizes it through the
// registered family adapter, and writes exactly one immutable event file under
// the app support root. It prints nothing on success, never holds a lock after
// writing, and never acquires a power assertion, starts a timer, or opens a
// network connection.
//
// Every behavior lives in AwakeLiteCore; this file is the process shell.
//
// The import is conditional because the same file is built two ways:
// SwiftPM compiles it as an executable that links the `AwakeLiteCore` module,
// while build.sh compiles it in one swiftc invocation with the library sources,
// where it is already in the same module.

#if canImport(AwakeLiteCore)
import AwakeLiteCore
#endif
import Foundation

exit(HelperEntryPoint.main(arguments: Array(CommandLine.arguments.dropFirst())))

package compiler.core;

/**
 * A command line the tool cannot run as given: an unknown option, a missing or invalid value, options that do not go together.
 * Commands exit with status 2 for it, as for any usage error, and print the message alone.
 */
class UsageError extends haxe.Exception {}

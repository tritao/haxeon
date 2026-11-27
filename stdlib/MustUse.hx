/**
 * A value that must not be dropped: a statement that computes one and does nothing with it is an error (E1033), and so
 * is a lambda whose expression body computes one where the lambda returns Void. `_ = value;` drops one on purpose.
 */
interface MustUse {}

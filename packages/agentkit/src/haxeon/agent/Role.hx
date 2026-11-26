package haxeon.agent;

/** Who sent a message. */
enum Role {
	/** The user, or the host on its behalf, including tool results. */
	User;

	/** The model. */
	Assistant;
}

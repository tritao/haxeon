package nativekit.ui.style;

/** Value-level difference between two computed styles, classified by impact. */
class StyleDiff {
	public final changed:Bool;
	public final impact:StyleImpact;

	public function new(changed:Bool, impact:StyleImpact) {
		this.changed = changed;
		this.impact = impact;
	}

	static final Unchanged = new StyleDiff(false, StyleImpact.None);
	/** Results are immutable and `impact` is a mask of six bits, so each distinct changed result is created once. */
	static final changedByImpact:Array<Null<StyleDiff>> = [for (_ in 0...64) null];

	static function changedWith(impact:StyleImpact):StyleDiff {
		var cached = changedByImpact[impact];
		if (cached != null)
			return cached;
		var created = new StyleDiff(true, impact);
		changedByImpact[impact] = created;
		return created;
	}

	/**
	 * Compares resolved values only. Provenance changes do not invalidate work
	 * when the resulting value is unchanged.
	 */
	public static function compare(previous:Null<ComputedStyle>, current:Null<ComputedStyle>):StyleDiff {
		if (previous == current || previous != null && previous.sharesValuesWith(current))
			return Unchanged;

		var changed = false;
		var impact:StyleImpact = StyleImpact.None;
		for (property in StyleProperty.all()) {
			var previousHas = previous != null && previous.has(property);
			var currentHas = current != null && current.has(property);
			if (previousHas == currentHas && (!previousHas ||
				property.isEqual(previous.peek(property), current.peek(property))))
				continue;
			changed = true;
			impact |= property.impact;
		}
		return changed ? changedWith(impact) : Unchanged;
	}
}

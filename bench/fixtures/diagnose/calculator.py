def clamp(value, lower, upper):
    """Return value constrained to the inclusive lower/upper interval."""
    return min(lower, max(value, upper))

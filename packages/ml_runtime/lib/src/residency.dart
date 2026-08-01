/// Model memory residency (proposal-2 §5, the memory-residency bullet).
///
/// Platform-aware residency fixes the donor's evict-to-one jank: a desktop
/// holds several models at once; a phone holds one, freed before a sibling
/// loads. And a transient load failure earns a bounded cooldown retry —
/// never a session-long sticky demotion.
library;

/// Decides which resident models must be freed before a new one loads.
/// Pure: the caller owns the actual load/free and the LRU bookkeeping.
class ResidencyPolicy {
  /// How many models may be resident at once. Phones: 1. Desktops: several.
  final int maxResident;

  ResidencyPolicy({required this.maxResident}) {
    if (maxResident < 1) {
      throw ArgumentError('ResidencyPolicy: maxResident must be >= 1');
    }
  }

  /// A phone holds exactly one model.
  ResidencyPolicy.phone() : this(maxResident: 1);

  /// A desktop holds several.
  ResidencyPolicy.desktop({int maxResident = 3}) : this(maxResident: maxResident);

  /// The model ids to free, oldest first, so that [incomingId] fits within
  /// [maxResident]. [residentOldestFirst] is the caller's residency list in
  /// load order (least recently loaded first).
  ///
  /// A model that is already resident costs nothing: no evictions.
  List<String> evictionsFor({
    required String incomingId,
    required List<String> residentOldestFirst,
  }) {
    if (residentOldestFirst.contains(incomingId)) return const [];
    final excess = residentOldestFirst.length + 1 - maxResident;
    if (excess <= 0) return const [];
    return List.unmodifiable(residentOldestFirst.take(excess));
  }
}

/// The cooldown law for transient model-load failures: retry is delayed —
/// doubling from [baseCooldown], capped at [maxCooldown] — but NEVER denied
/// permanently. There is no failure count after which a model is demoted
/// for the rest of the session.
class LoadRetryPolicy {
  final Duration baseCooldown;
  final Duration maxCooldown;

  LoadRetryPolicy({
    this.baseCooldown = const Duration(seconds: 30),
    this.maxCooldown = const Duration(minutes: 5),
  }) {
    if (baseCooldown <= Duration.zero || maxCooldown < baseCooldown) {
      throw ArgumentError(
          'LoadRetryPolicy: need 0 < baseCooldown <= maxCooldown');
    }
  }

  /// The wait after [consecutiveFailures] failures: zero for none, then
  /// base * 2^(n-1), capped. Overflow-safe at any failure count.
  Duration cooldownAfter(int consecutiveFailures) {
    if (consecutiveFailures <= 0) return Duration.zero;
    var cooldown = baseCooldown;
    for (var i = 1; i < consecutiveFailures; i++) {
      cooldown *= 2;
      if (cooldown >= maxCooldown) return maxCooldown;
    }
    return cooldown < maxCooldown ? cooldown : maxCooldown;
  }

  /// Whether a load may be attempted now, [sinceLastFailure] after the most
  /// recent failure. With zero failures, always true.
  bool shouldRetry({
    required int consecutiveFailures,
    required Duration sinceLastFailure,
  }) =>
      sinceLastFailure >= cooldownAfter(consecutiveFailures);
}

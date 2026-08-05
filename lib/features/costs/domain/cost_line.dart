import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

/// How much the number behind a line can be trusted.
///
/// Three states, not two, and the third one is the point. `unknown` means the
/// model has nothing to say about this item — not that it costs nothing. A
/// zero would be a claim ("vstup zdarma"); an absent line would be a lie by
/// omission; `unknown` is the only honest third option, and accommodation on
/// a two-day trip is exactly the case that needs it.
enum CostConfidence {
  known('known'),
  estimate('estimate'),
  unknown('unknown');

  const CostConfidence(this.wire);

  final String wire;

  static CostConfidence fromWire(String? v) => switch (v) {
        'known' => CostConfidence.known,
        'unknown' => CostConfidence.unknown,
        _ => CostConfidence.estimate,
      };
}

/// What the line is for. Kept as an enum rather than a label, because the
/// database stores keys and the client assembles the sentence — Czech needs
/// ICU for that and a finished string in a column cannot be re-cased,
/// re-inflected or translated.
enum CostKind {
  transport('transport'),
  entry('entry'),
  food('food'),
  accommodation('accommodation'),
  buffer('buffer');

  const CostKind(this.wire);

  final String wire;

  static CostKind? fromWire(String? v) =>
      CostKind.values.where((CostKind k) => k.wire == v).firstOrNull;
}

/// One line of the per-person estimate.
///
/// Always per person. `transport_options()` already divides fuel by the number
/// of people in the car, so both transport modes arrive comparable and nothing
/// is divided a second time here.
@immutable
class CostLine {
  const CostLine({
    required this.kind,
    required this.confidence,
    this.minCzk,
    this.maxCzk,
  });

  final CostKind kind;
  final CostConfidence confidence;

  /// Null when [confidence] is [CostConfidence.unknown]. Nullable rather than
  /// zero on purpose: the screen has to be able to render "nevíme" and a
  /// number cannot express that.
  final double? minCzk;
  final double? maxCzk;

  bool get hasNumbers => minCzk != null && maxCzk != null;

  /// True when the two ends are close enough that showing a range would be
  /// noise — an entrance fee is one number, not a band.
  bool get isFlat => hasNumbers && (maxCzk! - minCzk!).abs() < 1;

  static CostLine? fromRow(Map<String, dynamic> r) {
    final CostKind? kind = CostKind.fromWire(r['kind'] as String?);
    // An unknown kind means the server grew a line this build has never heard
    // of. Dropping it silently is better than crashing the whole tab, and it
    // makes adding a line a server-only change.
    if (kind == null) return null;
    return CostLine(
      kind: kind,
      confidence: CostConfidence.fromWire(r['confidence'] as String?),
      minCzk: (r['min_czk'] as num?)?.toDouble(),
      maxCzk: (r['max_czk'] as num?)?.toDouble(),
    );
  }
}

/// The lines plus the two totals, so the screen never adds up anything itself.
@immutable
class CostEstimate {
  const CostEstimate(this.lines);

  final List<CostLine> lines;

  bool get isEmpty => lines.isEmpty;

  double get totalMin => lines
      .where((CostLine l) => l.minCzk != null)
      .fold(0, (double a, CostLine l) => a + l.minCzk!);

  double get totalMax => lines
      .where((CostLine l) => l.maxCzk != null)
      .fold(0, (double a, CostLine l) => a + l.maxCzk!);

  /// True when something in the breakdown has no number, which makes the total
  /// a floor rather than an estimate. The screen must say so — a two-day trip
  /// whose total quietly excludes the bed is the single most misleading number
  /// this app could show.
  bool get isPartial =>
      lines.any((CostLine l) => l.confidence == CostConfidence.unknown);
}

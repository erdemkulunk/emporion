import 'dart:math' as math;

import 'package:obtainium/catalog/models.dart';

class EmporionScorer {
  const EmporionScorer._();

  static MetricSnapshot score(MetricSnapshot metrics) {
    final dimensions = <_Dimension>[];

    if (metrics.stars != null) {
      dimensions.add(
        _Dimension(
          weight: 0.15,
          value: _clamp(
            math.log(1 + math.max(0, metrics.stars!)) / math.log(10001),
          ),
          reliability: _estimated(metrics, {'stars'}) ? 0.75 : 1,
        ),
      );
    }

    final development = _weightedTerms([
      _Term(
        weight: 0.6,
        value: metrics.daysSinceCommit == null
            ? null
            : math.exp(-math.max(0, metrics.daysSinceCommit!) / 90),
      ),
      _Term(
        weight: 0.4,
        value: metrics.commits90d == null
            ? null
            : math.min(math.max(0, metrics.commits90d!) / 90, 1),
      ),
    ]);
    if (development != null) {
      dimensions.add(
        _Dimension(
          weight: 0.25,
          value: development.value,
          reliability:
              development.availableWeight *
              (_estimated(metrics, {'daysSinceCommit', 'commits90d'})
                  ? 0.75
                  : 1),
        ),
      );
    }

    final releases = _weightedTerms([
      _Term(
        weight: 0.55,
        value: metrics.daysSinceRelease == null
            ? null
            : math.exp(-math.max(0, metrics.daysSinceRelease!) / 180),
      ),
      _Term(
        weight: 0.45,
        value: metrics.releases365d == null
            ? null
            : math.min(math.max(0, metrics.releases365d!) / 12, 1),
      ),
    ]);
    if (releases != null) {
      dimensions.add(
        _Dimension(
          weight: 0.20,
          value: releases.value,
          reliability:
              releases.availableWeight *
              (_estimated(metrics, {'daysSinceRelease', 'releases365d'})
                  ? 0.75
                  : 1),
        ),
      );
    }

    if (metrics.activeContributors90d != null) {
      dimensions.add(
        _Dimension(
          weight: 0.15,
          value: _clamp(
            math.log(1 + math.max(0, metrics.activeContributors90d!)) /
                math.log(51),
          ),
          reliability: _estimated(metrics, {'activeContributors90d'})
              ? 0.75
              : 1,
        ),
      );
    }

    final issueValues = <double>[
      if (metrics.responseRate != null) _clamp(metrics.responseRate!),
      if (metrics.actionRate != null) _clamp(metrics.actionRate!),
      if (metrics.closeRate != null) _clamp(metrics.closeRate!),
      if (metrics.medianFirstResponseHours != null)
        math.exp(-math.max(0, metrics.medianFirstResponseHours!) / 168),
    ];
    if (issueValues.isNotEmpty && metrics.issueSampleSize > 0) {
      dimensions.add(
        _Dimension(
          weight: 0.25,
          value: issueValues.reduce((a, b) => a + b) / issueValues.length,
          reliability:
              (issueValues.length / 4) *
              math.min(metrics.issueSampleSize / 10, 1),
        ),
      );
    }

    final confidenceWeight = dimensions.fold<double>(
      0,
      (sum, dimension) => sum + dimension.weight * dimension.reliability,
    );
    final confidence = (100 * confidenceWeight).round().clamp(0, 100);
    if (dimensions.length < 3 || confidence < 50 || confidenceWeight == 0) {
      return metrics.copyWith(confidence: confidence);
    }
    final weightedScore = dimensions.fold<double>(
      0,
      (sum, dimension) =>
          sum + dimension.value * dimension.weight * dimension.reliability,
    );
    return metrics.copyWith(
      score: (100 * weightedScore / confidenceWeight).round().clamp(0, 100),
      confidence: confidence,
    );
  }

  static bool _estimated(MetricSnapshot metrics, Set<String> fields) =>
      metrics.estimatedFields.any(fields.contains);

  static _WeightedValue? _weightedTerms(List<_Term> terms) {
    final available = terms.where((term) => term.value != null).toList();
    if (available.isEmpty) return null;
    final availableWeight = available.fold<double>(
      0,
      (sum, term) => sum + term.weight,
    );
    final value =
        available.fold<double>(
          0,
          (sum, term) => sum + _clamp(term.value!) * term.weight,
        ) /
        availableWeight;
    return _WeightedValue(value: value, availableWeight: availableWeight);
  }

  static double _clamp(double value) => value.clamp(0, 1).toDouble();
}

class _Term {
  final double weight;
  final double? value;

  const _Term({required this.weight, required this.value});
}

class _WeightedValue {
  final double value;
  final double availableWeight;

  const _WeightedValue({required this.value, required this.availableWeight});
}

class _Dimension {
  final double weight;
  final double value;
  final double reliability;

  const _Dimension({
    required this.weight,
    required this.value,
    required this.reliability,
  });
}

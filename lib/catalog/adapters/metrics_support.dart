class SampledIssue {
  final bool responded;
  final bool actioned;
  final bool closed;
  final double? firstResponseHours;

  const SampledIssue({
    required this.responded,
    required this.actioned,
    required this.closed,
    this.firstResponseHours,
  });
}

class IssueCareMetrics {
  final int sampleSize;
  final double? responseRate;
  final double? actionRate;
  final double? closeRate;
  final double? medianFirstResponseHours;

  const IssueCareMetrics({
    required this.sampleSize,
    this.responseRate,
    this.actionRate,
    this.closeRate,
    this.medianFirstResponseHours,
  });
}

IssueCareMetrics deriveIssueCare(Iterable<SampledIssue> issues) {
  final sample = issues.toList(growable: false);
  if (sample.isEmpty) return const IssueCareMetrics(sampleSize: 0);
  final count = sample.length;
  final responseTimes =
      sample.map((e) => e.firstResponseHours).whereType<double>().toList()
        ..sort();
  double? median;
  if (responseTimes.isNotEmpty) {
    final middle = responseTimes.length ~/ 2;
    median = responseTimes.length.isOdd
        ? responseTimes[middle]
        : (responseTimes[middle - 1] + responseTimes[middle]) / 2;
  }
  return IssueCareMetrics(
    sampleSize: count,
    responseRate: sample.where((e) => e.responded).length / count,
    actionRate: sample.where((e) => e.actioned).length / count,
    closeRate: sample.where((e) => e.closed).length / count,
    medianFirstResponseHours: median,
  );
}

String normalizedContributorIdentity({
  Object? id,
  Object? login,
  Object? email,
  Object? name,
}) {
  if (id != null) return 'id:${id.toString().toLowerCase()}';
  final candidate = login ?? email ?? name;
  return candidate == null ? '' : candidate.toString().trim().toLowerCase();
}

bool isAutomatedContributor({Object? login, Object? type}) {
  final normalizedLogin = login?.toString().trim().toLowerCase() ?? '';
  final normalizedType = type?.toString().trim().toLowerCase() ?? '';
  return normalizedType == 'bot' ||
      normalizedLogin.endsWith('[bot]') ||
      normalizedLogin.endsWith('-bot') ||
      normalizedLogin == 'bot';
}

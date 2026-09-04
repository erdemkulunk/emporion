import 'package:obtainium/app_sources/fdroid.dart';
import 'package:obtainium/app_sources/fdroidrepo.dart';
import 'package:obtainium/components/generated_form_model.dart';
import 'package:obtainium/custom_errors.dart';
import 'package:obtainium/providers/source_provider.dart';

class IzzyOnDroid extends AppSource {
  final FDroid fd = FDroid();

  IzzyOnDroid() {
    name = 'IzzyOnDroid';
    hosts = ['izzysoft.de'];
    allowSubDomains = true;
  }

  @override
  List<List<GeneratedFormItem>>
  get additionalSourceAppSpecificSettingFormItems =>
      fd.additionalSourceAppSpecificSettingFormItems;

  @override
  String sourceSpecificStandardizeURL(String url, {bool forSelection = false}) {
    final host = Uri.parse(url).host;
    if (host.startsWith('android.')) {
      return standardizeUrlWithRegex(
        url,
        subdomainPrefix: r'android\.',
        pathPattern: r'/repo/apk/[^/]+',
      );
    }
    return standardizeUrlWithRegex(
      url,
      subdomainPrefix: r'apt\.',
      pathPattern: r'/fdroid/index/apk/[^/]+',
    );
  }

  @override
  Future<String?> tryInferringAppId(
    String standardUrl, {
    Map<String, dynamic> additionalSettings = const {},
  }) async {
    return fd.tryInferringAppId(standardUrl);
  }

  @override
  Future<APKDetails> getLatestAPKDetails(
    String standardUrl,
    Map<String, dynamic> additionalSettings,
  ) async {
    try {
      final String? appId = await tryInferringAppId(standardUrl);
      if (appId == null) {
        throw NoReleasesError();
      }
      return await FDroidRepo().getLatestAPKDetails(
        'https://apt.izzysoft.de/fdroid/repo?appId=${Uri.encodeQueryComponent(appId)}',
        {...additionalSettings, 'appIdOrName': appId},
      );
    } catch (e) {
      rethrowOrWrapError(e);
    }
  }
}

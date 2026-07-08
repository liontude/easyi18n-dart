import 'config.dart';
import 'logger.dart';

/// The production origin the token is expected to go to, derived from the
/// single source of truth in [Easyi18nConfig]. Anything else is treated as
/// untrusted for credential purposes.
final String _defaultHost = Uri.parse(Easyi18nConfig.defaultBaseUrl).host;

bool _isLoopback(String host) =>
    host == 'localhost' || host == '127.0.0.1' || host == '::1';

/// Warns before the API token is sent to a host that is not the default
/// production origin, or over plaintext HTTP to a non-loopback host.
///
/// The token is a bearer secret and `baseUrl` comes from a checked-in
/// `easyi18n.yaml`; a value planted in a hostile repo could otherwise redirect
/// the credential to an attacker. Loopback http (the local emulator) is trusted
/// silently so the dev workflow is unaffected.
void warnOnUntrustedTarget(String baseUrl, CliLogger logger) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) return;
  final loopback = _isLoopback(uri.host);
  if (uri.scheme == 'http' && !loopback) {
    logger.warn(
      'Sending your API token over plaintext HTTP to ${uri.host}. '
      'Use https unless you fully trust this network.',
    );
  }
  if (uri.host != _defaultHost && !loopback) {
    logger.warn(
      'baseUrl points at ${uri.host}, not $_defaultHost. Your API token will '
      'be sent there - make sure you trust this easyi18n.yaml.',
    );
  }
}

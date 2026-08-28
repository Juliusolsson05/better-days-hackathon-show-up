/// Normalises the only private profile field before it crosses either repository boundary.
///
/// The hackathon build is SF-only, so treating ten digits as a US number is an explicit product
/// constraint rather than a universal phone parser. When city selection ships, this function is
/// the seam that must be replaced with country-aware parsing; scattering `+1` through widgets
/// would make that migration impossible to audit.
String? normalizeSfPhone(String raw) {
  final trimmed = raw.trim();
  final digits = trimmed.replaceAll(RegExp(r'\D'), '');
  if (trimmed.startsWith('+') && digits.length >= 8 && digits.length <= 15) {
    return '+$digits';
  }
  if (digits.length == 10) return '+1$digits';
  if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
  return null;
}

/// The few names the app prints in more than one place, kept in one spot so a
/// traveler always reads the same plain word (docs/FLAGSHIP_UX_PLAN.md, F1).
///
/// "Region XI" and "IGaCoS" are government and insider labels; travelers say
/// "Davao Region" and "Samal Island". `test/plain_words_test.dart` keeps the
/// old words out of the screens.
class PlainWords {
  PlainWords._();

  static const region = 'Davao Region';
  static const samal = 'Samal Island';

  /// The Discover button that switches to the map. Names what it does, not the
  /// map vendor.
  static const map = 'Map';
}

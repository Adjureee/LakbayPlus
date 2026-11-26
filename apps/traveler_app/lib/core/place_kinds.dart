/// The few kinds of place the catalog's free-text `category` can be read as, so
/// a place with no photo can show a fitting illustration instead of someone
/// else's photo (docs/FLAGSHIP_UX_PLAN.md, F3).
///
/// The catalog category is free text ("Boutique Heritage Beach Resort",
/// "Garden / Eco-Park"), so this reads keywords, first match wins, in the order
/// below: what a traveler would picture first.
enum PlaceKind { beach, water, mountain, culture, nature, stay, other }

PlaceKind placeKindFor(String? category) {
  final text = (category ?? '').toLowerCase();
  bool has(List<String> words) => words.any(text.contains);

  if (has(['beach', 'island', 'surf', 'cove', 'coastal', 'seawall'])) {
    return PlaceKind.beach;
  }
  if (has(['fall', 'river', 'lake', 'spring', 'cruise'])) {
    return PlaceKind.water;
  }
  if (has(['mountain', 'peak', 'trail', 'cape', 'clouds', 'viewpoint', 'hill'])) {
    return PlaceKind.mountain;
  }
  if (has([
    'museum', 'church', 'cathedral', 'landmark', 'heritage', 'cultural',
    'historical', 'rosary', 'religious', 'library', 'plaza',
  ])) {
    return PlaceKind.culture;
  }
  if (has([
    'park', 'nature', 'forest', 'garden', 'mangrove', 'farm', 'eco',
    'reserve', 'wildlife', 'sanctuary', 'agri', 'arboretum',
  ])) {
    return PlaceKind.nature;
  }
  if (has(['resort', 'hotel', 'cafe', 'café', 'restaurant', 'stay'])) {
    return PlaceKind.stay;
  }
  return PlaceKind.other;
}

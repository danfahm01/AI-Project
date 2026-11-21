class User {
  const User({required this.id, required this.email, required this.displayName, required this.createdAt});

  final String id;
  final String email;
  final String displayName;
  final DateTime createdAt;

  List<String> get _nameParts => displayName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();

  /// Up to two initials for the avatar, e.g. "Ana Maria" -> "AM".
  String get initials {
    final parts = _nameParts;
    if (parts.isEmpty) return email.isEmpty ? '?' : _firstRune(email).toUpperCase();
    final first = _firstRune(parts.first);
    final last = parts.length > 1 ? _firstRune(parts.last) : '';
    return (first + last).toUpperCase();
  }

  String get firstName => _nameParts.firstOrNull ?? displayName;

  User copyWith({String? displayName}) =>
      User(id: id, email: email, displayName: displayName ?? this.displayName, createdAt: createdAt);

  static String _firstRune(String value) => value.isEmpty ? '' : String.fromCharCode(value.runes.first);
}

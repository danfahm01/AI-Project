class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.provider,
    this.model,
    this.lastMessageAt,
  });

  final String id;
  final String title;
  final String? provider;
  final String? model;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastMessageAt;

  Conversation copyWith({String? title, String? provider, String? model, DateTime? updatedAt}) => Conversation(
    id: id,
    title: title ?? this.title,
    provider: provider ?? this.provider,
    model: model ?? this.model,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastMessageAt: lastMessageAt,
  );
}

class ConversationPage {
  const ConversationPage({required this.items, this.nextCursor});

  final List<Conversation> items;
  final String? nextCursor;
}

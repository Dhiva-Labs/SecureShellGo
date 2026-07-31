/// A saved shell command the user can fire into any session's shell without
/// retyping it — see `snippet_store.dart` for persistence and
/// `snippet_placeholders.dart` for the `{name}` substitution grammar.
class Snippet {
  const Snippet({
    required this.id,
    required this.name,
    required this.command,
    this.description = '',
  });

  final String id;
  final String name;
  final String command;

  /// Optional, shown under the name in the management list and the picker.
  final String description;

  Snippet copyWith({
    String? id,
    String? name,
    String? command,
    String? description,
  }) {
    return Snippet(
      id: id ?? this.id,
      name: name ?? this.name,
      command: command ?? this.command,
      description: description ?? this.description,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'command': command,
        if (description.isNotEmpty) 'description': description,
      };

  factory Snippet.fromJson(Map<String, dynamic> json) => Snippet(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? '',
        command: (json['command'] as String?) ?? '',
        description: (json['description'] as String?) ?? '',
      );
}

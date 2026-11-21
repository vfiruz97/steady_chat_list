import 'dart:convert';
import 'dart:typed_data';

/// Turns the app's message class into bytes for the cache and back.
///
/// ```dart
/// class ProtoCodec implements MessageCodec<ChatMessage> {
///   @override
///   Uint8List encode(ChatMessage m) => m.writeToBuffer();
///   @override
///   ChatMessage decode(Uint8List bytes) => ChatMessage.fromBuffer(bytes);
/// }
/// ```
abstract interface class MessageCodec<M> {
  /// The bytes stored for [message].
  Uint8List encode(M message);

  /// The message stored as [bytes].
  M decode(Uint8List bytes);
}

/// A [MessageCodec] over the `fromJson` / `toJson` most message classes
/// already have.
///
/// ```dart
/// JsonMessageCodec<ChatMessage>(ChatMessage.fromJson, (m) => m.toJson());
/// ```
final class JsonMessageCodec<M> implements MessageCodec<M> {
  /// Creates a codec from the two JSON functions.
  const JsonMessageCodec(this.fromJson, this.toJson);

  /// Builds a message from a decoded JSON object.
  final M Function(Map<String, Object?> json) fromJson;

  /// Turns a message into a JSON-encodable map.
  final Map<String, Object?> Function(M message) toJson;

  @override
  Uint8List encode(M message) => utf8.encode(jsonEncode(toJson(message)));

  @override
  M decode(Uint8List bytes) =>
      fromJson((jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>());
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'assistant_types.dart';

typedef AssistantHttpClientFactory = HttpClient Function();

/// The limits every provider request runs under. Injectable so a test can
/// use a short timeout and a tiny size cap.
class AssistantHttpLimits {
  const AssistantHttpLimits({
    this.connectTimeout = const Duration(seconds: 20),
    this.requestTimeout = const Duration(seconds: 120),
    this.maxResponseBytes = 4 * 1024 * 1024,
  });

  final Duration connectTimeout;
  final Duration requestTimeout;
  final int maxResponseBytes;
}

class AssistantHttpResponse {
  const AssistantHttpResponse(this.status, this.body);
  final int status;
  final String body;
}

/// Checks [raw] is an address the assistant may send to: https, or http only
/// for this computer (so a local model server works). Anything else would
/// send the API key and the conversation unencrypted.
Uri checkedAssistantUrl(String raw, {required String what}) {
  final Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } on FormatException {
    throw AssistantFailure(
      AssistantFailureKind.config,
      'The $what address is not a valid web address.',
    );
  }
  if (!uri.hasAuthority || uri.host.isEmpty) {
    throw AssistantFailure(
      AssistantFailureKind.config,
      'The $what address is not a valid web address.',
    );
  }
  if (uri.userInfo.isNotEmpty) {
    throw const AssistantFailure(
      AssistantFailureKind.config,
      'The address must not contain a user name or password.',
    );
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') return uri;
  if (scheme == 'http' && _isThisComputer(uri.host)) return uri;
  throw AssistantFailure(
    AssistantFailureKind.config,
    scheme == 'http'
        ? 'The $what address uses http, which is not encrypted. Use an '
              'https address, or a server on this computer (localhost).'
        : 'The $what address must start with https://.',
  );
}

bool _isThisComputer(String host) {
  final h = host.toLowerCase();
  return h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
}

/// POSTs [body] as JSON and reads the whole reply, under [limits]. Throws
/// [AssistantFailure] for a network problem, a timeout, an oversized reply
/// or a cancel; an HTTP error status is returned for the caller to map.
Future<AssistantHttpResponse> assistantPostJson(
  Uri url,
  Map<String, String> headers,
  Object body, {
  required AssistantHttpClientFactory clientFactory,
  required AssistantHttpLimits limits,
  AssistantCancel? cancel,
}) async {
  if (cancel != null && cancel.isCancelled) throw _cancelled;
  final client = clientFactory();
  client.connectionTimeout = limits.connectTimeout;
  // No proxy or credential lookups: the address and headers are all ours.
  var timedOut = false;
  var cancelled = false;
  var tooBig = false;
  final timer = Timer(limits.requestTimeout, () {
    timedOut = true;
    client.close(force: true);
  });
  unawaited(
    cancel?.whenCancelled.then((_) {
      cancelled = true;
      client.close(force: true);
    }),
  );
  try {
    final request = await client.postUrl(url);
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final bytes = utf8.encode(jsonEncode(body));
    request.headers.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
      if (builder.length > limits.maxResponseBytes) {
        tooBig = true;
        client.close(force: true);
        break;
      }
    }
    if (tooBig) {
      throw const AssistantFailure(
        AssistantFailureKind.badResponse,
        'The AI service sent a reply that is too large to handle.',
      );
    }
    return AssistantHttpResponse(
      response.statusCode,
      utf8.decode(builder.takeBytes(), allowMalformed: true),
    );
  } on AssistantFailure {
    rethrow;
  } catch (_) {
    // The exception's text can name the address; the user gets plain words.
    if (cancelled || (cancel?.isCancelled ?? false)) throw _cancelled;
    if (timedOut) {
      throw const AssistantFailure(
        AssistantFailureKind.network,
        'The AI service did not answer in time. Try again.',
      );
    }
    throw const AssistantFailure(
      AssistantFailureKind.network,
      'Could not reach the AI service. Check the connection and the address '
      'in the assistant settings.',
    );
  } finally {
    timer.cancel();
    client.close(force: true);
  }
}

const AssistantFailure _cancelled = AssistantFailure(
  AssistantFailureKind.cancelled,
  'Stopped.',
);

/// Removes anything key-like from text that came from the service before it
/// is shown: the API key itself, bearer tokens and `sk-` style keys.
String scrubServiceText(String text, String apiKey, {int maxLength = 300}) {
  var out = text;
  if (apiKey.length >= 4) out = out.replaceAll(apiKey, '[hidden]');
  out = out
      .replaceAll(
        RegExp(r'(bearer|basic)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
        '[hidden]',
      )
      .replaceAll(RegExp(r'sk-[A-Za-z0-9_-]{8,}'), '[hidden]')
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
      .trim();
  if (out.length > maxLength) out = '${out.substring(0, maxLength)}...';
  return out;
}

/// The failure for an HTTP error [status]; shared by both providers.
/// [serviceMessage] is the service's own explanation, already scrubbed.
AssistantFailure assistantFailureForStatus(int status, String serviceMessage) {
  final detail = serviceMessage.isEmpty ? '' : ' It said: $serviceMessage';
  if (status == 401 || status == 403) {
    return const AssistantFailure(
      AssistantFailureKind.auth,
      'The AI service did not accept the API key. Check the key in the '
      'assistant settings.',
    );
  }
  if (status == 429) {
    return AssistantFailure(
      AssistantFailureKind.rateLimit,
      'The AI service is limiting requests, or the account is out of '
      'credit. Wait a little and try again.$detail',
    );
  }
  if (status >= 500) {
    return AssistantFailure(
      AssistantFailureKind.server,
      'The AI service had a problem (HTTP $status). Try again in a moment.',
    );
  }
  return AssistantFailure(
    AssistantFailureKind.badResponse,
    'The AI service refused the request (HTTP $status).$detail',
  );
}

/// `error.message` from a JSON error body, or ''.
String serviceErrorMessage(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final error = decoded['error'];
      if (error is Map && error['message'] is String) {
        return error['message'] as String;
      }
      if (error is String) return error;
      if (decoded['message'] is String) return decoded['message'] as String;
    }
  } catch (_) {}
  return '';
}

const AssistantFailure unreadableReply = AssistantFailure(
  AssistantFailureKind.badResponse,
  'The AI service sent a reply this app could not read.',
);

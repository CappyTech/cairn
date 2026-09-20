import 'package:flutter_test/flutter_test.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:my_app/services/auth_service.dart';

/// Silent device sign-in creates the account on first launch and logs in every
/// launch after. The tricky bit is that PocketBase returns a 400 both when an
/// account is *absent* (so we should create it) and when one *exists* but the
/// credentials didn't open it (so creating would collide). These cover the pure
/// decision that keeps the two apart — no server needed.
void main() {
  ClientException emailTaken() => ClientException(statusCode: 400, response: {
        'data': {
          'email': {
            'code': 'validation_not_unique',
            'message': 'Value must be unique.',
          },
        },
        'message': 'Failed to create record.',
        'status': 400,
      });

  group('AuthService.isEmailTakenError', () {
    test('recognises the email-uniqueness 400 from users.create', () {
      expect(AuthService.isEmailTakenError(emailTaken()), isTrue);
    });

    test('a different 400 validation error is NOT treated as email-taken', () {
      final e = ClientException(statusCode: 400, response: {
        'data': {
          'password': {'code': 'validation_min_length', 'message': 'too short'},
        },
      });
      expect(AuthService.isEmailTakenError(e), isFalse);
    });

    test('a 400 with no field errors is not email-taken', () {
      final e = ClientException(statusCode: 400, response: {
        'message': 'Failed to authenticate.',
        'data': <String, dynamic>{},
      });
      expect(AuthService.isEmailTakenError(e), isFalse);
    });

    test('a non-400 (e.g. server/network) error is not email-taken', () {
      expect(
        AuthService.isEmailTakenError(
            ClientException(statusCode: 500, response: const {})),
        isFalse,
      );
    });

    test('a non-ClientException is not email-taken', () {
      expect(AuthService.isEmailTakenError(Exception('boom')), isFalse);
    });
  });

  group('DeviceAccountMismatch', () {
    test('reads as an actionable message, not raw server JSON', () {
      final msg = const DeviceAccountMismatch().toString();
      expect(msg, contains('recovery phrase'));
      expect(msg, isNot(contains('ClientException')));
      expect(msg, isNot(contains('validation_not_unique')));
    });
  });
}

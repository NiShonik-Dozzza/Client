import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

/// Контракт подписи обновлений между сервером (Python/cryptography) и клиентом.
///
/// Вектор ниже сгенерирован серверной стороной: приватный ключ = seed
/// bytes(range(32)), артефакт = "efir-test-artifact", подписан sha256-дайджест.
/// Если кто-то поменяет схему (например, начнёт подписывать файл целиком или
/// hex-строку вместо байтов), этот тест упадёт — а не экраны в проде, которые
/// перестанут принимать обновления.
const _publicKeyB64 = 'A6EHv/POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg=';
const _artifact = 'efir-test-artifact';
const _expectedSha256 =
    'e60ba7ba21f631e5ead515d0370836c71001a3de384ee705f23aca8b302919bd';
const _signatureB64 =
    'pFNpUgnyxu5b92VLiJF84pZoiwyJnIwyc8SbH6iO7dDR1G7xnha0sWWEXwyz5IjtuQoTQHhYD8I7eO9OCg72DQ==';

List<int> _hexToBytes(String hex) {
  final out = <int>[];
  for (var i = 0; i + 1 < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return out;
}

Future<bool> _verify({
  required String digestHex,
  required String signatureB64,
  required String publicKeyB64,
}) {
  return Ed25519().verify(
    _hexToBytes(digestHex),
    signature: Signature(
      base64Decode(signatureB64),
      publicKey: SimplePublicKey(
        base64Decode(publicKeyB64),
        type: KeyPairType.ed25519,
      ),
    ),
  );
}

void main() {
  test('sha256 артефакта совпадает с серверным', () {
    expect(sha256.convert(utf8.encode(_artifact)).toString(), _expectedSha256);
  });

  test('подпись сервера проверяется клиентским ключом', () async {
    expect(
      await _verify(
        digestHex: _expectedSha256,
        signatureB64: _signatureB64,
        publicKeyB64: _publicKeyB64,
      ),
      isTrue,
    );
  });

  test('подпись не проходит для другого артефакта', () async {
    final otherDigest = sha256.convert(utf8.encode('подменённый')).toString();
    expect(
      await _verify(
        digestHex: otherDigest,
        signatureB64: _signatureB64,
        publicKeyB64: _publicKeyB64,
      ),
      isFalse,
    );
  });

  test('подпись не проходит с чужим ключом', () async {
    final foreign = await Ed25519().newKeyPair();
    final foreignPublic = await foreign.extractPublicKey();
    expect(
      await _verify(
        digestHex: _expectedSha256,
        signatureB64: _signatureB64,
        publicKeyB64: base64Encode(foreignPublic.bytes),
      ),
      isFalse,
    );
  });
}

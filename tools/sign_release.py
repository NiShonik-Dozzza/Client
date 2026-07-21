#!/usr/bin/env python3
"""Подпись сборок клиента ключом Ed25519 — для раздачи обновлений через панель.

Подписывается sha256-дайджест артефакта (не файл целиком): подписант работает
с коротким значением, а связь с содержимым обеспечивает сам клиент — он считает
sha256 при скачивании и сверяет.

Приватный ключ на сервер не попадает НИКОГДА. Панель хранит только артефакт и
подпись; проверяет её клиент вшитым публичным ключом. Поэтому компрометация
панели не даёт возможности разлить на экраны посторонний бинарь.

Использование:

  # один раз: сгенерировать пару
  python tools/sign_release.py --generate-key
  #   -> приватный ключ в секрет CI UPDATE_SIGNING_KEY_BASE64 (и в офлайн-бэкап)
  #   -> публичный в переменную репозитория EFIR_UPDATE_PUBLIC_KEY
  #      и в .env сервера как CLIENT_UPDATE_PUBLIC_KEY

  # на каждый релиз: подписать артефакты
  python tools/sign_release.py dist/*.apk dist/*.exe dist/*.tar.gz
  #   -> печатает "<файл> <sha256> <подпись base64>"

Ключ читается из переменной окружения UPDATE_SIGNING_KEY_BASE64 (base64 сырых
32 байт) либо из файла по --key-file.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import os
import sys
from pathlib import Path

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except ImportError:  # pragma: no cover
    sys.exit("нужен пакет cryptography:  pip install cryptography")

KEY_ENV = "UPDATE_SIGNING_KEY_BASE64"


def generate_key() -> int:
    private = Ed25519PrivateKey.generate()
    private_b64 = base64.b64encode(private.private_bytes_raw()).decode("ascii")
    public_b64 = base64.b64encode(private.public_key().public_bytes_raw()).decode("ascii")
    print("ПРИВАТНЫЙ ключ (секрет CI UPDATE_SIGNING_KEY_BASE64, плюс офлайн-бэкап):")
    print(f"  {private_b64}")
    print()
    print("ПУБЛИЧНЫЙ ключ (переменная репозитория EFIR_UPDATE_PUBLIC_KEY")
    print("                и CLIENT_UPDATE_PUBLIC_KEY в .env сервера):")
    print(f"  {public_b64}")
    print()
    print("Потеря приватного ключа = невозможность выпускать обновления:")
    print("клиенты в поле проверяют подпись вшитым публичным ключом, и сменить")
    print("его можно только новой сборкой, установленной вручную.")
    return 0


def load_key(key_file: str | None) -> Ed25519PrivateKey:
    raw = ""
    if key_file:
        raw = Path(key_file).read_text(encoding="utf-8").strip()
    else:
        raw = os.environ.get(KEY_ENV, "").strip()
    if not raw:
        sys.exit(f"приватный ключ не задан: ни ${KEY_ENV}, ни --key-file")
    try:
        key_bytes = base64.b64decode(raw, validate=True)
    except Exception:
        sys.exit("приватный ключ должен быть base64 от 32 сырых байт")
    if len(key_bytes) != 32:
        sys.exit("приватный ключ должен быть ровно 32 байта")
    return Ed25519PrivateKey.from_private_bytes(key_bytes)


def sign_file(private: Ed25519PrivateKey, path: Path) -> tuple[str, str]:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    digest_hex = digest.hexdigest()
    signature = base64.b64encode(private.sign(bytes.fromhex(digest_hex))).decode("ascii")
    return digest_hex, signature


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("artifacts", nargs="*", help="файлы для подписи")
    parser.add_argument("--generate-key", action="store_true", help="сгенерировать новую пару ключей")
    parser.add_argument("--key-file", help="файл с приватным ключом (base64)")
    parser.add_argument("--output", help="куда записать сводку (по умолчанию только stdout)")
    args = parser.parse_args()

    if args.generate_key:
        return generate_key()
    if not args.artifacts:
        parser.error("укажите файлы для подписи или --generate-key")

    private = load_key(args.key_file)
    lines: list[str] = []
    for raw_path in args.artifacts:
        path = Path(raw_path)
        if not path.is_file():
            sys.exit(f"нет файла: {path}")
        digest_hex, signature = sign_file(private, path)
        line = f"{path.name}  {digest_hex}  {signature}"
        print(line)
        lines.append(line)

    if args.output:
        Path(args.output).write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

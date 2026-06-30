"""
workout_verification.py  —  Бэкенд верификации тренировок (Blueprint)
=======================================================================

Стек: Python 3.11+, FastAPI, cryptography

Установка зависимостей:
    pip install fastapi uvicorn cryptography pydantic python-jose[cryptography]

Запуск для разработки:
    uvicorn workout_verification:app --reload --port 8080

Производственный запуск (HTTPS обязателен — приложение проверяет пиннинг):
    uvicorn workout_verification:app \
        --host 0.0.0.0 --port 443 \
        --ssl-keyfile /etc/ssl/private.key \
        --ssl-certfile /etc/ssl/certificate.crt

Архитектура верификации:

    1. POST /v1/session/init
       Клиент отправляет clientPublicKey (P-256, base64).
       Сервер генерирует эфемерный ключ, вычисляет общий секрет (ECDH),
       выводит симметричный ключ AES-256 (HKDF-SHA256) и сохраняет его
       в сессионном хранилище (Redis/memcached в production).
       Возвращает serverPublicKey + sessionToken клиенту.

    2. POST /v1/workout/verify
       Клиент отправляет EncryptedWorkoutPayload.
       Сервер:
         a) Восстанавливает ключ из sessionID
         b) Расшифровывает AES-256-GCM (проверяет authentication tag)
         c) Парсит массив LedgerEntry
         d) Верифицирует хэш-цепочку (tamper-evident ledger)
         e) Проверяет хронологию timestamps (anti-replay)
         f) Считает допустимые повторения
         g) Возвращает подписанную квитанцию (HMAC-SHA256)
"""

import base64
import hashlib
import hmac
import json
import os
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional
from uuid import uuid4

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.ec import (
    ECDH,
    EllipticCurvePublicKey,
    SECP256R1,
    generate_private_key,
)
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from fastapi import FastAPI, HTTPException, Request, status
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Конфигурация сервера
# ---------------------------------------------------------------------------

# Секрет подписи серверных квитанций. В production — из HSM или Vault.
SERVER_SIGNING_SECRET = os.environ.get("RECEIPT_SIGNING_SECRET", "СМЕНИТЕ_ДО_ДЕПЛОЯ")

# Максимальное количество повторений за одну тренировочную сессию.
MAX_REPS_PER_SESSION = 500

# Минимальный интервал между последовательными повторениями (микросекунды).
# Физический предел: ~30 повторений/минуту → ≥ 2 000 000 мкс (2 сек)
MIN_REP_INTERVAL_MICROS = 500_000   # 0.5 секунды — консервативный нижний порог

# Максимальный возраст payload (секунды). Payload старше этого = replay-атака.
MAX_PAYLOAD_AGE_SECONDS = 300   # 5 минут

# Хранилище сессионных ключей: sessionID → bytes. В production — Redis.
# Ключи истекают вместе с timeout сессии.
SESSION_KEY_STORE: Dict[str, bytes] = {}

# ---------------------------------------------------------------------------
# Модели данных (Pydantic — автоматическая валидация входящих JSON)
# ---------------------------------------------------------------------------


class HandshakeRequest(BaseModel):
    sessionID: str = Field(..., min_length=36, max_length=36)
    clientPublicKey: str = Field(..., description="P-256 public key, base64 raw representation")
    timestamp: float
    clientVersion: str


class HandshakeResponse(BaseModel):
    serverPublicKey: str
    sessionToken: str
    expiresAt: float


class EncryptedWorkoutPayload(BaseModel):
    ciphertext: str
    nonce: str
    authTag: str
    clientPublicKey: str
    sessionID: str
    createdAt: float
    protocolVersion: int


class LedgerEntry(BaseModel):
    repIndex: int
    timestampMicros: int
    difficultyLevel: float
    jointConfidences: Dict[str, float]
    peakDepthAngle: float
    previousEntryHash: str
    sessionID: str


class ServerReceipt(BaseModel):
    verifiedRepCount: int
    sessionDurationSeconds: float
    status: str
    serverSignature: str
    sessionID: str


# ---------------------------------------------------------------------------
# Инициализация FastAPI
# ---------------------------------------------------------------------------

app = FastAPI(
    title="ExerciseTracker Verification API",
    description="Верификация зашифрованных тренировочных сессий",
    version="1.0.0",
)

# В production ограничьте список допустимых хостов.
app.add_middleware(TrustedHostMiddleware, allowed_hosts=["api.yourfitnessapp.com", "localhost"])


# ---------------------------------------------------------------------------
# POST /v1/session/init  —  ECDH Handshake
# ---------------------------------------------------------------------------


@app.post("/v1/session/init", response_model=HandshakeResponse)
async def session_init(body: HandshakeRequest) -> HandshakeResponse:
    """
    Принимает публичный ключ клиента, выполняет ECDH, сохраняет симметричный
    ключ AES-256, возвращает публичный ключ сервера.
    """
    # Проверяем свежесть запроса (±60 секунд от серверного времени).
    drift = abs(time.time() - body.timestamp)
    if drift > 60:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Временна́я метка запроса устарела (drift={drift:.1f}s)",
        )

    # Парсим публичный ключ клиента (65 байт: 04 || X || Y, uncompressed P-256).
    try:
        client_key_raw = base64.b64decode(body.clientPublicKey)
        client_public_key = _load_raw_ec_public_key(client_key_raw)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Некорректный публичный ключ клиента: {exc}",
        )

    # Генерируем эфемерную серверную пару ключей.
    server_private_key = generate_private_key(SECP256R1())

    # ECDH: вычисляем общий секрет.
    shared_secret = server_private_key.exchange(ECDH(), client_public_key)

    # HKDF-SHA256 → AES-256 ключ (32 байта). Тот же алгоритм что и на клиенте.
    aes_key = _derive_aes_key(shared_secret, session_id=body.sessionID)

    # Сохраняем ключ в хранилище сессий.
    SESSION_KEY_STORE[body.sessionID] = aes_key

    # Публичный ключ сервера в raw representation (base64) → клиенту.
    server_pub_raw = server_private_key.public_key().public_bytes(
        encoding=serialization.Encoding.X962,
        format=serialization.PublicFormat.UncompressedPoint,
    )

    session_token = str(uuid4())   # В production — JWT с подписью
    return HandshakeResponse(
        serverPublicKey=base64.b64encode(server_pub_raw).decode(),
        sessionToken=session_token,
        expiresAt=time.time() + 3600,   # Сессия живёт 1 час
    )


# ---------------------------------------------------------------------------
# POST /v1/workout/verify  —  Расшифровка и верификация тренировки
# ---------------------------------------------------------------------------


@app.post("/v1/workout/verify", response_model=ServerReceipt)
async def workout_verify(body: EncryptedWorkoutPayload) -> ServerReceipt:
    """
    Расшифровывает AES-256-GCM payload, верифицирует цепочку хэшей,
    проверяет хронологию и возвращает подписанную квитанцию.
    """
    # 1. Проверка возраста payload (anti-replay на уровне транспорта).
    age = time.time() - body.createdAt
    if age > MAX_PAYLOAD_AGE_SECONDS or age < -60:
        return _build_receipt(body.sessionID, 0, 0.0, "REPLAY_ATTACK")

    # 2. Получаем сессионный ключ.
    aes_key = SESSION_KEY_STORE.get(body.sessionID)
    if aes_key is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Сессия '{body.sessionID}' не найдена или истекла",
        )

    # 3. Расшифровка AES-256-GCM.
    try:
        entries = _decrypt_and_parse(body, aes_key)
    except InvalidGCMTag:
        # GCM тег не прошёл → payload модифицирован → отклоняем полностью.
        return _build_receipt(body.sessionID, 0, 0.0, "REJECTED")
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"Ошибка расшифровки: {exc}",
        )

    # 4. Верификация хэш-цепочки (tamper-evident ledger).
    chain_ok, chain_msg = _verify_hash_chain(entries)
    if not chain_ok:
        return _build_receipt(body.sessionID, 0, 0.0, "LEDGER_CORRUPT")

    # 5. Хронологическая верификация (anti-replay и физическая достижимость).
    timeline_ok, valid_entries = _verify_timeline(entries)
    if not timeline_ok and len(valid_entries) == 0:
        return _build_receipt(body.sessionID, 0, 0.0, "REPLAY_ATTACK")

    # 6. Подсчёт верифицированных повторений.
    verified_count = min(len(valid_entries), MAX_REPS_PER_SESSION)

    # 7. Вычисляем длительность по первой и последней метке.
    duration = _session_duration(valid_entries)

    # 8. Определяем итоговый статус.
    if verified_count == len(entries):
        receipt_status = "VERIFIED"
    elif verified_count > 0:
        receipt_status = "PARTIAL_CREDIT"
    else:
        receipt_status = "REJECTED"

    # Очищаем ключ из хранилища — сессия одноразовая.
    SESSION_KEY_STORE.pop(body.sessionID, None)

    return _build_receipt(body.sessionID, verified_count, duration, receipt_status)


# ---------------------------------------------------------------------------
# Внутренние функции
# ---------------------------------------------------------------------------


def _load_raw_ec_public_key(raw_bytes: bytes) -> EllipticCurvePublicKey:
    """Загружает P-256 публичный ключ из uncompressed raw representation (65 байт)."""
    return serialization.load_der_public_key(
        _raw_to_spki_der(raw_bytes)
    )


def _raw_to_spki_der(raw: bytes) -> bytes:
    """
    Оборачивает raw EC P-256 ключ (65 байт) в DER-кодированный SPKI блок.
    Тот же заголовок, что использует клиент для пиннинга SPKI хэша.
    """
    # ASN.1 SPKI заголовок для P-256 (RFC 5480)
    header = bytes([
        0x30, 0x59,
        0x30, 0x13,
        0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
        0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,
        0x03, 0x42, 0x00,
    ])
    return header + raw


def _derive_aes_key(shared_secret: bytes, session_id: str) -> bytes:
    """
    HKDF-SHA256: из ECDH общего секрета выводит 256-битный AES ключ.
    Параметры ДОЛЖНЫ совпадать с реализацией на клиенте (Swift CryptoKit).
    """
    info = f"ExerciseTracker-v1-AES256GCM-{session_id}".encode()
    salt = b"workout-ledger-salt-v1"
    hkdf = HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=salt,
        info=info,
    )
    return hkdf.derive(shared_secret)


class InvalidGCMTag(Exception):
    """AES-GCM тег аутентификации не совпал — данные повреждены или подделаны."""


def _decrypt_and_parse(body: EncryptedWorkoutPayload, key: bytes) -> List[LedgerEntry]:
    """
    Расшифровывает AES-256-GCM payload и парсит список LedgerEntry.
    Выбрасывает InvalidGCMTag при несовпадении тега.
    """
    try:
        nonce      = base64.b64decode(body.nonce)       # 12 байт
        ciphertext = base64.b64decode(body.ciphertext)
        auth_tag   = base64.b64decode(body.authTag)     # 16 байт

        # AESGCM.decrypt ожидает ciphertext + tag слитно (combined format).
        combined = ciphertext + auth_tag

        aesgcm = AESGCM(key)
        # Выбрасывает InvalidTag если GCM аутентификация провалилась.
        plaintext = aesgcm.decrypt(nonce, combined, associated_data=None)
    except Exception as exc:
        if "InvalidTag" in type(exc).__name__ or "Authentication" in str(exc):
            raise InvalidGCMTag(str(exc)) from exc
        raise

    raw = json.loads(plaintext.decode("utf-8"))
    return [LedgerEntry(**entry) for entry in raw]


def _verify_hash_chain(entries: List[LedgerEntry]) -> tuple[bool, str]:
    """
    Проверяет, что каждая запись корректно ссылается на хэш предыдущей.
    Любое изменение/вставка/удаление записи ломает цепочку.
    """
    expected_prev = "GENESIS"
    for entry in entries:
        if entry.previousEntryHash != expected_prev:
            return False, f"rep {entry.repIndex}: ожидался hash '{expected_prev}'"
        expected_prev = _hash_entry(entry)
    return True, "OK"


def _hash_entry(entry: LedgerEntry) -> str:
    """SHA-256 записи реестра в hex. Должен совпадать с hashEntry() на клиенте."""
    # JSON с сортировкой ключей — детерминированный вывод, как JSONEncoder.sortedKeys.
    data = json.dumps(entry.model_dump(), sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(data).hexdigest()


def _verify_timeline(entries: List[LedgerEntry]) -> tuple[bool, List[LedgerEntry]]:
    """
    Проверяет хронологическую достоверность записей:

    1. repIndex должны строго возрастать (1, 2, 3, ...)
    2. Интервал между последовательными повторениями ≥ MIN_REP_INTERVAL_MICROS
       (невозможно сделать 10 подтягиваний за 1 секунду)
    3. Нет дубликатов timestamps (буквальный replay)

    Возвращает (все_ок, список_верифицированных_записей).
    """
    if not entries:
        return True, []

    valid: List[LedgerEntry] = []
    seen_timestamps = set()
    prev_ts = None

    for i, entry in enumerate(entries):
        # Порядковый номер должен совпадать с позицией в массиве (1-based).
        if entry.repIndex != i + 1:
            continue

        # Дублирующиеся временны́е метки → replay в рамках одного payload.
        if entry.timestampMicros in seen_timestamps:
            continue
        seen_timestamps.add(entry.timestampMicros)

        # Минимальный физический интервал между повторениями.
        if prev_ts is not None:
            interval = entry.timestampMicros - prev_ts
            if interval < MIN_REP_INTERVAL_MICROS:
                continue   # Слишком быстро — физически невозможно

        prev_ts = entry.timestampMicros
        valid.append(entry)

    all_ok = len(valid) == len(entries)
    return all_ok, valid


def _session_duration(entries: List[LedgerEntry]) -> float:
    """Длительность сессии в секундах по крайним временны́м меткам."""
    if len(entries) < 2:
        return 0.0
    first = entries[0].timestampMicros
    last  = entries[-1].timestampMicros
    return (last - first) / 1_000_000.0


def _build_receipt(
    session_id: str,
    rep_count: int,
    duration: float,
    receipt_status: str,
) -> ServerReceipt:
    """
    Создаёт квитанцию и подписывает её HMAC-SHA256.
    Клиент должен верифицировать подпись перед доверием счётчику.
    """
    payload = f"{session_id}:{rep_count}:{receipt_status}:{int(time.time())}"
    signature = hmac.new(
        SERVER_SIGNING_SECRET.encode(),
        payload.encode(),
        hashlib.sha256,
    ).hexdigest()

    return ServerReceipt(
        verifiedRepCount=rep_count,
        sessionDurationSeconds=duration,
        status=receipt_status,
        serverSignature=signature,
        sessionID=session_id,
    )


# ---------------------------------------------------------------------------
# Вспомогательный endpoint для получения SPKI хэша сервера (только dev!)
# ---------------------------------------------------------------------------


@app.get("/dev/spki-hash", include_in_schema=False)
async def dev_spki_hash(request: Request) -> dict:
    """
    ТОЛЬКО ДЛЯ РАЗРАБОТКИ. Возвращает SPKI хэш сертификата сервера.
    Удалите или защитите паролем в production!

    Используйте этот хэш для настройки CertificatePinConfig на клиенте.
    """
    return {
        "note": "Запустите openssl для получения реального хэша. Этот endpoint — заглушка.",
        "command": (
            "openssl s_client -connect api.yourfitnessapp.com:443 </dev/null 2>/dev/null "
            "| openssl x509 -pubkey -noout "
            "| openssl pkey -pubin -outform DER "
            "| openssl dgst -sha256 -binary | base64"
        ),
    }

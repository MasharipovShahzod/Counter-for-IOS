//
//  SecureStateLedger.swift
//  ExerciseTracker — Security Layer 3
//
//  СЛОЙ 3: Криптографический реестр состояний и шифрование payload.
//
//  Схема работы:
//
//  1. Начало сессии: клиент генерирует эфемерную пару ключей P-256,
//     отправляет clientPublicKey серверу → сервер отвечает serverPublicKey.
//
//  2. ECDH-рукопожатие: обе стороны независимо вычисляют одинаковый
//     общий секрет (Diffie-Hellman на кривой P-256).
//
//  3. HKDF-SHA256: из общего секрета + контекста сессии выводится
//     256-битный симметричный ключ AES-256.
//
//  4. Каждое засчитанное повторение добавляется в реестр как LedgerEntry:
//       { repIndex, timestamp(µs), difficultyLevel, jointConfidences[], peakDepthAngle,
//         previousEntryHash, sessionID }
//     Поле previousEntryHash связывает записи в цепочку (tamper-evident log).
//
//  5. Финализация: весь массив LedgerEntry сериализуется в JSON и шифруется
//     AES-256-GCM с уникальным 96-битным nonce. SealedBox содержит
//     ciphertext + authentication tag (16 байт GCM-тег).
//
//  6. Сервер расшифровывает payload, проверяет GCM-тег, верифицирует
//     хронологическую последовательность timestamps и хэш-цепочку.
//

import Foundation
import CryptoKit

// MARK: - Запись реестра (один зачтённый повтор)

/// Неизменяемая атомарная запись об одном повторении. Все поля критичны
/// для серверной верификации — не удаляйте ни одно без обновления бэкенда.
public struct LedgerEntry: Codable, Sendable {

    /// Порядковый номер повторения внутри данной сессии (начиная с 1).
    public let repIndex: Int

    /// Unix timestamp с точностью до микросекунды (Date.timeIntervalSince1970 × 1_000_000).
    public let timestampMicros: Int64

    /// Уровень сложности в момент засчёта: 0.0 → лёгкий, 1.0 → максимальный.
    public let difficultyLevel: Double

    /// Уверенность Vision для каждого ключевого сустава на момент завершения повтора.
    /// Ключи — строковые имена суставов (e.g., "leftShoulder").
    public let jointConfidences: [String: Float]

    /// Минимальный угол первичного сустава (глубина повтора в градусах).
    public let peakDepthAngle: Double

    /// SHA-256 хэш предыдущей записи (HEX). Для первой записи — "GENESIS".
    /// Любая вставка/удаление записи в середине цепочки ломает эту связь.
    public let previousEntryHash: String

    /// UUID сессии, к которой относится эта запись.
    public let sessionID: String
}

// MARK: - Зашифрованный payload для отправки на сервер

/// Структура, отправляемая POST /v1/workout/verify.
/// Сервер не может прочитать содержимое без симметричного ключа,
/// но может проверить GCM-тег для обнаружения любой модификации.
public struct EncryptedWorkoutPayload: Codable, Sendable {

    /// AES-GCM зашифрованные данные (base64).
    public let ciphertext: String

    /// 96-битный случайный nonce, уникальный для данного payload (base64).
    public let nonce: String

    /// 128-битный GCM аутентификационный тег (base64).
    public let authTag: String

    /// Raw representation публичного ключа клиента (base64, P-256 uncompressed).
    /// Сервер использует его для повторного вычисления общего секрета.
    public let clientPublicKey: String

    /// UUID сессии (должен совпадать с данными handshake).
    public let sessionID: String

    /// Unix timestamp создания payload (для защиты от replay на уровне транспорта).
    public let createdAt: Double

    /// Версия схемы шифрования (для поддержки будущих миграций).
    public let protocolVersion: Int
}

// MARK: - Ошибки реестра

public enum LedgerError: LocalizedError {
    case keyNotEstablished
    case emptyLedger
    case invalidServerKey(detail: String)
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .keyNotEstablished:
            return "Симметричный ключ не установлен — сначала выполните ECDH handshake"
        case .emptyLedger:
            return "Реестр пуст — нечего экспортировать"
        case .invalidServerKey(let d):
            return "Некорректный публичный ключ сервера: \(d)"
        case .encryptionFailed:
            return "Ошибка AES-256-GCM шифрования"
        case .decryptionFailed:
            return "Ошибка расшифровки или неверный GCM-тег"
        }
    }
}

// MARK: - Криптографический контекст сессии

/// Управляет эфемерными ключами P-256 и производным AES-256 ключом.
/// Один экземпляр = одна тренировочная сессия; никогда не переиспользуйте.
final class SessionCryptoContext: @unchecked Sendable {

    // Эфемерный приватный ключ клиента генерируется один раз при старте сессии.
    private let privateKey = P256.KeyAgreement.PrivateKey()

    /// Raw representation (65 байт, uncompressed 04||X||Y) → base64 для сервера.
    var clientPublicKeyBase64: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    /// Производный симметричный ключ AES-256. Доступен после deriveSharedKey().
    private(set) var symmetricKey: SymmetricKey?

    /// Завершает ECDH и выводит симметричный ключ через HKDF-SHA256.
    ///
    /// - Parameters:
    ///   - serverPublicKeyBase64: raw P-256 public key сервера в base64
    ///   - sessionID: контекстная метка для HKDF info (предотвращает переиспользование ключа)
    func deriveSharedKey(serverPublicKeyBase64: String, sessionID: String) throws {
        guard let rawData = Data(base64Encoded: serverPublicKeyBase64) else {
            throw LedgerError.invalidServerKey(detail: "base64 decode failed")
        }
        let serverPublicKey: P256.KeyAgreement.PublicKey
        do {
            serverPublicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: rawData)
        } catch {
            throw LedgerError.invalidServerKey(detail: error.localizedDescription)
        }

        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: serverPublicKey)

        // HKDF-SHA256: разные info → разные ключи из одного секрета → domain separation.
        let info = Data("ExerciseTracker-v1-AES256GCM-\(sessionID)".utf8)
        let salt = Data("workout-ledger-salt-v1".utf8)

        symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: info,
            outputByteCount: 32   // 256 бит = AES-256
        )
    }
}

// MARK: - Защищённый реестр состояний

/// Накапливает криптографически связанные записи повторений и шифрует их
/// для отправки на сервер верификации.
public final class SecureStateLedger: @unchecked Sendable {

    // MARK: Внутреннее состояние

    private var entries: [LedgerEntry] = []
    private let crypto = SessionCryptoContext()
    private var isKeyEstablished = false

    /// UUID текущей тренировочной сессии. Фиксируется при инициализации.
    public let sessionID = UUID().uuidString

    // MARK: Инициализация

    public init() {}

    // MARK: Публичные свойства

    /// Количество записанных повторений.
    public var repCount: Int { entries.count }

    /// Публичный ключ клиента для отправки серверу в /v1/session/init.
    public var clientPublicKeyBase64: String { crypto.clientPublicKeyBase64 }

    // MARK: ECDH Handshake

    /// Принимает публичный ключ сервера и завершает ECDH-рукопожатие.
    /// Вызывать после получения ответа от /v1/session/init.
    public func establishSharedKey(serverPublicKeyBase64: String) throws {
        try crypto.deriveSharedKey(
            serverPublicKeyBase64: serverPublicKeyBase64,
            sessionID: sessionID
        )
        isKeyEstablished = true
    }

    // MARK: Запись повторений

    /// Добавляет криптографически связанную запись о засчитанном повторении.
    ///
    /// - Parameters:
    ///   - repIndex:         порядковый номер повторения (1-based)
    ///   - jointConfidences: уверенность Vision по суставам
    ///   - peakDepthAngle:   угол первичного сустава в нижней точке (°)
    ///   - difficultyLevel:  уровень сложности (0.0–1.0)
    public func recordRep(
        repIndex: Int,
        jointConfidences: [String: Float],
        peakDepthAngle: Double,
        difficultyLevel: Double = 1.0
    ) {
        // SHA-256 предыдущей записи связывает записи в цепочку.
        let previousHash = entries.last.map(hashEntry) ?? "GENESIS"

        let entry = LedgerEntry(
            repIndex: repIndex,
            timestampMicros: Int64(Date().timeIntervalSince1970 * 1_000_000),
            difficultyLevel: difficultyLevel,
            jointConfidences: jointConfidences,
            peakDepthAngle: peakDepthAngle,
            previousEntryHash: previousHash,
            sessionID: sessionID
        )
        entries.append(entry)
    }

    // MARK: Шифрование и экспорт

    /// Сериализует реестр в JSON и шифрует AES-256-GCM.
    /// Готовый payload передаётся в TransportLayer для отправки на сервер.
    ///
    /// - Throws: `LedgerError` если ключ не установлен, реестр пуст или шифрование не удалось.
    public func exportEncryptedPayload() throws -> EncryptedWorkoutPayload {
        guard isKeyEstablished, let symmetricKey = crypto.symmetricKey else {
            throw LedgerError.keyNotEstablished
        }
        guard !entries.isEmpty else {
            throw LedgerError.emptyLedger
        }

        // Детерминированная сортировка ключей JSON → стабильный хэш на сервере.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plaintext = try encoder.encode(entries)

        // AES-256-GCM с auto-генерацией случайного 96-битного nonce.
        guard let sealedBox = try? AES.GCM.seal(plaintext, using: symmetricKey),
              let combined = sealedBox.combined else {
            throw LedgerError.encryptionFailed
        }

        // combined layout: [12 bytes nonce] [N bytes ciphertext] [16 bytes GCM tag]
        let nonceData = Data(combined.prefix(12))
        let tagData   = Data(combined.suffix(16))
        let ctData    = Data(combined.dropFirst(12).dropLast(16))

        return EncryptedWorkoutPayload(
            ciphertext: ctData.base64EncodedString(),
            nonce: nonceData.base64EncodedString(),
            authTag: tagData.base64EncodedString(),
            clientPublicKey: crypto.clientPublicKeyBase64,
            sessionID: sessionID,
            createdAt: Date().timeIntervalSince1970,
            protocolVersion: 1
        )
    }

    /// Очищает записи повторений, не трогая криптоконтекст.
    public func clearEntries() { entries.removeAll() }

    // MARK: Хэш записи

    /// Детерминированный SHA-256 хэш записи реестра (lowercase hex).
    private func hashEntry(_ entry: LedgerEntry) -> String {
        guard let data = try? JSONEncoder().encode(entry) else { return "HASH_ERROR" }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

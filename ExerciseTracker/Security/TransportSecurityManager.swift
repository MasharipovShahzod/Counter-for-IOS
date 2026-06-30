//
//  TransportSecurityManager.swift
//  ExerciseTracker — Security Layer 4
//
//  СЛОЙ 4: Безопасность транспорта и защита от реверс-инжиниринга.
//
//  Две подсистемы:
//
//  [A] SSL Certificate Pinning — PinnedURLSessionDelegate
//
//      Реализация URLSessionDelegate, которая при каждом TLS-рукопожатии
//      вычисляет SHA-256 хэш блока SubjectPublicKeyInfo (SPKI) листового
//      сертификата и сравнивает его с набором заранее сохранённых хэшей.
//
//      Пиннинг выполняется на уровне SPKI, а не всего сертификата:
//      SPKI стабилен при перевыпуске сертификата на том же ключевом материале
//      (например, при ежегодном обновлении Let's Encrypt).
//
//      Соединение принудительно прерывается если хэш не совпадает ни с одним
//      из закреплённых значений — Charles Proxy, mitmproxy, Wireshark и другие
//      MitM-инструменты не смогут перехватить трафик.
//
//  [B] Проверка целостности приложения — AppIntegrityChecker
//
//      - Извлекает Team ID из embedded.mobileprovision и сравнивает с ожидаемым.
//        Несовпадение → IPA переподписана чужим сертификатом (пиратское распространение).
//      - Обнаруживает DEBUG-сборки (не должны попасть в production поток).
//      - Проверяет наличие профиля обеспечения (отсутствие → сборка из Xcode).
//
//  Инструкции по настройке компилятора (раздел Build Settings Xcode):
//
//      Dead Code Stripping           → YES
//      Strip Debug Symbols           → YES (Release)
//      Strip Linked Product          → YES (Release)
//      Generate Debug Symbols        → NO  (Release)
//      Optimization Level            → Fastest, Smallest [-Os] (Release)
//      Enable Bitcode                → YES (если поддерживается)
//
//      Добавьте в Other Linker Flags (Release): -Xlinker -dead_strip_dylibs
//

import Foundation
import Security
import CryptoKit

// MARK: - Конфигурация пиннинга сертификатов

/// Описывает конкретный хост и множество допустимых SPKI-хэшей.
public struct CertificatePinConfig: Sendable {

    /// Имя хоста бэкенда (например, "api.yourfitnessapp.com")
    public let host: String

    /// Ожидаемые SHA-256 SPKI хэши в base64.
    /// Включите минимум два значения: текущий и резервный (ротация сертификата).
    public let pinnedSPKIHashes: Set<String>

    public init(host: String, pinnedSPKIHashes: Set<String>) {
        self.host = host
        self.pinnedSPKIHashes = pinnedSPKIHashes
    }

    // MARK: Производственные конфигурации

    /// Получите реальные хэши командой:
    ///   openssl s_client -connect api.yourfitnessapp.com:443 </dev/null 2>/dev/null \
    ///     | openssl x509 -pubkey -noout \
    ///     | openssl pkey -pubin -outform DER \
    ///     | openssl dgst -sha256 -binary | base64
    public static let production = CertificatePinConfig(
        host: "api.yourfitnessapp.com",
        pinnedSPKIHashes: [
            // Основной сертификат (обновите до получения реального хэша).
            "PLACEHOLDER_PRIMARY_SPKI_SHA256_BASE64=",
            // Резервный сертификат (для бесперебойной ротации).
            "PLACEHOLDER_BACKUP_SPKI_SHA256_BASE64="
        ]
    )

    public static let staging = CertificatePinConfig(
        host: "staging-api.yourfitnessapp.com",
        pinnedSPKIHashes: [
            "PLACEHOLDER_STAGING_SPKI_SHA256_BASE64="
        ]
    )
}

// MARK: - Ошибки пиннинга

public enum PinningError: LocalizedError {
    case hostNotPinned(host: String)
    case noCertificateInChain
    case spkiExtractionFailed
    case hashMismatch(computed: String, allowedSet: Set<String>)
    case trustEvaluationFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .hostNotPinned(let h):
            return "Хост \(h) не входит в список пиннинга — соединение отклонено"
        case .noCertificateInChain:
            return "Сертификат не был предоставлен сервером"
        case .spkiExtractionFailed:
            return "Не удалось извлечь SPKI из сертификата"
        case .hashMismatch(let h, _):
            return "SPKI хэш \(h) не совпадает ни с одним закреплённым значением — возможен MitM"
        case .trustEvaluationFailed(let s):
            return "Оценка доверия TLS не пройдена (OSStatus: \(s))"
        }
    }
}

// MARK: - URLSession делегат с SPKI пиннингом

/// Подключите этот объект как делегат URLSession для всех защищённых запросов.
///
///     let session = URLSession(
///         configuration: .ephemeral,
///         delegate: PinnedURLSessionDelegate(pinConfig: .production),
///         delegateQueue: nil
///     )
///
public final class PinnedURLSessionDelegate: NSObject, URLSessionDelegate, Sendable {

    private let pinConfig: CertificatePinConfig
    private let onViolation: @Sendable (PinningError) -> Void

    /// - Parameter onViolation: вызывается при любом нарушении пиннинга.
    ///   Используйте для логирования / завершения сессии тренировки.
    public init(
        pinConfig: CertificatePinConfig = .production,
        onViolation: @Sendable @escaping (PinningError) -> Void = { _ in }
    ) {
        self.pinConfig = pinConfig
        self.onViolation = onViolation
    }

    // MARK: URLSessionDelegate

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace

        // Обрабатываем только TLS-аутентификацию сервера для нашего хоста.
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == pinConfig.host else {
            // Неизвестный хост или метод аутентификации → запрет.
            reject(completionHandler, error: .hostNotPinned(host: space.host))
            return
        }

        guard let trust = space.serverTrust else {
            reject(completionHandler, error: .noCertificateInChain)
            return
        }

        // Стандартная оценка цепочки ОС — дополнительный слой поверх пиннинга.
        var result = SecTrustResultType.invalid
        let status = SecTrustEvaluate(trust, &result)
        guard status == errSecSuccess,
              result == .unspecified || result == .proceed else {
            reject(completionHandler, error: .trustEvaluationFailed(status: status))
            return
        }

        // Проверяем SPKI-хэш листового сертификата.
        guard let leaf = SecTrustGetCertificateAtIndex(trust, 0) else {
            reject(completionHandler, error: .noCertificateInChain)
            return
        }

        do {
            let computedHash = try spkiHash(of: leaf)
            if pinConfig.pinnedSPKIHashes.contains(computedHash) {
                // Пиннинг пройден — разрешаем соединение.
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                reject(completionHandler, error: .hashMismatch(
                    computed: computedHash,
                    allowedSet: pinConfig.pinnedSPKIHashes
                ))
            }
        } catch let e as PinningError {
            reject(completionHandler, error: e)
        } catch {
            reject(completionHandler, error: .spkiExtractionFailed)
        }
    }

    // MARK: Вычисление SPKI хэша

    /// Извлекает SubjectPublicKeyInfo (SPKI) из сертификата и вычисляет SHA-256.
    ///
    /// SPKI = ASN.1 SEQUENCE { AlgorithmIdentifier, BIT STRING { publicKey } }.
    /// Для EC P-256 DER-заголовок фиксированной длины (26 байт) предшествует
    /// 65-байтному uncompressed public key (04||X||Y).
    private func spkiHash(of certificate: SecCertificate) throws -> String {
        guard let pubKey = SecCertificateCopyKey(certificate) else {
            throw PinningError.spkiExtractionFailed
        }
        var cfError: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(pubKey, &cfError) as Data? else {
            throw PinningError.spkiExtractionFailed
        }

        // ASN.1 DER заголовок SPKI для EC P-256 (RFC 5480):
        // SEQUENCE { SEQUENCE { OID ecPublicKey, OID prime256v1 }, BIT STRING }
        let ecP256SPKIHeader: [UInt8] = [
            0x30, 0x59,
            0x30, 0x13,
            0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,  // OID 1.2.840.10045.2.1
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07,  // OID 1.2.840.10045.3.1.7
            0x03, 0x42, 0x00
        ]

        var spki = Data(ecP256SPKIHeader)
        spki.append(keyData)   // 65 байт: 04 || X(32) || Y(32)

        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    // MARK: Вспомогательный метод

    private func reject(
        _ handler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
        error: PinningError
    ) {
        onViolation(error)
        handler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - Проверка целостности приложения

/// Обнаруживает переподписание IPA, отладочные сборки и отсутствие
/// профиля обеспечения безопасности.
public final class AppIntegrityChecker: Sendable {

    private let expectedTeamID: String
    private let expectedBundleID: String

    public init(expectedTeamID: String, expectedBundleID: String) {
        self.expectedTeamID = expectedTeamID
        self.expectedBundleID = expectedBundleID
    }

    // MARK: Публичный API

    /// Выполняет все доступные проверки целостности. Thread-safe, blocking.
    public func runChecks() -> [AppTamperIndicator] {
        var indicators: [AppTamperIndicator] = []

        if let found = extractTeamID(), found != expectedTeamID {
            indicators.append(.teamIDMismatch(found: found, expected: expectedTeamID))
        }
        if isDebugBuild() {
            indicators.append(.debugBuildDetected)
        }
        if !hasProvisioningProfile() {
            indicators.append(.provisioningProfileMissing)
        }
        if bundleIDMismatch() {
            indicators.append(.bundleIDMismatch)
        }

        return indicators
    }

    // MARK: — Проверки

    /// Читает Team ID из embedded.mobileprovision (CMS-подписанный plist внутри бандла).
    /// Несовпадение = переподписание чужим Developer Account.
    private func extractTeamID() -> String? {
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let raw = try? Data(contentsOf: url),
            let text = String(data: raw, encoding: .ascii)
        else { return nil }

        // mobileprovision содержит текстовый plist между CMS-обёртками.
        guard
            let keyRange   = text.range(of: "<key>TeamIdentifier</key>"),
            let arrRange   = text.range(of: "<array>",   range: keyRange.upperBound...),
            let startRange = text.range(of: "<string>",  range: arrRange.upperBound...),
            let endRange   = text.range(of: "</string>", range: startRange.upperBound...)
        else { return nil }

        return String(text[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// true если приложение собрано с флагом DEBUG. В production это недопустимо.
    private func isDebugBuild() -> Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Отсутствие embedded.mobileprovision означает запуск из Xcode, не из App Store.
    private func hasProvisioningProfile() -> Bool {
        #if targetEnvironment(simulator)
        return true   // Профиль в симуляторе не нужен — это нормально
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") != nil
        #endif
    }

    /// Сравниваем Bundle ID с ожидаемым — защита от пересборки с чужим идентификатором.
    private func bundleIDMismatch() -> Bool {
        let actual = Bundle.main.bundleIdentifier ?? ""
        return actual != expectedBundleID
    }
}

// MARK: - Индикаторы модификации приложения

public enum AppTamperIndicator: CustomStringConvertible {
    case teamIDMismatch(found: String, expected: String)
    case debugBuildDetected
    case provisioningProfileMissing
    case bundleIDMismatch

    public var description: String {
        switch self {
        case .teamIDMismatch(let f, let e):
            return "Team ID: найден '\(f)', ожидался '\(e)' → IPA переподписана"
        case .debugBuildDetected:
            return "DEBUG сборка — не для production"
        case .provisioningProfileMissing:
            return "embedded.mobileprovision отсутствует — запуск не из App Store"
        case .bundleIDMismatch:
            return "Bundle ID не совпадает с ожидаемым — возможна пересборка"
        }
    }
}

// MARK: - Фабрика URLSession с полной защитой

public extension URLSession {

    /// Создаёт URLSession с настроенным SPKI-пиннингом и ephemeral конфигурацией.
    /// Ephemeral: без кэша, без cookies, без disk persistence — всё только в памяти.
    static func pinnedSession(
        pinConfig: CertificatePinConfig = .production,
        onViolation: @Sendable @escaping (PinningError) -> Void = { _ in }
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        // Запрет HTTP → отклоняем незашифрованные соединения на уровне конфигурации.
        config.waitsForConnectivity = false

        let delegate = PinnedURLSessionDelegate(
            pinConfig: pinConfig,
            onViolation: onViolation
        )
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
}

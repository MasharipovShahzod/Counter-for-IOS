//
//  SecureWorkoutSession.swift
//  ExerciseTracker — Security Orchestrator
//
//  Главный оркестратор: объединяет все 4 слоя безопасности в единый
//  жизненный цикл защищённой тренировочной сессии.
//
//  Интеграция с ExerciseTrackerManager:
//
//    1. Создайте SecureWorkoutSession и присвойте его
//       ExerciseTrackerManager.secureSession.
//
//    2. Вызовите secureSession.startSession() перед началом захвата камеры.
//       Метод выполнит ECDH handshake с сервером и запустит периодическое
//       фоновое сканирование целостности.
//
//    3. ExerciseTrackerManager автоматически вызывает:
//         • secureSession.validateFrame(_:)   — перед каждым анализом кадра
//         • secureSession.registerRep(_:...)  — при каждом засчитанном повторе
//
//    4. В конце тренировки вызовите secureSession.finishSession() —
//       получите ServerReceipt с верифицированным числом повторений.
//
//  Обработка ошибок:
//
//    Если любой слой обнаруживает угрозу, SecuritySessionError прокидывается
//    через делегат. В мягком режиме (softMode = true) сессия продолжается
//    с предупреждением — используйте только для отладки.
//

import Foundation
import Vision

// MARK: - Ошибки защищённой сессии

public enum SecuritySessionError: LocalizedError {
    case spoofingDetected(LivenessViolation)
    case integrityCompromised([IntegrityThreat])
    case appTampered([AppTamperIndicator])
    case pinningViolation(PinningError)
    case cryptographicFailure(Error)
    case sessionNotStarted
    case sessionAlreadyFinished

    public var errorDescription: String? {
        switch self {
        case .spoofingDetected(let v):
            return "БЛОКИРОВКА [L1]: \(v)"
        case .integrityCompromised(let ts):
            return "БЛОКИРОВКА [L2]: \(ts.map(\.description).joined(separator: "; "))"
        case .appTampered(let is_):
            return "БЛОКИРОВКА [L4]: \(is_.map(\.description).joined(separator: "; "))"
        case .pinningViolation(let e):
            return "БЛОКИРОВКА [L4-TLS]: \(e.localizedDescription ?? "")"
        case .cryptographicFailure(let e):
            return "ОШИБКА [L3]: \(e.localizedDescription)"
        case .sessionNotStarted:
            return "Сессия не запущена — вызовите startSession() сначала"
        case .sessionAlreadyFinished:
            return "Сессия уже завершена"
        }
    }
}

// MARK: - Квитанция верификации от сервера

public struct ServerReceipt: Codable, Sendable {
    /// Верифицированное серверным алгоритмом число повторений.
    public let verifiedRepCount: Int
    /// Длительность тренировки в секундах по данным временных меток реестра.
    public let sessionDurationSeconds: Double
    /// Результат верификации.
    public let status: VerificationStatus
    /// Подпись сервера (HMAC-SHA256 от JSON-тела; ключ — серверный секрет).
    public let serverSignature: String
    /// UUID сессии (должен совпадать с отправленным).
    public let sessionID: String

    public enum VerificationStatus: String, Codable {
        case verified       = "VERIFIED"        // Все повторения прошли верификацию
        case partialCredit  = "PARTIAL_CREDIT"  // Часть повторений отклонена
        case rejected       = "REJECTED"        // Сессия отклонена целиком
        case replayAttack   = "REPLAY_ATTACK"   // Обнаружена повторная отправка payload
        case ledgerCorrupt  = "LEDGER_CORRUPT"  // Цепочка хэшей нарушена
    }
}

// MARK: - Конфигурация безопасности

public struct SecurityConfiguration: Sendable {
    /// Layer 1: обнаружение видео-спуфинга
    public var enableAntiSpoofing: Bool = true
    /// Layer 2: проверка джейлбрейка, Frida и сред выполнения
    public var enableProcessIntegrity: Bool = true
    /// Layer 3: криптографический реестр + шифрование
    public var enableStateLedger: Bool = true
    /// Layer 4: SSL-пиннинг при отправке реестра
    public var enableSSLPinning: Bool = true

    /// Конфигурация пиннинга сертификатов
    public var pinConfig: CertificatePinConfig = .production
    /// Ожидаемый Team ID подписи приложения
    public var expectedTeamID: String = "ВАШЕ_TEAM_ID"
    /// Ожидаемый Bundle Identifier
    public var expectedBundleID: String = "com.yourcompany.exercisetracker"

    /// URL инициализации сессии (ECDH handshake)
    public var sessionInitURL: URL = URL(string: "https://api.yourfitnessapp.com/v1/session/init")!
    /// URL верификации тренировки (отправка зашифрованного реестра)
    public var workoutVerifyURL: URL = URL(string: "https://api.yourfitnessapp.com/v1/workout/verify")!

    /// Интервал периодического сканирования L2 (секунды)
    public var integrityCheckInterval: TimeInterval = 45.0

    /// Мягкий режим: угрозы логируются, но не блокируют сессию. Только для QA/отладки.
    public var softMode: Bool = false

    public init() {}
}

// MARK: - Делегат защищённой сессии

public protocol SecureWorkoutSessionDelegate: AnyObject {
    /// Сессия заблокирована из-за угрозы безопасности. Остановите тренировку.
    func secureSession(_ session: SecureWorkoutSession, wasBlockedBy error: SecuritySessionError)

    /// Угроза обнаружена, но в мягком режиме сессия продолжается (предупреждение).
    func secureSession(_ session: SecureWorkoutSession, detectedThreat description: String)

    /// Тренировка успешно верифицирована сервером.
    func secureSession(_ session: SecureWorkoutSession, didReceiveReceipt receipt: ServerReceipt)
}

// MARK: - Главный оркестратор

public final class SecureWorkoutSession: @unchecked Sendable {

    // MARK: Конфигурация и делегат

    public weak var delegate: SecureWorkoutSessionDelegate?
    public let configuration: SecurityConfiguration

    // MARK: Слои безопасности

    private let spoofingDetector:   AntiSpoofingDetector
    private let integrityGuard:     ProcessIntegrityGuard
    private let stateLedger:        SecureStateLedger
    private let appChecker:         AppIntegrityChecker

    // MARK: Обфусцированный счётчик (Layer 2)

    /// Хранит число верифицированных повторений; защищён от GameGem/MemoryEditor.
    private let obfuscatedCounter = ObfuscatedCounter(initialValue: 0)

    /// Безопасное число повторений для отображения в UI.
    public var secureRepCount: Int { obfuscatedCounter.safeValue() ?? 0 }

    // MARK: Сетевой слой (Layer 4)

    private lazy var urlSession: URLSession = {
        if configuration.enableSSLPinning {
            return .pinnedSession(pinConfig: configuration.pinConfig) { [weak self] error in
                guard let self else { return }
                self.handleThreat(.pinningViolation(error))
            }
        }
        return URLSession(configuration: .ephemeral)
    }()

    // MARK: Управление жизненным циклом

    private var isActive   = false
    private var isBlocked  = false
    private var isFinished = false
    private var scanToken: ScanToken?

    // MARK: Инициализация

    public init(configuration: SecurityConfiguration = SecurityConfiguration()) {
        self.configuration = configuration
        spoofingDetector = AntiSpoofingDetector()
        integrityGuard   = ProcessIntegrityGuard()
        stateLedger      = SecureStateLedger()
        appChecker       = AppIntegrityChecker(
            expectedTeamID: configuration.expectedTeamID,
            expectedBundleID: configuration.expectedBundleID
        )
    }

    // MARK: — Жизненный цикл сессии

    /// Инициализирует защищённую сессию. Вызывайте перед первым кадром камеры.
    ///
    /// Выполняет последовательно:
    ///   1. L2: синхронное сканирование целостности среды
    ///   2. L4: проверка целостности IPA
    ///   3. L3: ECDH handshake с сервером (async)
    ///   4. L2: запуск периодического фонового сканирования
    ///
    /// - Throws: `SecuritySessionError` при обнаружении критической угрозы.
    public func startSession() async throws {
        precondition(!isActive, "SecureWorkoutSession: попытка запустить уже активную сессию")

        // Layer 2 — предстартовое сканирование
        if configuration.enableProcessIntegrity {
            let threats = integrityGuard.runFullScan()
            if !threats.isEmpty {
                throw SecuritySessionError.integrityCompromised(threats)
            }
        }

        // Layer 4 — проверка целостности IPA
        let tampers = appChecker.runChecks()
        if !tampers.isEmpty, !configuration.softMode {
            throw SecuritySessionError.appTampered(tampers)
        }

        // Layer 3 — ECDH handshake
        if configuration.enableStateLedger {
            try await performECDHHandshake()
        }

        // Layer 2 — периодическое сканирование каждые N секунд
        if configuration.enableProcessIntegrity {
            scanToken = integrityGuard.startPeriodicScan(
                interval: configuration.integrityCheckInterval
            ) { [weak self] threats in
                guard let self else { return }
                self.handleThreat(.integrityCompromised(threats))
            }
        }

        obfuscatedCounter.reset()
        spoofingDetector.reset()
        isActive   = true
        isBlocked  = false
        isFinished = false
    }

    /// Вызывается ExerciseTrackerManager для каждого Vision-наблюдения (Layer 1).
    ///
    /// - Returns: `true` если кадр прошёл проверку; `false` — кадр заблокирован.
    @discardableResult
    public func validateFrame(observation: VNHumanBodyPoseObservation) -> Bool {
        guard isActive, !isBlocked else { return false }
        guard configuration.enableAntiSpoofing else { return true }

        if let violation = spoofingDetector.evaluate(observation: observation) {
            handleThreat(.spoofingDetected(violation))
            return false
        }
        return true
    }

    /// Вызывается ExerciseTrackerManager при каждом засчитанном повторении.
    /// Атомарно инкрементирует обфусцированный счётчик и записывает в реестр.
    ///
    /// - Parameters:
    ///   - joints:          суставы текущего кадра
    ///   - peakDepthAngle:  угол первичного сустава в нижней точке (°)
    ///   - difficultyLevel: уровень сложности (0.0–1.0)
    public func registerRep(
        joints: BodyJoints,
        peakDepthAngle: Double,
        difficultyLevel: Double = 1.0
    ) {
        guard isActive, !isBlocked else { return }

        // Атомарный инкремент с ротацией XOR-ключей (Layer 2).
        obfuscatedCounter.increment()

        guard configuration.enableStateLedger else { return }

        // Карта уверенности Vision — прямое доказательство реального скелета.
        let confidences: [String: Float] = [
            "minConfidence": joints.minConfidence,
            "side": joints.side == .left ? 1.0 : 0.0
        ]

        stateLedger.recordRep(
            repIndex: obfuscatedCounter.value,
            jointConfidences: confidences,
            peakDepthAngle: peakDepthAngle,
            difficultyLevel: difficultyLevel
        )
    }

    /// Завершает тренировку и отправляет зашифрованный реестр на верификацию.
    ///
    /// - Returns: `ServerReceipt` с верифицированным числом повторений.
    /// - Throws: `SecuritySessionError` или `LedgerError`.
    @discardableResult
    public func finishSession() async throws -> ServerReceipt {
        guard isActive  else { throw SecuritySessionError.sessionNotStarted }
        guard !isFinished else { throw SecuritySessionError.sessionAlreadyFinished }

        isActive   = false
        isFinished = true
        scanToken  = nil  // Останавливаем периодическое сканирование

        guard configuration.enableStateLedger else {
            // Реестр отключён — возвращаем локальный счётчик без серверной верификации.
            return ServerReceipt(
                verifiedRepCount: secureRepCount,
                sessionDurationSeconds: 0,
                status: .verified,
                serverSignature: "LEDGER_DISABLED",
                sessionID: stateLedger.sessionID
            )
        }

        let payload = try stateLedger.exportEncryptedPayload()
        return try await submitWorkoutPayload(payload)
    }

    // MARK: — Обработка угроз

    private func handleThreat(_ error: SecuritySessionError) {
        if configuration.softMode {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.secureSession(self, detectedThreat: error.localizedDescription ?? "")
            }
        } else {
            isBlocked = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.secureSession(self, wasBlockedBy: error)
            }
        }
    }

    // MARK: — Сетевые вызовы (Layer 3 + 4)

    /// Выполняет ECDH handshake: отправляет публичный ключ клиента, получает серверный.
    private func performECDHHandshake() async throws {
        let body: [String: Any] = [
            "sessionID": stateLedger.sessionID,
            "clientPublicKey": stateLedger.clientPublicKeyBase64,
            "timestamp": Date().timeIntervalSince1970,
            "clientVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        ]

        var request = URLRequest(url: configuration.sessionInitURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LedgerError.keyNotEstablished
        }

        let handshake = try JSONDecoder().decode(HandshakeServerResponse.self, from: data)
        try stateLedger.establishSharedKey(serverPublicKeyBase64: handshake.serverPublicKey)
    }

    /// Отправляет зашифрованный payload на /v1/workout/verify.
    private func submitWorkoutPayload(_ payload: EncryptedWorkoutPayload) async throws -> ServerReceipt {
        var request = URLRequest(url: configuration.workoutVerifyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SecuritySessionError.sessionAlreadyFinished
        }

        let receipt = try JSONDecoder().decode(ServerReceipt.self, from: data)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.secureSession(self, didReceiveReceipt: receipt)
        }
        return receipt
    }
}

// MARK: - Внутренние модели сетевого уровня

private struct HandshakeServerResponse: Codable {
    let serverPublicKey: String  // base64 raw P-256 public key
    let sessionToken: String     // JWT или opaque token для следующих запросов
    let expiresAt: Double        // Unix timestamp истечения сессионного токена
}

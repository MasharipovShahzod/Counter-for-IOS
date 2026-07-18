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
    case sessionAlreadyStarted
    case sessionAlreadyFinished
    case verificationRequestFailed(statusCode: Int)

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
        case .sessionAlreadyStarted:
            return "Сессия уже запущена"
        case .sessionAlreadyFinished:
            return "Сессия уже завершена"
        case .verificationRequestFailed(let code):
            return "Сервер верификации ответил HTTP \(code)"
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

    /// НЕ lazy: `deinit` обязан её инвалидировать, а обращение к lazy-свойству
    /// из deinit создало бы сессию только ради того, чтобы тут же её закрыть.
    private var urlSession: URLSession!

    // MARK: Управление жизненным циклом

    /// Защищает флаги жизненного цикла ниже.
    ///
    /// Класс объявлен `@unchecked Sendable` — то есть мы РУЧАЕМСЯ за
    /// потокобезопасность вручную. До этого замка ручательство не было ничем
    /// обеспечено: `_isActive`/`_isBlocked` читаются из visionQueue
    /// (`validateFrame` на каждом кадре), пишутся из main (`startSession`,
    /// `finishSession`) и из очереди делегата URLSession (`handleThreat` при
    /// нарушении пиннинга).
    private let stateLock = NSLock()
    private var _isActive   = false
    private var _isBlocked  = false
    private var _isFinished = false
    private var _isStarting = false
    private var _scanToken: ScanToken?

    /// Одно взятие замка на оба флага: между отдельными чтениями `isActive` и
    /// `isBlocked` состояние успевало смениться.
    private var canProcess: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isActive && !_isBlocked
    }

    /// Сессия заблокирована сработавшим слоем защиты.
    public var isBlocked: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isBlocked
    }

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
        // Все хранимые свойства инициализированы → `self` уже можно захватывать.
        urlSession = Self.makeURLSession(configuration: configuration) { [weak self] error in
            self?.handleThreat(.pinningViolation(error))
        }
    }

    private static func makeURLSession(
        configuration: SecurityConfiguration,
        onViolation: @escaping @Sendable (PinningError) -> Void
    ) -> URLSession {
        guard configuration.enableSSLPinning else {
            return URLSession(configuration: .ephemeral)
        }
        return .pinnedSession(pinConfig: configuration.pinConfig, onViolation: onViolation)
    }

    deinit {
        // URLSession, созданная с делегатом, держит его СИЛЬНОЙ ссылкой до явной
        // инвалидации — это документированное поведение Apple, а не догадка. Без
        // этой строки и сессия, и `PinnedURLSessionDelegate` жили до конца
        // процесса: одна протекшая пара на каждую тренировку.
        urlSession?.finishTasksAndInvalidate()
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
        // Слот занимается атомарно. Раньше здесь стоял
        // `precondition(!isActive, ...)` — то есть ПАДЕНИЕ релизной сборки на
        // штатном пути жизненного цикла: SwiftUI волен вызвать `onAppear`
        // повторно (возврат на экран, пересборка иерархии), и это не ошибка
        // программиста, а обычное событие, которое надо просто отклонить.
        stateLock.lock()
        guard !_isActive, !_isStarting else {
            stateLock.unlock()
            throw SecuritySessionError.sessionAlreadyStarted
        }
        _isStarting = true
        stateLock.unlock()

        do {
            try await runStartupSequence()
        } catch {
            // Слот освобождается на любом сбое, иначе повторная попытка
            // (например, после восстановления сети) вечно упиралась бы в
            // `sessionAlreadyStarted`.
            stateLock.lock()
            _isStarting = false
            stateLock.unlock()
            throw error
        }

        obfuscatedCounter.reset()
        spoofingDetector.reset()

        stateLock.lock()
        _isStarting = false
        _isActive   = true
        _isBlocked  = false
        _isFinished = false
        stateLock.unlock()
    }

    /// Последовательность предстартовых проверок. Вынесена из `startSession`,
    /// чтобы освобождение слота при сбое было ровно в одном месте.
    private func runStartupSequence() async throws {
        // Layer 2 — предстартовое сканирование
        if configuration.enableProcessIntegrity {
            let threats = integrityGuard.runFullScan()
            if !threats.isEmpty, !configuration.softMode {
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
            let token = integrityGuard.startPeriodicScan(
                interval: configuration.integrityCheckInterval
            ) { [weak self] threats in
                guard let self else { return }
                self.handleThreat(.integrityCompromised(threats))
            }
            stateLock.lock()
            _scanToken = token
            stateLock.unlock()
        }
    }

    /// Вызывается ExerciseTrackerManager для каждого Vision-наблюдения (Layer 1).
    ///
    /// - Parameters:
    ///   - observation: наблюдение Vision для текущего кадра.
    ///   - exerciseKind: тип упражнения. Нужен слою 1: у `.hold` (планка)
    ///     неподвижность — это норма, а не признак видеозаписи.
    /// - Returns: `true` если кадр прошёл проверку; `false` — кадр заблокирован.
    @discardableResult
    public func validateFrame(observation: VNHumanBodyPoseObservation,
                              exerciseKind: ExerciseKind) -> Bool {
        guard canProcess else { return false }
        guard configuration.enableAntiSpoofing else { return true }

        if let violation = spoofingDetector.evaluate(observation: observation,
                                                     exerciseKind: exerciseKind) {
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
    /// NOT `public`: `BodyJoints` is an internal frame snapshot, and Swift
    /// rejects a public method whose parameter uses an internal type. The
    /// caller named above lives in this module, so internal is the access level
    /// this always needed — widening `BodyJoints` to public instead would
    /// export an implementation detail to satisfy a modifier nothing required.
    func registerRep(
        joints: BodyJoints,
        peakDepthAngle: Double,
        difficultyLevel: Double = 1.0
    ) {
        // Карта уверенности Vision — прямое доказательство реального скелета.
        registerRep(
            confidences: [
                "minConfidence": joints.minConfidence,
                "side": joints.side == .left ? 1.0 : 0.0
            ],
            peakDepthAngle: peakDepthAngle,
            difficultyLevel: difficultyLevel
        )
    }

    /// Вариант для упражнений без односторонней выборки суставов (подтягивания
    /// анализируются по обеим рукам сразу — `BilateralJoints`, у которых нет
    /// поля `side`).
    ///
    /// Формат записи реестра НЕ меняется: `jointConfidences` — свободный
    /// словарь `[String: Float]`, и бэкенд (`LedgerEntry.jointConfidences:
    /// Dict[str, float]`) не валидирует набор ключей. Хэш-цепочка и схема
    /// подписи остаются прежними.
    ///
    /// - Parameters:
    ///   - confidences:     карта уверенности Vision для записи в реестр
    ///   - peakDepthAngle:  угол первичного сустава в нижней точке (°)
    ///   - difficultyLevel: уровень сложности (0.0–1.0)
    public func registerRep(
        confidences: [String: Float],
        peakDepthAngle: Double,
        difficultyLevel: Double = 1.0
    ) {
        guard canProcess else { return }

        // Инкремент и чтение — ОДНА атомарная операция (Layer 2). Раньше это
        // были два отдельных вызова, `increment()` и геттер `value`, с окном
        // между ними: два засчитанных повтора подряд могли записать в реестр
        // один и тот же индекс, хотя вся хэш-цепочка построена на его
        // монотонности, и сервер прочитал бы это как повреждённый реестр.
        let index = obfuscatedCounter.incrementAndGet()

        guard configuration.enableStateLedger else { return }

        stateLedger.recordRep(
            repIndex: index,
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
        stateLock.lock()
        guard _isActive else {
            stateLock.unlock()
            throw SecuritySessionError.sessionNotStarted
        }
        guard !_isFinished else {
            stateLock.unlock()
            throw SecuritySessionError.sessionAlreadyFinished
        }
        _isActive   = false
        _isFinished = true
        _scanToken  = nil  // Останавливаем периодическое сканирование
        stateLock.unlock()

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
            return
        }

        // Блокируем ровно один раз: угроза может прилететь одновременно из
        // visionQueue (спуфинг), из очереди делегата URLSession (пиннинг) и с
        // main (периодическое сканирование). Без этой проверки делегат получил
        // бы несколько взаимоисключающих `wasBlockedBy` на одну блокировку.
        stateLock.lock()
        let alreadyBlocked = _isBlocked
        _isBlocked = true
        stateLock.unlock()
        guard !alreadyBlocked else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.secureSession(self, wasBlockedBy: error)
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

        // Раньше здесь бросался `sessionAlreadyFinished` — то есть отказ сервера
        // верификации (500, 401, что угодно) доезжал до пользователя под видом
        // «сессия уже завершена», и найти по этому сообщению настоящую причину
        // было невозможно.
        guard let http = response as? HTTPURLResponse else {
            throw SecuritySessionError.verificationRequestFailed(statusCode: -1)
        }
        guard http.statusCode == 200 else {
            throw SecuritySessionError.verificationRequestFailed(statusCode: http.statusCode)
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

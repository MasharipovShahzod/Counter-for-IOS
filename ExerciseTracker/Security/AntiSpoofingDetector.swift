//
//  AntiSpoofingDetector.swift
//  ExerciseTracker — Security Layer 1
//
//  СЛОЙ 1: Обнаружение живости и защита от инъекции видеозаписи.
//
//  Задача: доказать, что перед камерой находится живой человек в реальном времени,
//  а не воспроизводимое видео, изображение или виртуальный захват экрана.
//
//  Три независимых сигнала обнаружения:
//
//  [A] Дисперсия масштаба (Z-прокси)
//      Vision возвращает 2D координаты, но масштаб сегментов тела изменяется
//      по мере того, как человек двигается вперёд/назад в пространстве.
//      Нулевая дисперсия соотношений длин сегментов за 60 кадров означает
//      полное отсутствие 3D-движения — признак плоского видеофайла.
//
//  [B] Микротремор (шум датчика + естественная дрожь)
//      Реальная рука + матрица CMOS камеры всегда вносят субпиксельный шум
//      в координаты суставов. Программно-синтезированный поток математически
//      идеален: δ позиций между кадрами стремится к нулю.
//
//  [C] Обнаружение замороженного кадра
//      Если «подпись» набора точек не меняется N кадров подряд —
//      поток заморожен или зациклен.
//
//  Вызывается из visionQueue ExerciseTrackerManager — полностью thread-safe.
//

import Foundation
import Vision

// MARK: - Типы нарушений живости

/// Конкретный вид атаки или аномалии, обнаруженной детектором.
public enum LivenessViolation: CustomStringConvertible {

    /// Нулевая дисперсия Z-прокси — признак плоского видеофайла или виртуальной камеры.
    case flatVideoReplay(zVariance: Double)

    /// Координаты лишены естественного шума датчика — признак программной инъекции.
    case syntheticCoordinates(noiseLevel: Double)

    /// Один и тот же кадр повторяется без изменений — замороженный поток.
    case frozenFrame(duplicateCount: Int)

    public var description: String {
        switch self {
        case .flatVideoReplay(let v):
            return "Обнаружено видео-воспроизведение (дисперсия Z-прокси: \(String(format: "%.7f", v)) < порога)"
        case .syntheticCoordinates(let n):
            return "Синтетические координаты (средний шум: \(String(format: "%.8f", n)) < порога датчика)"
        case .frozenFrame(let c):
            return "Замороженный поток: \(c) идентичных кадров подряд"
        }
    }
}

// MARK: - Детектор живости

/// Анализирует каждый кадр Vision-наблюдения на предмет признаков спуфинга.
/// Не хранит ссылок на UIKit — пригоден для фонового потока.
public final class AntiSpoofingDetector {

    // MARK: — Настраиваемые пороги

    /// Размер скользящего окна в кадрах (при 30 fps ≈ 2 секунды истории).
    private let windowSize = 60

    /// Ниже этой дисперсии соотношений сегментов → нет 3D-движения → видеофайл.
    ///
    /// НЕ ОТКАЛИБРОВАНО НА УСТРОЙСТВЕ. Здесь раньше стоял комментарий
    /// «Откалибровано по 500 живым сессиям; значение < 4e-4 не встречается
    /// у людей» — таких замеров не было, и число подобрано умозрительно.
    /// Оставляем его как рабочую гипотезу, но без ложной уверенности:
    /// порог обязан быть перепроверен на реальных записях до релиза.
    private let zVarianceThreshold: Double = 4e-4

    /// Минимальное смещение опорного сустава за кадр (в нормированных единицах),
    /// при котором кадр вообще участвует в выборке Z-прокси.
    ///
    /// ЗАЧЕМ ЭТО НУЖНО
    /// ---------------
    /// Z-прокси измеряет дисперсию соотношения сегментов и трактует её отсутствие
    /// как «плоское видео». Но неподвижность — это суть планки и мёртвого виса:
    /// честный атлет, замерший на 2 секунды (= окно в 60 кадров), даёт нулевую
    /// дисперсию по определению и получал блокировку `flatVideoReplay`, после
    /// которой `isBlocked` навсегда обрывал сессию. Сигнал осмыслен только на
    /// движущемся теле, поэтому неподвижные кадры в окно больше не попадают:
    /// при удержании позы окно просто не наполняется и проверка молчит.
    ///
    /// ЗНАЧЕНИЕ — ОЦЕНОЧНОЕ. Собственный джиттер Vision у неподвижного человека
    /// ориентировочно ~1e-3, активное движение (плечо в отжимании) ~7e-3.
    /// Порог намеренно смещён к верхней границе: если он ЗАВЫШЕН, окно не
    /// наполняется и Z-прокси просто не срабатывает — сигнал слабеет, но ложных
    /// блокировок честного атлета нет. Если ЗАНИЖЕН — возвращаются именно они.
    /// Из двух ошибок выбрана молчаливая. Требует калибровки на устройстве.
    private let movementFloor: Double = 3e-3

    /// Средний пиксельный шум ниже этого → идеально стабильные координаты → инъекция.
    /// Настоящая рука даёт ≥ 5e-5 даже в режиме максимальной неподвижности.
    private let microTremorThreshold: Double = 5e-5

    /// Максимум допустимых подряд идущих дублирующих кадров до блокировки.
    private let maxFrozenFrames = 8

    // MARK: — Скользящие буферы

    /// История соотношений длин ключевых сегментов (шириноплечие / высота торса).
    private var segmentRatioHistory: [Double] = []

    /// История δX позиций плеча между последовательными кадрами.
    private var xNoiseHistory: [Double] = []

    /// История δY позиций плеча между последовательными кадрами.
    private var yNoiseHistory: [Double] = []

    /// Позиция плеча в предыдущем кадре для вычисления δ.
    private var prevShoulderPos: CGPoint?

    /// Счётчик подряд идущих одинаковых «подписей» кадра.
    private var frozenCount = 0

    /// FNV-1a хэш предыдущего кадра.
    private var prevFrameHash: UInt64 = 0

    // MARK: — Состояние

    /// true если последнее обнаруженное нарушение ещё не сброшено.
    public private(set) var isVideoSpoof = false

    /// Последнее зафиксированное нарушение.
    public private(set) var lastViolation: LivenessViolation?

    public init() {}

    // MARK: — Публичный API

    /// Обрабатывает одно Vision-наблюдение. Вызывать из visionQueue.
    ///
    /// - Parameters:
    ///   - observation: наблюдение Vision для текущего кадра.
    ///   - exerciseKind: тип упражнения. Для `.hold` сигнал [A] не применяется
    ///     вовсе: у планки неподвижность — это и есть упражнение, поэтому
    ///     «нет движения в глубину» там не улика, а описание правильной формы.
    /// - Returns: `LivenessViolation` если кадр подозрительный, иначе `nil`.
    @discardableResult
    public func evaluate(observation: VNHumanBodyPoseObservation,
                         exerciseKind: ExerciseKind = .reps) -> LivenessViolation? {
        guard let allPoints = try? observation.recognizedPoints(.all) else { return nil }

        // ── [C] Обнаружение замороженного кадра ────────────────────────────
        let signature = frameSignature(allPoints)
        if signature == prevFrameHash, prevFrameHash != 0 {
            frozenCount += 1
            if frozenCount >= maxFrozenFrames {
                return flag(.frozenFrame(duplicateCount: frozenCount))
            }
        } else {
            frozenCount = 0
        }
        prevFrameHash = signature

        // Смещение опорного сустава за кадр. Считается ДО [A], потому что
        // Z-прокси теперь обязан знать, двигался ли атлет вообще.
        let motion = updateMotion(allPoints)

        // ── [A] Дисперсия масштаба (Z-прокси) ──────────────────────────────
        // Только для упражнений «на повторения». Планка неподвижна по своей
        // сути — там этот сигнал не просто бесполезен, он систематически ложен.
        if exerciseKind == .reps,
           let violation = evaluateZProxy(allPoints, motion: motion) { return violation }

        // ── [B] Анализ микротремора ─────────────────────────────────────────
        if let violation = evaluateMicroTremor() { return violation }

        return nil
    }

    /// Сбрасывает всё внутреннее состояние. Вызывать при старте новой тренировки.
    public func reset() {
        segmentRatioHistory.removeAll()
        xNoiseHistory.removeAll()
        yNoiseHistory.removeAll()
        prevShoulderPos = nil
        frozenCount = 0
        prevFrameHash = 0
        isVideoSpoof = false
        lastViolation = nil
    }

    // MARK: — Z-прокси (сигнал A)

    private func evaluateZProxy(
        _ pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        motion: Double?
    ) -> LivenessViolation? {

        // Кадры без реального движения в выборку не берём — см. `movementFloor`.
        // Иначе честная планка (2 секунды неподвижности) даёт нулевую дисперсию
        // и блокируется как «плоское видео».
        guard let motion = motion, motion >= movementFloor else { return nil }

        // Два измерения: ширина плеч и высота торса (левая сторона).
        // Их соотношение меняется при движении в глубину (перспектива).
        guard
            let ls = pts[.leftShoulder],  let rs = pts[.rightShoulder],
            let lh = pts[.leftHip],       let lk = pts[.leftKnee],
            ls.confidence > 0.4, rs.confidence > 0.4,
            lh.confidence > 0.4, lk.confidence > 0.4
        else { return nil }

        let shoulderWidth = distance(ls.location, rs.location)
        let torsoHeight   = distance(ls.location, lh.location)
        guard torsoHeight > 1e-6 else { return nil }

        let ratio = Double(shoulderWidth / torsoHeight)
        push(&segmentRatioHistory, value: ratio)

        guard segmentRatioHistory.count >= windowSize else { return nil }

        let variance = sampleVariance(segmentRatioHistory)
        if variance < zVarianceThreshold {
            return flag(.flatVideoReplay(zVariance: variance))
        }
        return nil
    }

    // MARK: — Микротремор (сигнал B)

    /// Обновляет δ-буферы по опорному суставу и возвращает смещение за кадр.
    ///
    /// Вынесено из `evaluateMicroTremor`, потому что величина смещения нужна
    /// ещё и сигналу [A] — решить, движется ли атлет вообще. Возвращает `nil`,
    /// если опорный сустав в этом кадре недостаточно уверенный или это первый
    /// кадр (сравнивать не с чем).
    private func updateMotion(
        _ pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> Double? {

        // Используем левое плечо как опорную точку для δ-измерений.
        guard let ls = pts[.leftShoulder], ls.confidence > 0.5 else { return nil }
        let pos = ls.location
        defer { prevShoulderPos = pos }

        guard let prev = prevShoulderPos else { return nil }
        let dx = abs(Double(pos.x) - Double(prev.x))
        let dy = abs(Double(pos.y) - Double(prev.y))
        push(&xNoiseHistory, value: dx)
        push(&yNoiseHistory, value: dy)
        return (dx * dx + dy * dy).squareRoot()
    }

    private func evaluateMicroTremor() -> LivenessViolation? {
        guard xNoiseHistory.count >= windowSize else { return nil }

        let avgNoise = (mean(xNoiseHistory) + mean(yNoiseHistory)) / 2.0
        if avgNoise < microTremorThreshold {
            return flag(.syntheticCoordinates(noiseLevel: avgNoise))
        }
        return nil
    }

    // MARK: — Вспомогательные функции

    /// FNV-1a подпись кадра: квантизованные координаты ключевых суставов.
    private func frameSignature(
        _ pts: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]
    ) -> UInt64 {
        let joints: [VNHumanBodyPoseObservation.JointName] = [
            .leftShoulder, .rightShoulder,
            .leftHip,      .rightHip,
            .leftKnee,     .rightKnee
        ]
        var h: UInt64 = 14_695_981_039_346_656_037
        for j in joints {
            guard let p = pts[j] else { continue }
            // Квантизация до 1/10 000 пикселя — субпиксельный шум не влияет на подпись.
            let qx = UInt64(bitPattern: Int64(p.location.x * 10_000))
            let qy = UInt64(bitPattern: Int64(p.location.y * 10_000))
            h ^= qx; h = h &* 1_099_511_628_211
            h ^= qy; h = h &* 1_099_511_628_211
        }
        return h
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x; let dy = a.y - b.y
        return (dx*dx + dy*dy).squareRoot()
    }

    /// Добавляет значение в скользящий буфер; вытесняет самые старые записи.
    private func push(_ buf: inout [Double], value: Double) {
        buf.append(value)
        if buf.count > windowSize { buf.removeFirst() }
    }

    private func mean(_ xs: [Double]) -> Double {
        xs.reduce(0, +) / Double(xs.count)
    }

    /// Несмещённая выборочная дисперсия.
    private func sampleVariance(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = mean(xs)
        let ss = xs.reduce(0.0) { $0 + ($1 - m) * ($1 - m) }
        return ss / Double(xs.count - 1)
    }

    /// Устанавливает флаг спуфинга и сохраняет последнее нарушение.
    @discardableResult
    private func flag(_ v: LivenessViolation) -> LivenessViolation {
        isVideoSpoof = true
        lastViolation = v
        return v
    }
}

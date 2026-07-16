//
//  ProcessIntegrityGuard.swift
//  ExerciseTracker — Security Layer 2
//
//  СЛОЙ 2: Целостность процесса и аттестация среды выполнения.
//
//  Четыре подсистемы защиты:
//
//  [A] Обнаружение файлов джейлбрейка
//      Проверяет существование характерных путей Cydia/Substrate через
//      Foundation и напрямую через fopen() — для обхода возможных хуков
//      на уровне Foundation.
//
//  [B] Проверка побега из песочницы
//      Пробует записать файл в /private/var — запрещено в нормальной среде.
//
//  [C] Доступность fork()
//      На нетронутом устройстве fork() завершается с EPERM. Если он работает —
//      ядро пропатчено.
//
//  [D] Проверка загруженных dylib
//      Сканирует все образы процесса через _dyld_get_image_name() на предмет
//      известных фреймворков инструментации: Frida Gadget, Cycript, Substitute,
//      MobileSubstrate, Flex и т.д.
//
//  [E] Проверка наличия отладчика
//      Анализирует флаг P_TRACED через sysctl(KERN_PROC_PID).
//
//  ObfuscatedCounter:
//      Хранит счётчик повторений в форме `значение XOR соль XOR канарейка`,
//      где и соль, и канарейка — криптографически случайные UInt64,
//      перегенерируемые после каждого доступа. Делает «заморозку» числа
//      в GameGem/Flex невозможной — следующая запись всегда по другому адресу.
//

import Foundation
import Darwin

// MARK: - Типы угроз целостности

public enum IntegrityThreat: CustomStringConvertible {
    case jailbreakFilesFound([String])
    case sandboxEscapeDetected
    case forkAvailable
    case suspiciousDylibLoaded(name: String)
    case debuggerAttached

    public var description: String {
        switch self {
        case .jailbreakFilesFound(let fs):
            return "Файлы джейлбрейка: \(fs.joined(separator: ", "))"
        case .sandboxEscapeDetected:
            return "Запись вне песочницы — устройство взломано"
        case .forkAvailable:
            return "fork() доступен — ядро iOS пропатчено"
        case .suspiciousDylibLoaded(let n):
            return "Подозрительная dylib: \(n)"
        case .debuggerAttached:
            return "К процессу подключён отладчик (P_TRACED)"
        }
    }
}

// MARK: - Обфусцированный счётчик (защита от сканеров памяти)

/// Счётчик повторений, устойчивый к GameGem, iGameGuardian и другим редакторам памяти.
///
/// Инвариант: `maskedValue == realValue ^ salt ^ canary` всегда.
/// После каждого чтения/записи оба ключа заменяются новыми случайными значениями,
/// поэтому адрес «настоящего числа» в памяти постоянно мигрирует.
///
/// ПОТОКОБЕЗОПАСНОСТЬ
/// ------------------
/// Все операции проходят через `lock`. Раньше замка не было вовсе, хотя
/// комментарий обещал атомарность: любые два потока, одновременно оказавшиеся
/// внутри ротации ключей, ломали инвариант выше и превращали счётчик в мусор.
/// Самое неприятное в этом — не потерянный инкремент, а то, что `safeValue()`
/// затем опознаёт разрушенное состояние как «вмешался редактор памяти» и
/// обвиняет честного пользователя в читерстве по следам нашей же гонки.
public final class ObfuscatedCounter {

    // Все три поля живут рядом в памяти, но их XOR — это случайный мусор для сканера.
    private var maskedValue: UInt64
    private var salt:        UInt64
    private var canary:      UInt64

    private let lock = NSLock()

    public init(initialValue: Int = 0) {
        salt   = Self.randomUInt64()
        canary = Self.randomUInt64()
        maskedValue = UInt64(bitPattern: Int64(initialValue)) ^ salt ^ canary
    }

    // MARK: Доступ к значению

    /// Декодирует и возвращает счётчик, ПОПУТНО ротируя ключи.
    ///
    /// Это метод, а не свойство, и назван `consume` намеренно: операция мутирует
    /// объект. Раньше здесь стояло `public var value`, и вызов вида
    /// `ledger.record(repIndex: counter.value)` читался как безобидное чтение,
    /// хотя перезаписывал `salt`, `canary` и `maskedValue`. Скрытая мутация за
    /// геттером — ровно та ошибка, которую невозможно заметить на месте вызова.
    public func consumeValue() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let raw = maskedValue ^ salt ^ canary
        rotateMask(preserving: raw)
        return Int(truncatingIfNeeded: raw)
    }

    /// Устанавливает новое значение и генерирует свежую пару ключей.
    public func setValue(_ newValue: Int) {
        lock.lock()
        defer { lock.unlock() }
        salt   = Self.randomUInt64()
        canary = Self.randomUInt64()
        maskedValue = UInt64(bitPattern: Int64(newValue)) ^ salt ^ canary
    }

    /// Атомарно инкрементирует, ротируя ключи до и после операции.
    public func increment() {
        lock.lock()
        defer { lock.unlock() }
        let current = maskedValue ^ salt ^ canary
        salt   = Self.randomUInt64()
        canary = Self.randomUInt64()
        maskedValue = (current &+ 1) ^ salt ^ canary
    }

    /// Инкрементирует и возвращает НОВОЕ значение одной атомарной операцией.
    ///
    /// Существует потому, что `increment()` + `consumeValue()` — это две
    /// операции с окном между ними: два засчитанных повтора подряд могли
    /// записать в реестр один и тот же индекс, а хэш-цепочка построена на
    /// монотонности индекса.
    public func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        let next = (maskedValue ^ salt ^ canary) &+ 1
        rotateMask(preserving: next)
        return Int(truncatingIfNeeded: next)
    }

    public func reset() { setValue(0) }

    // MARK: Проверка на внешнее вмешательство

    /// Декодирует счётчик и проверяет, что результат находится в допустимом диапазоне.
    /// Возвращает `nil` если ключи были обнулены или значение стало абсурдным —
    /// верный признак того, что редактор памяти вмешался в структуру.
    ///
    /// В отличие от `consumeValue()` НЕ мутирует состояние — это честное чтение,
    /// пригодное для отрисовки счётчика в UI на каждом кадре.
    public func safeValue() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard salt != 0, canary != 0 else { return nil }
        let raw = maskedValue ^ salt ^ canary
        let decoded = Int(truncatingIfNeeded: raw)
        // Счётчик повторений за одну тренировку не может превысить 100 000.
        guard decoded >= 0, decoded < 100_000 else { return nil }
        return decoded
    }

    // MARK: Вспомогательные методы

    private func rotateMask(preserving value: UInt64) {
        salt   = Self.randomUInt64()
        canary = Self.randomUInt64()
        maskedValue = value ^ salt ^ canary
    }

    /// Криптографически случайный UInt64 через arc4random_buf.
    private static func randomUInt64() -> UInt64 {
        var result: UInt64 = 0
        withUnsafeMutableBytes(of: &result) { arc4random_buf($0.baseAddress!, $0.count) }
        // Гарантируем ненулевое значение (нулевая соль = отсутствие защиты).
        return result == 0 ? 0xDEAD_CAFE_BEEF_1337 : result
    }
}

// MARK: - Страж целостности процесса

public final class ProcessIntegrityGuard {

    // MARK: Конфигурация

    /// Характерные пути джейлбрейк-инструментов. Список формируется по реальным
    /// популярным утилитам; добавляйте новые по мере появления новых джейлбрейков.
    private let jailbreakPaths: [String] = [
        "/Applications/Cydia.app",
        "/Applications/Sileo.app",
        "/Applications/Zebra.app",
        "/Applications/Installer.app",
        "/Library/MobileSubstrate/MobileSubstrate.dylib",
        "/Library/MobileSubstrate/DynamicLibraries",
        "/private/var/lib/apt",
        "/private/var/lib/cydia",
        "/private/var/stash",
        "/private/var/tmp/cydia.log",
        "/usr/bin/sshd",
        "/usr/libexec/sftp-server",
        "/usr/sbin/sshd",
        "/etc/apt",
        "/bin/bash",
        "/bin/sh",
        "/usr/bin/ssh",
        "/var/checkra1n.dmg",
        "/usr/lib/TweakInject",
    ]

    /// Подстроки в именах образов, характерные для инструментов инструментации.
    private let suspiciousDylibSubstrings: [String] = [
        "frida",            // Frida — наиболее популярный инструмент хуков
        "gadget",           // Frida Gadget (встраиваемая версия)
        "cynject",          // Cycript инжектор
        "cycript",
        "libsubstrate",     // MobileSubstrate
        "mobilesubstrate",
        "substitute",       // libsubstitute (альтернатива Substrate)
        "libhooker",        // libhooker (современный пуллинг хуков)
        "rviconnectsupport",// Инструмент отладки Apple (не должен быть в production)
        "flexdylib",        // Flex patches
        "a-bypass",         // AntiJailbreakBypass
        "liberty",          // Liberty Lite
        "tsprotector",
        "xcon",             // xCon bypass
        "shadowbreaker",
    ]

    public init() {}

    // MARK: Публичный API

    /// Запускает полное сканирование. Блокирующий вызов — используйте фоновую очередь.
    /// Возвращает все обнаруженные угрозы (пустой массив → среда чистая).
    public func runFullScan() -> [IntegrityThreat] {
        var threats: [IntegrityThreat] = []

        if let t = checkJailbreakFiles()  { threats.append(t) }
        if checkSandboxEscape()           { threats.append(.sandboxEscapeDetected) }
        if checkForkAvailability()        { threats.append(.forkAvailable) }
        threats.append(contentsOf: checkLoadedDylibs())
        if checkDebuggerAttached()        { threats.append(.debuggerAttached) }

        return threats
    }

    /// Запускает периодическое фоновое сканирование.
    /// - Parameter interval: интервал между проверками в секундах
    /// - Parameter handler: вызывается на main-очереди при обнаружении угроз
    /// - Returns: токен отмены; удерживайте его — освобождение остановит таймер
    @discardableResult
    public func startPeriodicScan(
        interval: TimeInterval = 45.0,
        handler: @escaping ([IntegrityThreat]) -> Void
    ) -> ScanToken {
        let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(5))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let threats = self.runFullScan()
            guard !threats.isEmpty else { return }
            DispatchQueue.main.async { handler(threats) }
        }
        source.resume()
        return ScanToken(source)
    }

    // MARK: — [A] Проверка файлов джейлбрейка

    private func checkJailbreakFiles() -> IntegrityThreat? {
        var found: [String] = []
        let fm = FileManager.default

        for path in jailbreakPaths {
            // Двойная проверка: Foundation и прямой вызов fopen.
            // Некоторые твики перехватывают FileManager.fileExists, но не fopen.
            if fm.fileExists(atPath: path) {
                found.append(path)
                continue
            }
            if let fp = fopen(path, "r") { fclose(fp); found.append(path) }
        }

        return found.isEmpty ? nil : .jailbreakFilesFound(found)
    }

    // MARK: — [B] Проверка побега из песочницы

    private func checkSandboxEscape() -> Bool {
        // Уникальное имя файла предотвращает конфликты при параллельных запусках.
        let probeFile = "/private/var/mobile/.\(UUID().uuidString)"
        do {
            try "probe".write(toFile: probeFile, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: probeFile)
            return true  // Запись удалась → sandbox прорван
        } catch {
            return false // Нормальное поведение в нетронутой среде
        }
    }

    // MARK: — [C] Доступность fork()

    private func checkForkAvailability() -> Bool {
        #if targetEnvironment(simulator)
        // В симуляторе fork() допустим — это macOS процесс.
        return false
        #else
        let pid = fork()
        if pid == 0 {
            // Мы в дочернем процессе — немедленно завершаемся без cleanup.
            _exit(0)
        }
        // pid > 0 → fork() сработал → ядро пропатчено
        // pid < 0 → EPERM/ENOSYS → нормальное поведение iOS
        return pid > 0
        #endif
    }

    // MARK: — [D] Проверка загруженных dylib

    private func checkLoadedDylibs() -> [IntegrityThreat] {
        var threats: [IntegrityThreat] = []
        let count = _dyld_image_count()

        for i in UInt32(0)..<count {
            guard let rawName = _dyld_get_image_name(i) else { continue }
            let name = String(cString: rawName).lowercased()

            for pattern in suspiciousDylibSubstrings {
                if name.contains(pattern) {
                    threats.append(.suspiciousDylibLoaded(name: String(cString: rawName)))
                    break
                }
            }
        }
        return threats
    }

    // MARK: — [E] Обнаружение отладчика через sysctl

    private func checkDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let rc = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard rc == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}

// MARK: - Токен отмены периодического сканирования

/// Удерживайте этот объект пока сканирование необходимо. Освобождение = остановка.
public final class ScanToken {
    private let source: DispatchSourceTimer
    init(_ source: DispatchSourceTimer) { self.source = source }
    deinit { source.cancel() }
}

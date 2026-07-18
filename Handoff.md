# Handoff.md — Техническая документация для разработчиков

> Архитектурный blueprint проекта **Counter-for-IOS (FitnessTracker)**.  
> Предназначен для передачи проекта другому разработчику или для синхронизации с бэкенд-командой.  
> Все разделы написаны на русском языке.

---

## 📋 Содержание

1. [Слой данных (Data Layer)](#1-слой-данных-data-layer)
2. [Конечный автомат повторений](#2-конечный-автомат-повторений)
3. [Тригонометрические векторы и валидация позы](#3-тригонометрические-векторы-и-валидация-позы)
4. [Криптографический пакет (L3)](#4-криптографический-пакет-l3)
5. [Контракт API сервера верификации](#5-контракт-api-сервера-верификации)
6. [Архитектура безопасности (все 4 уровня)](#6-архитектура-безопасности-все-4-уровня)
7. [Ключевые инварианты системы](#7-ключевые-инварианты-системы)

---

## 1. Слой данных (Data Layer)

### 1.1 Основные типы данных

#### `BodyJoints` — снимок суставов одного кадра

```
BodyJoints {
    shoulder : CGPoint   // Нормализованные координаты Vision [0,1] × [0,1]
    elbow    : CGPoint   // Система координат Vision: начало — нижний левый угол
    wrist    : CGPoint   // Ось Y направлена ВВЕРХ (противоположно UIKit)
    hip      : CGPoint
    knee     : CGPoint
    ankle    : CGPoint
    minConfidence : Float   // Минимальная уверенность среди обязательных суставов
    side          : .left | .right
}
```

> **Важно:** Алгоритмы работают в пространстве координат Vision (Y-up). Для отрисовки скелета на экране необходимо применить преобразование `y_screen = 1 - y_vision` перед масштабированием.

#### `LedgerEntry` — атомарная запись о повторении

```
LedgerEntry {
    repIndex          : Int       // Порядковый номер, начиная с 1
    timestampMicros   : Int64     // Unix timestamp × 1_000_000 (микросекунды)
    difficultyLevel   : Double    // 0.0 — лёгкий, 1.0 — максимальный
    jointConfidences  : [String: Float]   // Ключи: "minConfidence", "side"
    peakDepthAngle    : Double    // Угол первичного сустава в нижней точке (°)
    previousEntryHash : String    // SHA-256 (hex) предыдущей LedgerEntry
    sessionID         : String    // UUID сессии
}
```

Поле `previousEntryHash` связывает записи в **tamper-evident цепочку**: изменение любой записи разрывает цепочку и обнаруживается сервером.

#### `ExerciseThresholds` — пороговые значения упражнения

```
ExerciseThresholds {
    descentStartAngle : CGFloat   // Отжимания: 150°, Приседания: 160°
    depthAngle        : CGFloat   // Целевая глубина: 90° для обоих упражнений
    lockoutAngle      : CGFloat   // Отжимания: 165°, Приседания: 170°
    reversalMargin    : CGFloat   // Гистерезис разворота: 12° (подавление дрожания)
    supportAngleMin   : CGFloat   // Отжимания: 155° (плечо–бедро–колено)
    torsoLeanMax      : CGFloat   // Приседания: 55° от вертикали
    maxTorsoPitch     : CGFloat   // Отжимания: 30° от горизонта
}
```

---

## 2. Конечный автомат повторений

### 2.1 Граф переходов состояний

```
                    ┌─────────────────────────────────┐
                    │              ready               │◄──────────────┐
                    └─────────────────┬───────────────┘               │
                                      │ угол < descentStartAngle      │
                                      ▼                               │
                    ┌─────────────────────────────────┐               │
                    │           descending             │               │
                    └─────────────────┬───────────────┘               │
                                      │ угол ≤ depthAngle             │ угол ≥ lockoutAngle
                                      ▼                    ✓ reachedDepth
                    ┌─────────────────────────────────┐               │
                    │            atBottom              │               │
                    └─────────────────┬───────────────┘               │
                                      │ угол > min + reversalMargin   │
                                      ▼                               │
                    ┌─────────────────────────────────┐               │
                    │            ascending             ├───────────────┘
                    └─────────────────────────────────┘
                              │           │
            ошибка позы       │           │ ошибка глубины / формы
                    ▼                     ▼
    ┌──────────────────────┐   ┌───────────────────────┐
    │   invalidPosition    │   │  invalidRepDetected   │
    │ (позиция не засчитан)│   │ (повтор не засчитан)  │
    └──────────────────────┘   └───────────────────────┘
```

### 2.2 Условия засчёта повторения

Повторение **засчитывается** (`repCompleted`) только при одновременном выполнении всех условий:

1. `reachedDepth == true` — угол первичного сустава достиг `depthAngle`
2. `errorEmitted == false` — за время попытки не было ни одной ошибки формы
3. `угол ≥ lockoutAngle` — выход из попытки в верхнее положение

### 2.3 Глобальный античит-шлюз (только для отжиманий)

`PushUpPostureValidator` проверяется **каждый кадр до любой логики угла локтя**:

```
PushUpPostureValidator.isValid(shoulder, hip, knee):
  → torsoPitch(shoulder, hip) ≤ maxTorsoPitch       (30°)  // Тело параллельно полу
  → angle(shoulder, hip, knee) ≥ supportAngleMin    (155°) // Нет провисания/выгиба
```

Если шлюз не пройден → `errorEmitted = true`, переход в `invalidPosition`, автомат **заморожен** до исправления позы.

---

## 3. Тригонометрические векторы и валидация позы

### 3.1 Угол в суставе `angle(a, b, c)`

Вычисляет внутренний угол в вершине `b` между сегментами `b→a` и `b→c`:

```
v1 = a - b
v2 = c - b
dot    = v1.x·v2.x + v1.y·v2.y
|v1|   = √(v1.x² + v1.y²)
|v2|   = √(v2.x² + v2.y²)
angle  = arccos(dot / (|v1|·|v2|)) × (180/π)
```

Результат: `[0°, 180°]`. Используется для локтя (отжимания) и колена (приседания).

### 3.2 Уклон торса `torsoPitch(shoulder, hip)` — **atan2-валидация**

```
dx     = hip.x - shoulder.x
dy     = hip.y - shoulder.y        // Vision Y-up: dy > 0 если бедро ВЫШЕ плеча
degrees = |atan2(dy, dx)| × (180/π)  // Абсолютный угол: [0°, 180°]
pitch  = degrees > 90 ? (180 - degrees) : degrees  // Свёртка в [0°, 90°]
```

**Интерпретация значений `pitch`:**

| pitch | Положение тела |
|---|---|
| ~0° | Тело горизонтально — идеальная стойка отжимания |
| 15–30° | Допустимый наклон |
| > 30° | Пикирование/стойка — повтор не засчитывается |
| ~90° | Тело вертикально — человек стоит |

**Почему atan2, а не простой arccos:**  
`atan2(dy, dx)` возвращает угол с учётом знаков обеих компонент, что корректно обрабатывает все четыре квадранта плоскости. Абсолютное значение и свёртка устраняют зависимость от ориентации камеры (лежит человек головой влево или вправо).

### 3.3 Наклон торса `angleFromVertical(a, b)` (приседания)

```
dx = b.x - a.x
dy = b.y - a.y
cosine = |dy| / √(dx² + dy²)   // Косинус угла к вертикальной оси
lean   = arccos(cosine) × (180/π)
```

Порог: `lean > torsoLeanMax (55°)` → «Держите грудь выше!»

### 3.4 Выбор стороны тела

```
Для каждой стороны (left, right):
    joints[] = [shoulder, elbow, wrist, hip, knee, ankle]
    required = фильтр по упражнению
    minConf  = min(required[].confidence)
    valid    = minConf ≥ minimumJointConfidence

Выбрать сторону с наибольшим minConf из валидных.
```

---

## 4. Криптографический пакет (L3)

### 4.1 Схема установки сессионного ключа (ECDH)

```
Клиент                                     Сервер
──────                                     ──────
P-256 PrivKey (эфемерный) ──clientPubKey──►  P-256 PrivKey (эфемерный)
                           ◄─serverPubKey──  

Обе стороны независимо вычисляют:
  sharedSecret = ECDH(myPrivKey, theirPubKey)

HKDF-SHA256:
  key = HKDF(
    ikm   = sharedSecret,
    salt  = b"workout-ledger-salt-v1",
    info  = b"ExerciseTracker-v1-AES256GCM-{sessionID}",
    len   = 32   // 256 бит
  )
```

Ключ существует только в оперативной памяти обеих сторон и никогда не передаётся по сети.

### 4.2 Шифрование реестра AES-256-GCM

```
Вход:
  plaintext = JSON(LedgerEntry[])   // sorted keys — детерминированный порядок
  key       = 256-битный AES ключ (из HKDF)

Шифрование (CryptoKit AES.GCM.seal):
  nonce     = случайный 96-битный (12 байт)
  sealedBox = AES-256-GCM(plaintext, key, nonce)

combined layout (SealedBox.combined):
  [12 bytes nonce] [N bytes ciphertext] [16 bytes GCM auth tag]

Payload:
  ciphertext = combined[12 : -16]      (base64)
  nonce      = combined[:12]           (base64)
  authTag    = combined[-16:]          (base64)
```

### 4.3 Цепочка хэшей реестра

```
entry_1.previousEntryHash = "GENESIS"
entry_2.previousEntryHash = SHA256(JSON(entry_1))
entry_3.previousEntryHash = SHA256(JSON(entry_2))
...
entry_N.previousEntryHash = SHA256(JSON(entry_{N-1}))
```

Сервер проверяет: `expectedPrev = "GENESIS"`, затем для каждой записи вычисляет хэш и сравнивает с `nextEntry.previousEntryHash`.

### 4.4 `ObfuscatedCounter` — XOR-обфускация в памяти

```
Инициализация:
  salt   = arc4random_buf(8 байт)   // UInt64
  canary = arc4random_buf(8 байт)   // UInt64
  maskedValue = 0 XOR salt XOR canary

Запись N:
  maskedValue = N XOR salt XOR canary

Чтение (с ротацией ключей):
  result = maskedValue XOR salt XOR canary   // восстанавливаем N
  salt   = arc4random_buf(8 байт)            // новая соль
  canary = arc4random_buf(8 байт)            // новая канарейка
  maskedValue = result XOR salt XOR canary   // перешифровываем

Проверка на вмешательство (safeValue()):
  salt == 0 || canary == 0  →  вмешательство (nil)
  result < 0 || result ≥ 100_000  →  вмешательство (nil)
```

---

## 5. Контракт API сервера верификации

### Базовый URL

```
Production : https://api.yourfitnessapp.com
Staging    : https://staging-api.yourfitnessapp.com
```

---

### 5.1 `POST /v1/session/init` — ECDH Handshake

**Запрос:**

```json
{
  "sessionID"     : "550e8400-e29b-41d4-a716-446655440000",
  "clientPublicKey": "<base64-raw-P256-pubkey-65-bytes>",
  "timestamp"     : 1719744000.123,
  "clientVersion" : "1.0.0"
}
```

| Поле | Тип | Описание |
|---|---|---|
| `sessionID` | `string (UUID v4)` | Уникальный идентификатор тренировочной сессии |
| `clientPublicKey` | `string (base64)` | Raw representation P-256 публичного ключа (65 байт: `04‖X‖Y`) |
| `timestamp` | `float (Unix)` | Временна́я метка запроса; сервер отвергает при drift > 60 сек |
| `clientVersion` | `string` | Версия приложения из `CFBundleShortVersionString` |

**Ответ `200 OK`:**

```json
{
  "serverPublicKey" : "<base64-raw-P256-pubkey-65-bytes>",
  "sessionToken"    : "eyJhbGciOiJIUzI1NiJ9...",
  "expiresAt"       : 1719747600.0
}
```

| Поле | Описание |
|---|---|
| `serverPublicKey` | Raw P-256 публичный ключ сервера (base64). Клиент завершает ECDH. |
| `sessionToken` | Токен для последующих запросов (передаётся в заголовке `Authorization`) |
| `expiresAt` | Unix timestamp истечения сессии |

**Ошибки:**

| Код | Причина |
|---|---|
| `400` | Некорректный публичный ключ или временна́я метка вне окна ±60 сек |
| `429` | Превышение лимита запросов |

---

### 5.2 `POST /v1/workout/verify` — Верификация тренировки

**Заголовки:**

```
Content-Type  : application/json
Authorization : Bearer <sessionToken>
```

**Запрос (`EncryptedWorkoutPayload`):**

```json
{
  "ciphertext"      : "<base64 AES-GCM ciphertext>",
  "nonce"           : "<base64 12-byte nonce>",
  "authTag"         : "<base64 16-byte GCM tag>",
  "clientPublicKey" : "<base64 P-256 pubkey>",
  "sessionID"       : "550e8400-e29b-41d4-a716-446655440000",
  "createdAt"       : 1719744900.456,
  "protocolVersion" : 1
}
```

| Поле | Тип | Описание |
|---|---|---|
| `ciphertext` | `string (base64)` | AES-256-GCM зашифрованный JSON массив `LedgerEntry[]` |
| `nonce` | `string (base64)` | 96-битный nonce (12 байт), уникальный для этого payload |
| `authTag` | `string (base64)` | 128-битный GCM authentication tag (16 байт) |
| `clientPublicKey` | `string (base64)` | Тот же ключ, что был в `/session/init` (для повторной деривации ключа) |
| `sessionID` | `string` | Должен совпадать с сессией из handshake |
| `createdAt` | `float (Unix)` | Время создания payload; отвергается если старше 300 сек |
| `protocolVersion` | `int` | Версия схемы шифрования (текущая: `1`) |

**Расшифрованное содержимое (массив `LedgerEntry`):**

```json
[
  {
    "repIndex"          : 1,
    "timestampMicros"   : 1719744123456789,
    "difficultyLevel"   : 1.0,
    "jointConfidences"  : { "minConfidence": 0.87, "side": 1.0 },
    "peakDepthAngle"    : 88.3,
    "previousEntryHash" : "GENESIS",
    "sessionID"         : "550e8400-e29b-41d4-a716-446655440000"
  },
  {
    "repIndex"          : 2,
    "timestampMicros"   : 1719744126234567,
    "difficultyLevel"   : 1.0,
    "jointConfidences"  : { "minConfidence": 0.91, "side": 1.0 },
    "peakDepthAngle"    : 86.7,
    "previousEntryHash" : "a3f2c1d4e5b6...",
    "sessionID"         : "550e8400-e29b-41d4-a716-446655440000"
  }
]
```

**Ответ `200 OK` (`ServerReceipt`):**

```json
{
  "verifiedRepCount"     : 12,
  "sessionDurationSeconds": 183.4,
  "status"               : "VERIFIED",
  "serverSignature"      : "a1b2c3d4e5f6...",
  "sessionID"            : "550e8400-e29b-41d4-a716-446655440000"
}
```

**Значения поля `status`:**

| Значение | Описание |
|---|---|
| `VERIFIED` | Все повторения прошли все проверки |
| `PARTIAL_CREDIT` | Часть повторений отклонена (слишком быстрые, нарушена хронология) |
| `REJECTED` | Вся сессия отклонена (неверный GCM-тег или нет ни одного валидного повторения) |
| `REPLAY_ATTACK` | Payload устарел (> 300 сек) или обнаружены дубликаты timestamps |
| `LEDGER_CORRUPT` | SHA-256 цепочка хэшей нарушена |

**Алгоритм верификации сервера:**

```
1. Проверка возраста payload: |now - createdAt| ≤ 300 сек
2. Получение AES-ключа из SESSION_KEY_STORE[sessionID]
3. AES-256-GCM расшифровка:
     AESGCM(key).decrypt(nonce, ciphertext + authTag)
     → InvalidTag exception = REJECTED
4. Парсинг LedgerEntry[]
5. Верификация хэш-цепочки:
     prev_hash = "GENESIS"
     для каждой entry:
         если entry.previousEntryHash ≠ prev_hash → LEDGER_CORRUPT
         prev_hash = SHA256(JSON(entry, sort_keys=True))
6. Хронологическая верификация:
     для каждой пары (entry_i, entry_{i+1}):
         если timestampMicros_{i+1} - timestampMicros_i < 500_000 → отклонить повтор
         если repIndex ≠ i+1 → отклонить повтор
7. Подсчёт valid_entries
8. HMAC-SHA256 подпись квитанции:
     signature = HMAC(SERVER_SECRET, f"{sessionID}:{count}:{status}:{timestamp}")
9. Удаление сессионного ключа (одноразовое использование)
```

---

### 5.3 Обработка ошибок

| HTTP код | Ситуация | Действие клиента |
|---|---|---|
| `400` | Некорректный запрос / невалидный ключ | Показать ошибку пользователю |
| `401` | Сессия не найдена или истекла | Повторить `POST /session/init` |
| `422` | Ошибка расшифровки | Логировать; не повторять |
| `429` | Rate limit | Экспоненциальная пауза (1s, 2s, 4s...) |
| `5xx` | Серверная ошибка | Retry с jitter, максимум 3 попытки |

---

## 6. Архитектура безопасности (все 4 уровня)

### L1 — `AntiSpoofingDetector`

**Скользящее окно:** 60 кадров (~2 секунды при 30 fps)

| Сигнал | Вычисление | Порог блокировки |
|---|---|---|
| Z-прокси | `Var(shoulderWidth / torsoHeight)` за 60 кадров | `< 4×10⁻⁴` |
| Микротремор | `Mean(|Δx_shoulder| + |Δy_shoulder|) / 2` | `< 5×10⁻⁵` |
| Заморозка | `FNV-1a(квантизованные_координаты) == prev_hash` × N | `8 дублей` |

### L2 — `ProcessIntegrityGuard`

**Проверки при старте + периодически каждые 45 секунд:**

```
checkJailbreakFiles()    → Foundation.fileExists() + fopen()  [21 путь]
checkSandboxEscape()     → запись в /private/var/
checkLoadedDylibs()      → _dyld_get_image_name() × image_count [16 паттернов]
checkDebuggerAttached()  → sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID) → P_TRACED
```

### L3 — `SecureStateLedger`

```
Ключевой материал:
  client: P256.KeyAgreement.PrivateKey  (эфемерный, только RAM)
  server: P256.KeyAgreement.PrivateKey  (эфемерный, только RAM)
  shared: HKDF(ECDH(client, server), ...) → AES-256 key

Реестр: [LedgerEntry] с SHA-256 цепочкой хэшей
Шифрование: AES.GCM.seal(JSON, key) → SealedBox
Export: { nonce(12) + ciphertext(N) + tag(16) }  все в base64
```

### L4 — `TransportSecurityManager`

```
TLS Pinning (SPKI):
  SHA256(DER(SubjectPublicKeyInfo(leaf_cert))) ∈ pinnedSPKIHashes

App Integrity:
  embedded.mobileprovision → TeamIdentifier == expectedTeamID
  #if DEBUG → блокировка
  Bundle.main.bundleIdentifier == expectedBundleID
```

---

## 7. Ключевые инварианты системы

1. **Повторение никогда не засчитывается если `PushUpPostureValidator` не пройден** — глобальный шлюз выполняется до любой логики углов.

2. **`ObfuscatedCounter.safeValue()` возвращает `nil`** при любом внешнем вмешательстве — вызывающий код должен обрабатывать `nil` как безусловную блокировку сессии.

3. **Сессионный AES-ключ одноразовый** — после `POST /v1/workout/verify` сервер удаляет ключ из `SESSION_KEY_STORE`. Повторная отправка того же payload вернёт `401`.

4. **Порядок вызовов `SecureWorkoutSession`** строго линейный:
   ```
   startSession() → [validateFrame() × N] → [registerRep() × M] → finishSession()
   ```
   Любое нарушение порядка выбрасывает `SecuritySessionError`.

5. **Vision координаты — Y-up.** Все геометрические функции в `PoseGeometry.swift` работают в этом пространстве. Флип `y_screen = 1 - y_vision` применяется **только** в слое отрисовки UI.

---

*Документ актуален для версии протокола `v1` (protocolVersion: 1).*  
*При изменении схемы шифрования или API — обновите этот документ и увеличьте `protocolVersion`.*

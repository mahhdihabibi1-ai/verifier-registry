// SBT-бейджи vinyl.market DAO — общие типы, сообщения и ошибки (DAO.md, раздел 4.2).
// Совместимость: TEP-62 (NFT), TEP-64 (метаданные в блокчейне), TEP-85 (SBT).
// Поведение бейджа повторяет getgems sbt-item.fc (коммит 2727ec0d), код написан заново на Tolk.

// ───────────── Виды бейджей ─────────────
// Новые виды добавляет владелец коллекции (AddKind); описания существующих не меняются.
const KIND_LABEL = 1 // «Лейбл» — выдаёт мультиподпись
const KIND_TEAM = 2 // «Команда» — выдаёт мультиподпись
const KIND_COLLECTOR = 3 // «Коллекционер» — выдаёт ключ выдачи сайта (или мультиподпись)

// ───────────── Суммы ─────────────
// Сколько GRAM приложить к выпуску (излишек вернётся отправителю)
const MIN_MINT_VALUE = grams("0.05")
// Сколько остаётся на бейдже для оплаты хранения
const BADGE_RESERVE = grams("0.02")
// Сколько оставляет коллекция себе при выводе излишка
const COLLECTION_RESERVE = grams("0.05")

const SECONDS_PER_DAY = 86400

enum SbtErrors {
    NotCollectionOwner = 200
    NotMinter = 201
    KindNotAllowed = 202 // ключ выдачи может выпускать только «Коллекционера»
    UnknownKind = 203
    KindExists = 204
    DailyLimit = 205
    NotEnoughValue = 206
    NotFromCollection = 207
    AlreadyInitialized = 208
    NotInitialized = 209
    NotBadgeOwner = 210
    NotAuthority = 211
    AlreadyRevoked = 212
    NonTransferable = 213
    InvalidMessage = 0xFFFF
}

// ───────────── Хранилища ─────────────

struct SbtCollectionStorage {
    owner: address          // мультиподпись: выпуск любых видов, отзыв (authority бейджей), настройки
    issuer: address?        // ключ выдачи сайта: только «Коллекционер», с дневным лимитом
    dailyLimit: uint16      // сколько бейджей ключ выдачи может выпустить за сутки (UTC)
    day: uint32             // номер текущих суток (now / 86400)
    issuedToday: uint16     // сколько ключ выдачи выпустил за эти сутки
    issuedTotal: uint64     // всего выпусков
    content: cell           // метаданные коллекции (TEP-64, в блокчейне)
    kinds: map<uint8, cell> // вид → метаданные бейджа (TEP-64, в блокчейне)
}

struct BadgeState {
    owner: address?     // null после уничтожения владельцем
    kind: uint8
    authority: address? // кто может отозвать (владелец коллекции на момент выпуска); null после уничтожения
    revokedAt: uint64   // время отзыва; 0 — не отозван
}

struct SbtItemStorage {
    collection: address
    index: uint256           // = хэш (вид, кошелёк): адрес бейджа зависит только от них
    state: Cell<BadgeState>? // null до выпуска
}

// ───────────── Сообщения vinyl.market ─────────────

// владелец коллекции или ключ выдачи → коллекция
struct (0x53420001) MintBadge {
    queryId: uint64
    owner: address
    kind: uint8
}

// коллекция → бейдж (с развёртыванием)
struct (0x53420002) InitBadge {
    owner: address
    kind: uint8
    authority: address
    excessesTo: address // кому вернуть излишек (тот, кто запросил выпуск)
}

// владелец коллекции → коллекция
struct (0x53420003) SetIssuer {
    queryId: uint64
    issuer: address?
    dailyLimit: uint16
}

struct (0x53420004) AddKind {
    queryId: uint64
    kind: uint8
    content: cell
}

struct (0x53420005) WithdrawExcess {
    queryId: uint64
}

// событие для журнала (внешнее сообщение)
struct (0x53428001) BadgeMintedEvent {
    kind: uint8
    owner: address
    index: uint256
    byIssuer: bool
}

// ───────────── Стандартные сообщения NFT/SBT ─────────────

// TEP-62: передача — у SBT всегда отказ
struct (0x5fcc3d14) NftTransfer {
    queryId: uint64
    rest: RemainingBitsAndRefs
}

struct (0x2fcb26a2) GetStaticData {
    queryId: uint64
}

struct (0x8b771735) ReportStaticData {
    queryId: uint64
    index: uint256
    collection: address
}

// TEP-85
struct (0x04ded148) ProveOwnership {
    queryId: uint64
    dest: address
    forwardPayload: cell
    withContent: bool
}

struct (0x0524c7ae) OwnershipProof {
    queryId: uint64
    itemId: uint256
    owner: address
    data: cell
    revokedAt: uint64
    content: cell?
}

struct (0xc18e86d2) OwnershipProofBounced {
    queryId: uint64
}

struct (0xd0c3bfea) RequestOwner {
    queryId: uint64
    dest: address
    forwardPayload: cell
    withContent: bool
}

// Реально ≤ 951 бит: owner — внутренний адрес (267) или addr_none (2); формат задан TEP-85.
@overflow1023_policy("suppress")
struct (0x0dd607e3) OwnerInfo {
    queryId: uint64
    itemId: uint256
    initiator: address
    owner: any_address // addr_none после уничтожения бейджа
    data: cell
    revokedAt: uint64
    content: cell?
}

struct (0x1f04537a) Destroy {
    queryId: uint64
}

struct (0x6f89f5e3) Revoke {
    queryId: uint64
}

struct (0xd136d3b3) TakeExcess {
    queryId: uint64
}

struct (0xd53276db) Excesses {
    queryId: uint64
}

// ───────────── Общие функции ─────────────

// Номер бейджа: один бейдж каждого вида на кошелёк (разные виды — можно).
fun badgeIndex(owner: address, kind: uint8): uint256 {
    return beginCell().storeUint(kind, 8).storeAddress(owner).endCell().hash();
}

// address? → any_address: null становится addr_none (так ждут кошельки и обозреватели)
fun orNone(a: address?): any_address {
    if (a == null) {
        return createAddressNone();
    }
    return a as any_address;
}

// Личное содержимое бейджа (TEP-64: individual content) — номер вида.
fun kindContent(kind: uint8): cell {
    return beginCell().storeUint(kind, 8).endCell();
}

fun SbtCollectionStorage.load(): SbtCollectionStorage {
    return SbtCollectionStorage.fromCell(contract.getData());
}

fun SbtCollectionStorage.save(self) {
    contract.setData(self.toCell());
}

fun SbtItemStorage.load(): SbtItemStorage {
    return SbtItemStorage.fromCell(contract.getData());
}

fun SbtItemStorage.save(self) {
    contract.setData(self.toCell());
}

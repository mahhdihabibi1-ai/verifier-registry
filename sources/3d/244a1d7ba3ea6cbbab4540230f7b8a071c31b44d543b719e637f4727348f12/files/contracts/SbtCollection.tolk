// SbtCollection — коллекция SBT-бейджей vinyl.market DAO (DAO.md, раздел 4.2).
// Владелец (мультиподпись 2 из 3) выпускает любые виды и является authority бейджей (отзыв).
// Ключ выдачи сайта выпускает только «Коллекционера» и не больше dailyLimit в сутки.
// Метаданные коллекции и видов хранятся в блокчейне (TEP-64), описания видов не меняются.
import "@gen/SbtItem.code"
import "sbt-types"

type AllowedCollectionMessage = MintBadge | SetIssuer | AddKind | WithdrawExcess

contract SbtCollection {
    storage: SbtCollectionStorage
    incomingMessages: AllowedCollectionMessage
}

fun itemInitFor(index: uint256): ContractState {
    return {
        code: sbtItemCompiledCode(),
        data: SbtItemStorage {
            collection: contract.getAddress(),
            index,
            state: null,
        }.toCell(),
    };
}

fun assertOwner(storage: SbtCollectionStorage, sender: address) {
    assert (sender == storage.owner) throw SbtErrors.NotCollectionOwner;
}

fun replyExcess(to: address, queryId: uint64) {
    val reply = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: to,
        body: Excesses { queryId },
    });
    // SAFETY: только остаток входящего сообщения; баланс коллекции не расходуется.
    reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedCollectionMessage.fromSlice(in.body);

    match (msg) {
        MintBadge => {
            var storage = lazy SbtCollectionStorage.load();
            val byOwner = in.senderAddress == storage.owner;
            if (!byOwner) {
                assert (
                    storage.issuer != null && in.senderAddress == storage.issuer
                ) throw SbtErrors.NotMinter;
                assert (msg.kind == KIND_COLLECTOR) throw SbtErrors.KindNotAllowed;
                val day = blockchain.now() / SECONDS_PER_DAY;
                if (day != storage.day) {
                    storage.day = day;
                    storage.issuedToday = 0;
                }
                assert (storage.issuedToday < storage.dailyLimit) throw SbtErrors.DailyLimit;
                storage.issuedToday += 1;
            }
            assert (storage.kinds.exists(msg.kind)) throw SbtErrors.UnknownKind;
            assert (in.valueCoins >= MIN_MINT_VALUE) throw SbtErrors.NotEnoughValue;
            storage.issuedTotal += 1;
            storage.save();

            val index = badgeIndex(msg.owner, msg.kind);
            val deploy = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                value: 0,
                dest: { stateInit: itemInitFor(index) },
                body: InitBadge {
                    owner: msg.owner,
                    kind: msg.kind,
                    authority: storage.owner,
                    excessesTo: in.senderAddress,
                },
            });
            // SAFETY: в бейдж уходит только то, что приложил выпускающий (не меньше
            // MIN_MINT_VALUE); бейдж оставит резерв и вернёт ему излишек.
            deploy.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);

            val log = createExternalLogMessage({
                dest: createAddressNone(),
                body: BadgeMintedEvent {
                    kind: msg.kind,
                    owner: msg.owner,
                    index,
                    byIssuer: !byOwner,
                },
            });
            log.send(SEND_MODE_REGULAR);
        }
        SetIssuer => {
            var storage = lazy SbtCollectionStorage.load();
            assertOwner(storage, in.senderAddress);
            storage.issuer = msg.issuer;
            storage.dailyLimit = msg.dailyLimit;
            storage.save();
            replyExcess(in.senderAddress, msg.queryId);
        }
        AddKind => {
            var storage = lazy SbtCollectionStorage.load();
            assertOwner(storage, in.senderAddress);
            assert (!storage.kinds.exists(msg.kind)) throw SbtErrors.KindExists;
            storage.kinds.set(msg.kind, msg.content);
            storage.save();
            replyExcess(in.senderAddress, msg.queryId);
        }
        WithdrawExcess => {
            val storage = lazy SbtCollectionStorage.load();
            assertOwner(storage, in.senderAddress);
            reserveGramsOnBalance(COLLECTION_RESERVE, RESERVE_MODE_AT_MOST);
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: in.senderAddress,
                body: Excesses { queryId: msg.queryId },
            });
            // SAFETY: владельцу коллекции уходит всё сверх резерва на хранение
            // (например, GRAM, вернувшиеся при повторном выпуске).
            reply.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        else => {
            // пустое сообщение — пополнение баланса
            assert (in.body.isEmpty()) throw SbtErrors.InvalidMessage;
        }
    }
}

// Бейдж уже был выпущен (повторный выпуск) — GRAM остаются в коллекции,
// владелец может вывести их сообщением WithdrawExcess.
fun onBouncedMessage(_in: InMessageBounced) {}

// ───────────── Геттеры TEP-62 ─────────────

// (следующий номер: -1 — номера не по порядку, метаданные коллекции, владелец)
get fun get_collection_data(): (int, cell, address) {
    val storage = lazy SbtCollectionStorage.load();
    return (-1, storage.content, storage.owner);
}

get fun get_nft_address_by_index(index: int): address {
    return AutoDeployAddress { stateInit: itemInitFor(index as uint256) }.calculateAddress();
}

// Полные метаданные бейджа по его личному содержимому (номеру вида)
get fun get_nft_content(_index: int, individualContent: cell): cell {
    val storage = lazy SbtCollectionStorage.load();
    val kind = individualContent.beginParse().loadUint(8) as uint8;
    val found = storage.kinds.get(kind);
    return found.isFound ? found.loadValue() : createEmptyCell();
}

// ───────────── Геттеры vinyl.market ─────────────

// Адрес бейджа вида kind у кошелька owner (есть ли он — смотреть get_nft_data)
get fun badgeAddress(owner: address, kind: uint8): address {
    return AutoDeployAddress { stateInit: itemInitFor(badgeIndex(owner, kind)) }.calculateAddress();
}

// (ключ выдачи, дневной лимит, выпущено ключом за текущие сутки, номер суток, всего выпусков)
get fun issuerInfo(): (address?, uint16, uint16, uint32, uint64) {
    val storage = lazy SbtCollectionStorage.load();
    val today = blockchain.now() / SECONDS_PER_DAY;
    val issuedToday: uint16 = storage.day == today ? storage.issuedToday : 0 as uint16;
    return (storage.issuer, storage.dailyLimit, issuedToday, today, storage.issuedTotal);
}

get fun hasKind(kind: uint8): bool {
    val storage = lazy SbtCollectionStorage.load();
    return storage.kinds.exists(kind);
}

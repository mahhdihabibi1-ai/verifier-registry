// SbtItem — один непередаваемый бейдж (TEP-85). Адрес зависит только от коллекции
// и номера (= хэш вида и кошелька), поэтому второй такой же бейдж выпустить нельзя.
import "sbt-types"

type AllowedItemMessage =
    | InitBadge
    | NftTransfer
    | GetStaticData
    | ProveOwnership
    | RequestOwner
    | Destroy
    | Revoke
    | TakeExcess

contract SbtItem {
    storage: SbtItemStorage
    incomingMessages: AllowedItemMessage
}

fun loadState(storage: SbtItemStorage): BadgeState {
    assert (storage.state != null) throw SbtErrors.NotInitialized;
    return storage.state.load();
}

fun assertBadgeOwner(state: BadgeState, sender: address) {
    assert (state.owner != null && sender == state.owner) throw SbtErrors.NotBadgeOwner;
}

// Возвращает отправителю остаток его сообщения (баланс бейджа не трогает).
fun replyExcess(to: address, queryId: uint64) {
    val reply = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: to,
        body: Excesses { queryId },
    });
    // SAFETY: только остаток входящего сообщения.
    reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

fun onInternalMessage(in: InMessage) {
    val msg = lazy AllowedItemMessage.fromSlice(in.body);

    match (msg) {
        InitBadge => {
            var storage = lazy SbtItemStorage.load();
            assert (in.senderAddress == storage.collection) throw SbtErrors.NotFromCollection;
            assert (storage.state == null) throw SbtErrors.AlreadyInitialized;
            storage.state = BadgeState {
                owner: msg.owner,
                kind: msg.kind,
                authority: msg.authority,
                revokedAt: 0,
            }.toCell();
            storage.save();

            // Резерв на хранение остаётся на бейдже, остальное — тому, кто запросил выпуск.
            reserveGramsOnBalance(BADGE_RESERVE, RESERVE_MODE_AT_MOST);
            val refund = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: msg.excessesTo,
                body: Excesses { queryId: 0 },
            });
            // SAFETY: при выпуске весь баланс бейджа — деньги выпускающего; резерв остаётся.
            refund.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        NftTransfer => {
            throw SbtErrors.NonTransferable;
        }
        GetStaticData => {
            val storage = lazy SbtItemStorage.load();
            loadState(storage);
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: in.senderAddress,
                body: ReportStaticData {
                    queryId: msg.queryId,
                    index: storage.index,
                    collection: storage.collection,
                },
            });
            // SAFETY: только остаток входящего сообщения.
            reply.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        ProveOwnership => {
            val storage = lazy SbtItemStorage.load();
            val state = loadState(storage);
            assertBadgeOwner(state, in.senderAddress);
            val proof = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                value: 0,
                dest: msg.dest,
                body: OwnershipProof {
                    queryId: msg.queryId,
                    itemId: storage.index,
                    owner: in.senderAddress,
                    data: msg.forwardPayload,
                    revokedAt: state.revokedAt,
                    content: msg.withContent ? kindContent(state.kind) : null,
                },
            });
            // SAFETY: только остаток входящего сообщения владельца.
            proof.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        RequestOwner => {
            val storage = lazy SbtItemStorage.load();
            val state = loadState(storage);
            val info = createMessage({
                bounce: BounceMode.Only256BitsOfBody,
                value: 0,
                dest: msg.dest,
                body: OwnerInfo {
                    queryId: msg.queryId,
                    itemId: storage.index,
                    initiator: in.senderAddress,
                    owner: orNone(state.owner),
                    data: msg.forwardPayload,
                    revokedAt: state.revokedAt,
                    content: msg.withContent ? kindContent(state.kind) : null,
                },
            });
            // SAFETY: только остаток входящего сообщения.
            info.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }
        Destroy => {
            var storage = lazy SbtItemStorage.load();
            var state = loadState(storage);
            assertBadgeOwner(state, in.senderAddress);
            state.owner = null;
            state.authority = null;
            storage.state = state.toCell();
            storage.save();
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: in.senderAddress,
                body: Excesses { queryId: msg.queryId },
            });
            // SAFETY: бейдж уничтожен владельцем — весь остаток баланса возвращается ему.
            reply.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        Revoke => {
            var storage = lazy SbtItemStorage.load();
            var state = loadState(storage);
            assert (
                state.authority != null && in.senderAddress == state.authority
            ) throw SbtErrors.NotAuthority;
            assert (state.revokedAt == 0) throw SbtErrors.AlreadyRevoked;
            state.revokedAt = blockchain.now();
            storage.state = state.toCell();
            storage.save();
            replyExcess(in.senderAddress, msg.queryId);
        }
        TakeExcess => {
            val storage = lazy SbtItemStorage.load();
            val state = loadState(storage);
            assertBadgeOwner(state, in.senderAddress);
            reserveGramsOnBalance(BADGE_RESERVE, RESERVE_MODE_AT_MOST);
            val reply = createMessage({
                bounce: BounceMode.NoBounce,
                value: 0,
                dest: in.senderAddress,
                body: Excesses { queryId: msg.queryId },
            });
            // SAFETY: владельцу уходит всё сверх резерва на хранение.
            reply.send(SEND_MODE_CARRY_ALL_BALANCE | SEND_MODE_IGNORE_ERRORS);
        }
        else => {
            // пустое сообщение — пополнение баланса
            assert (in.body.isEmpty()) throw SbtErrors.InvalidMessage;
        }
    }
}

// Получатель не принял доказательство владения — сообщаем владельцу (как в getgems).
fun onBouncedMessage(in: InMessageBounced) {
    in.bouncedBody.skipBouncedPrefix();
    val op = in.bouncedBody.loadUint(32);
    if (op != 0x0524c7ae) {
        return;
    }
    val queryId = in.bouncedBody.loadUint(64);
    val storage = lazy SbtItemStorage.load();
    val state = loadState(storage);
    if (state.owner == null) {
        return;
    }
    val notice = createMessage({
        bounce: BounceMode.NoBounce,
        value: 0,
        dest: state.owner,
        body: OwnershipProofBounced { queryId },
    });
    // SAFETY: возвращаем владельцу остаток его же сообщения.
    notice.send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE | SEND_MODE_IGNORE_ERRORS);
}

// ───────────── Геттеры TEP-62 / TEP-85 ─────────────

// (инициализирован, номер, коллекция, владелец, личное содержимое)
get fun get_nft_data(): (bool, uint256, address, any_address, cell) {
    val storage = lazy SbtItemStorage.load();
    if (storage.state == null) {
        return (false, storage.index, storage.collection, createAddressNone(), createEmptyCell());
    }
    val state = storage.state.load();
    return (true, storage.index, storage.collection, orNone(state.owner), kindContent(state.kind));
}

get fun get_authority_address(): any_address {
    val storage = lazy SbtItemStorage.load();
    if (storage.state == null) {
        return createAddressNone();
    }
    val state = storage.state.load();
    return orNone(state.authority);
}

get fun get_revoked_time(): uint64 {
    val storage = lazy SbtItemStorage.load();
    if (storage.state == null) {
        return 0;
    }
    return storage.state.load().revokedAt;
}

// Вид бейджа (1 — Лейбл, 2 — Команда, 3 — Коллекционер); 0 — не выпущен
get fun badgeKind(): uint8 {
    val storage = lazy SbtItemStorage.load();
    if (storage.state == null) {
        return 0;
    }
    return storage.state.load().kind;
}

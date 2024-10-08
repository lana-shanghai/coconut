//! Fake LN Backend
//!
//! Used for testing where quotes are auto filled
const core = @import("../core/lib.zig");
const std = @import("std");
const lightning_invoice = @import("../lightning_invoices/invoice.zig");
const helper = @import("../helper/helper.zig");
const zul = @import("zul");
const secp256k1 = @import("bitcoin-primitives").secp256k1;
const ref = @import("../sync/ref.zig");
const mpmc = @import("../sync/mpmc.zig");

const Amount = core.amount.Amount;
const PaymentQuoteResponse = core.lightning.PaymentQuoteResponse;
const CreateInvoiceResponse = core.lightning.CreateInvoiceResponse;
const PayInvoiceResponse = core.lightning.PayInvoiceResponse;
const MeltQuoteBolt11Request = core.nuts.nut05.MeltQuoteBolt11Request;
const Settings = core.lightning.Settings;
const MintMeltSettings = core.lightning.MintMeltSettings;
const FeeReserve = core.mint.FeeReserve;
const Channel = @import("../channels/channels.zig").Channel;
const MintQuoteState = core.nuts.nut04.QuoteState;
const MintLightning = core.lightning.MintLightning;

// TODO:  wait any invoices, here we need create a new listener, that will receive
// message like pub sub channel

fn sendLabelFn(label: std.ArrayList(u8), ch: ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))), duration: u64) void {
    errdefer label.deinit();
    defer ch.releaseWithFn((struct {
        fn deinit(_self: mpmc.UnboundedChannel(std.ArrayList(u8))) void {
            _self.deinit();
        }
    }).deinit);

    std.time.sleep(duration * @as(u64, 1e9));

    var sender = ch.value.sender() catch return std.log.err("channel closed, cannot take sender", .{});

    sender.send(label) catch |err| {
        std.log.err("send label {s}, failed: {any}", .{ label.items, err });
        return;
    };

    std.log.debug("successfully sent label, label {s}", .{label.items});
}

/// Fake Wallet
pub const FakeWallet = struct {
    const Self = @This();

    fee_reserve: core.mint.FeeReserve = .{},
    chan: ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))), // we using signle channel for sending invoices
    mint_settings: MintMeltSettings = .{},
    melt_settings: MintMeltSettings = .{},

    thread_pool: *zul.ThreadPool(sendLabelFn),

    allocator: std.mem.Allocator,

    /// Creat init [`FakeWallet`]
    pub fn init(
        allocator: std.mem.Allocator,
        fee_reserve: FeeReserve,
        mint_settings: MintMeltSettings,
        melt_settings: MintMeltSettings,
    ) !FakeWallet {
        const ch = try ref.arc(allocator, mpmc.UnboundedChannel(std.ArrayList(u8)).init(allocator));
        errdefer ch.releaseWithFn((struct {
            fn deinit(_self: mpmc.UnboundedChannel(std.ArrayList(u8))) void {
                _self.deinit();
            }
        }).deinit);

        return .{
            .chan = ch,
            .fee_reserve = fee_reserve,
            .mint_settings = mint_settings,
            .melt_settings = melt_settings,
            .allocator = allocator,
            .thread_pool = try zul.ThreadPool(sendLabelFn).init(allocator, .{ .count = 3 }),
        };
    }

    pub fn toMintLightning(self: *const Self, gpa: std.mem.Allocator) error{OutOfMemory}!MintLightning {
        return MintLightning.initFrom(Self, gpa, self.*);
    }

    pub fn deinit(self: *FakeWallet) void {
        self.chan.releaseWithFn((struct {
            fn deinit(_self: mpmc.UnboundedChannel(std.ArrayList(u8))) void {
                _self.deinit();
            }
        }).deinit);
        self.thread_pool.deinit(self.allocator);
    }

    pub fn getSettings(self: *const Self) Settings {
        return .{
            .mpp = true,
            .unit = .msat,
            .melt_settings = self.melt_settings,
            .mint_settings = self.mint_settings,
        };
    }

    // Result is channel with invoices, caller must free result
    pub fn waitAnyInvoice(
        self: *Self,
    ) ref.Arc(mpmc.UnboundedChannel(std.ArrayList(u8))) {
        return self.chan.retain();
    }

    /// caller responsible to deallocate result
    pub fn getPaymentQuote(
        self: *const Self,
        allocator: std.mem.Allocator,
        melt_quote_request: MeltQuoteBolt11Request,
    ) !PaymentQuoteResponse {
        const invoice_amount_msat = melt_quote_request
            .request
            .amountMilliSatoshis() orelse return error.UnknownInvoiceAmount;

        const amount = try core.lightning.toUnit(
            invoice_amount_msat,
            .msat,
            melt_quote_request.unit,
        );

        const relative_fee_reserve: u64 =
            @intFromFloat(self.fee_reserve.percent_fee_reserve * @as(f32, @floatFromInt(amount)));

        const absolute_fee_reserve: u64 = self.fee_reserve.min_fee_reserve;

        const fee = if (relative_fee_reserve > absolute_fee_reserve)
            relative_fee_reserve
        else
            absolute_fee_reserve;

        const req_lookup_id = try helper.copySlice(allocator, &melt_quote_request.request.paymentHash().inner);
        errdefer allocator.free(req_lookup_id);

        return .{
            .request_lookup_id = req_lookup_id,
            .amount = amount,
            .fee = fee,
            .state = .unpaid,
        };
    }

    /// pay invoice, caller responsible too free
    pub fn payInvoice(
        self: *const Self,
        allocator: std.mem.Allocator,
        melt_quote: core.mint.MeltQuote,
        _partial_msats: ?Amount,
        _max_fee_msats: ?Amount,
    ) !PayInvoiceResponse {
        _ = allocator; // autofix
        _ = self; // autofix
        _ = _partial_msats; // autofix
        _ = _max_fee_msats; // autofix

        return .{
            .unit = .msat,
            .payment_preimage = &.{},
            .payment_hash = &.{}, // empty slice - safe to free
            .status = .paid,
            .total_spent = melt_quote.amount,
        };
    }

    pub fn checkInvoiceStatus(
        self: *const Self,
        _request_lookup_id: []const u8,
    ) !MintQuoteState {
        _ = self; // autofix
        _ = _request_lookup_id; // autofix
        return .paid;
    }

    /// creating invoice - caller own response and responsible to free
    pub fn createInvoice(
        self: *Self,
        gpa: std.mem.Allocator,
        amount: Amount,
        unit: core.nuts.CurrencyUnit,
        description: []const u8,
        unix_expiry: u64,
    ) !CreateInvoiceResponse {
        const time_now: u64 = @intCast(std.time.timestamp());
        std.debug.assert(unix_expiry > time_now);

        const label = try gpa.dupe(u8, &zul.UUID.v4().toHex(.lower));
        errdefer gpa.free(label);

        const sha256 = std.crypto.hash.sha2.Sha256;

        var payment_hash: [sha256.digest_length]u8 = undefined;

        sha256.hash(&([_]u8{0} ** 32), &payment_hash, .{});

        const payment_secret = [_]u8{42} ** 32;

        const _amount = try core.lightning.toUnit(amount, unit, .msat);

        var invoice_builder = try lightning_invoice.InvoiceBuilder.init(gpa, .bitcoin);
        errdefer invoice_builder.deinit();

        try invoice_builder.setDescription(gpa, description);
        try invoice_builder.setPaymentHash(payment_hash);
        try invoice_builder.setPaymentSecret(gpa, .{ .inner = payment_secret });
        try invoice_builder.setAmountMilliSatoshis(_amount);
        try invoice_builder.setCurrentTimestamp();
        try invoice_builder.setMinFinalCltvExpiryDelta(144);

        var signed_invoice = try invoice_builder.tryBuildSigned(gpa, (struct {
            fn sign(hash: secp256k1.Message) !secp256k1.ecdsa.RecoverableSignature {
                const private_key = try secp256k1.SecretKey.fromSlice(
                    &.{
                        0xe1, 0x26, 0xf6, 0x8f, 0x7e, 0xaf, 0xcc, 0x8b, 0x74, 0xf5, 0x4d, 0x26, 0x9f, 0xe2,
                        0x06, 0xbe, 0x71, 0x50, 0x00, 0xf9, 0x4d, 0xac, 0x06, 0x7d, 0x1c, 0x04, 0xa8, 0xca,
                        0x3b, 0x2d, 0xb7, 0x34,
                    },
                );

                var secp = secp256k1.Secp256k1.genNew();
                defer secp.deinit();

                return secp.signEcdsaRecoverable(&hash, &private_key);
            }
        }).sign);
        errdefer signed_invoice.deinit();

        // Create a random delay between 3 and 6 seconds
        const duration = std.crypto.random.intRangeLessThanBiased(u64, 3, 7);

        // spawning thread to sent label
        {
            const label_clone = try self.allocator.dupe(u8, label);
            errdefer self.allocator.free(label_clone);

            try self.thread_pool.spawn(.{ std.ArrayList(u8).fromOwnedSlice(self.allocator, label_clone), self.chan.retain(), duration });
        }

        const expiry = signed_invoice.expiresAtSecs();

        return .{
            .request_lookup_id = label,
            .request = signed_invoice,
            .expiry = expiry,
        };
    }
};

test {
    var mint = try FakeWallet.init(std.testing.allocator, .{}, .{}, .{});
    defer mint.deinit();

    const ln = mint.toMintLightning();
    const settings = try ln.getSettings();

    const _settings = mint.getSettings();

    std.testing.expectEqual(settings, _settings);
    std.log.warn("qq", .{});
}

// Watt Bank for Mac — stores Pokémon Pikachu 2 GS watts on the Mac.
// Talks to the ESP32 IR head (firmware wattbank_ir, "#READY WATTBANK-IR 4") over USB serial.
// Build: see build.sh (swiftc, no Xcode needed).

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CoreImage
import Foundation

let appVersion = "8.0"
let maxPerTransfer = 999
let maxBatch = 9_999

// MARK: - Formatting

/// What to do so a save edit actually reaches the game. EverDrive carts (a GBCSYS folder on the SD card) copy the
/// game's own memory over the SD save when they boot to their menu, so the edit has to happen after that.
func saveTip(_ path: String?) -> String {
    if let p = path, p.contains("/GBCSYS/") {
        let name = (p as NSString).lastPathComponent
        return "EverDrive: boot to the cart's menu before moving money (so it saves its memory to the SD card), then move money here and eject. In the cart's menu (Hide GBCSYS = Off), open GBCSYS/SAVE/\(name), press A → Copy File To RAM, then start the game. A backup is kept."
    }
    return "Close the game first. For a cartridge, 3DS or Switch, put the save back afterwards. A backup is kept."
}

/// The amount in a transfer window, drawn as a text box with a blinking cursor so it's clear you can type into it.
struct AmountField: View {
    let text: String
    let typing: Bool
    @State private var on = true
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Text(text).font(.system(size: 22, weight: .bold, design: .rounded)).contentTransition(.numericText())
                Rectangle().fill(Color.accentColor).frame(width: 2, height: 24).opacity(on ? 1 : 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .frame(minWidth: 150, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2))
            Text(typing ? "⌫ to erase" : "type a number").font(.system(size: 10)).foregroundColor(.secondary)
        }
        .onReceive(Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()) { _ in on.toggle() }
        .help("Type the amount with the number keys. ⌫ erases, ← → nudge it.")
    }
}

/// Typing an amount in any transfer window: digits build the number (capped at the most allowed), ⌫ removes one.
func typeAmount(_ k: KeyPress, _ amount: inout Int, _ typing: inout Bool, _ top: Int) -> Bool {
    let back = k.key == .delete || k.characters == "\u{7F}" || k.characters == "\u{8}"
    return typeAmountChar(k.characters, back, &amount, &typing, top)
}
func typeAmountChar(_ c: String, _ back: Bool, _ amount: inout Int, _ typing: inout Bool, _ top: Int) -> Bool {
    if back { amount = typing ? amount / 10 : 0; typing = true; return true }
    guard c.count == 1, let d = Int(c) else { return false }
    let v = typing ? amount * 10 + d : d
    amount = min(v, max(0, top)); typing = true
    return true
}

/// While a transfer window is open, number keys and ⌫ go to its amount from anywhere in the app,
/// even if a click moved keyboard focus to a button (caught by the app-wide key monitor).
enum AmountKeys {
    static var handler: ((String, Bool) -> Bool)? = nil
}

/// Watts ↔ PokéDollars at the bank's rate (0.83 W per ₽). The Credit card and its loans are in ₽.
func pdOf(_ w: Int) -> Int { Int((Double(w) / 0.83).rounded()) }
func pdCost(ofW w: Int) -> Int { Int((Double(w) / 0.83 - 1e-9).rounded(.up)) }    // ₽ needed to buy w watts
func pdValue(ofW w: Int) -> Int { Int((Double(w) / 0.83 + 1e-9).rounded(.down)) } // ₽ that w watts can pay
func wCost(ofPd p: Int) -> Int { Int((Double(p) * 0.83 - 1e-9).rounded(.up)) }    // watts needed to pay p ₽
func wValue(ofPd p: Int) -> Int { Int((Double(p) * 0.83 + 1e-9).rounded(.down)) } // watts that p ₽ buy

/// Card balances: full number up to 999,999, then 1.23M / 45.6M / 789M, 1.23B …, so any amount fits.
func fmtCard(_ n: Int) -> String {
    let a = abs(n), sign = n < 0 ? "-" : ""
    func short(_ v: Double, _ suffix: String) -> String {
        let s = v >= 100 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        return sign + s + suffix
    }
    if a >= 1_000_000_000_000 { return short(Double(a) / 1e12, "T") }
    if a >= 1_000_000_000 { return short(Double(a) / 1e9, "B") }
    if a >= 1_000_000 { return short(Double(a) / 1e6, "M") }
    return fmt(n)
}

func fmt(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US")
    return f.string(from: NSNumber(value: n)) ?? "\(n)"
}

// MARK: - Mystery Gift catalog (Pokémon Gold/Silver/Crystal), index = Mystery Gift code 0x00-0x24

struct Gift: Identifiable, Hashable {
    let isDeco: Bool
    let code: Int
    let name: String
    let price: Int
    var id: String { (isDeco ? "d" : "i") + String(code) }
}

/// Pricing (watts). Rate: 0.83 W per $1 of Poké Mart sell-back value — the average of the Pikachu 2 items
/// that are neither berries (token $5 value) nor stuck at its 999 W ceiling
/// (Great Ball, Max Repel, Ether, Revive, Elixer: 2,900 W for $3,500 of sell-back).
/// Each item can have up to two valuations; with two, the price is their average:
///  • Pikachu: the Pikachu 2's price, if it gives that item (not Rare Candy: 999 is only its ceiling).
///  • Market: sold in a Crystal Poké Mart → sell-back × 0.83; not sold → the higher of that and a rarity
///    floor from how often Mystery Gift hands it out on its own
///    (common 100 · uncommon 300 · rare 700 · very rare 900 · never 999).
/// Decorations have no price in the game, so they go by rarity alone: 300 · 600 · 900 · 1,200 · 1,500.
func giftRarity(_ code: Int) -> String {
    switch code {
    case 0x00...0x0F: return "Common"
    case 0x10...0x17: return "Uncommon"
    case 0x18...0x1F: return "Rare"
    case 0x20...0x21: return "Very rare"
    default: return "Special"
    }
}

let giftItems: [Gift] = [
    ("Berry", 100),
    ("PRZCureBerry", 100),
    ("Mint Berry", 100),
    ("Ice Berry", 100),
    ("Burnt Berry", 100),
    ("PSNCureBerry", 100),
    ("Guard Spec.", 290),
    ("X Defend", 228),
    ("X Attack", 207),
    ("Bitter Berry", 150),
    ("Dire Hit", 269),
    ("X Special", 145),
    ("X Accuracy", 394),
    ("Eon Mail", 287),     // avg of Pikachu 0 W, market 100 W, and a Revive (761 W): the Pokéfan in Goldenrod Pokémon Center 1F trades a Revive for it, repeatably
    ("Morph Mail", 100),
    ("Music Mail", 100),
    ("MiracleBerry", 450),
    ("Gold Berry", 500),
    ("Revive", 761),
    ("Great Ball", 274),
    ("Super Repel", 207),
    ("Max Repel", 345),
    ("Elixer", 1_021),
    ("Ether", 499),
    ("Water Stone", 870),
    ("Fire Stone", 870),
    ("Leaf Stone", 870),
    ("Thunderstone", 870),
    ("Max Ether", 829),
    ("Max Elixer", 1_864),
    ("Max Revive", 1_657),
    ("Scope Lens", 700),
    ("HP Up", 4_060),
    ("PP Up", 4_060),
    ("Rare Candy", 1_989),
    ("BlueSky Mail", 999),
    ("Mirage Mail", 999),
].enumerated().map { Gift(isDeco: false, code: $0.offset, name: $0.element.0, price: $0.element.1) }

let giftDecos: [Gift] = [
    "Jigglypuff Doll", "Poliwag Doll", "Diglett Doll", "Staryu Doll", "Magikarp Doll", "Oddish Doll",
    "Gengar Doll", "Shellder Doll", "Grimer Doll", "Voltorb Doll", "Clefairy Poster", "Jigglypuff Poster",
    "Super NES", "Weedle Doll", "Geodude Doll", "Machop Doll",
    "Magnaplant", "Tropicplant", "NES", "Nintendo 64", "Bulbasaur Doll", "Squirtle Doll", "Pink Bed", "Polkadot Bed",
    "Red Carpet", "Blue Carpet", "Yellow Carpet", "Green Carpet", "Jumboplant", "Virtual Boy", "Big Onix Doll", "Pikachu Poster",
    "Big Lapras Doll", "Surf Pikachu Doll",
    "Pikachu Bed", "Unown Doll", "Tentacool Doll",
].enumerated().map { i, n in
    Gift(isDeco: true, code: i, name: n, price: i < 0x10 ? 300 : i < 0x18 ? 600 : i < 0x20 ? 900 : i < 0x22 ? 1_200 : 1_500)
}

// MARK: - Model

struct Entry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var kind: String        // "Deposit" | "Withdraw" | "Adjust"
    var amount: Int         // watts, signed: + in, - out
    var pd: Int? = nil      // PokéDollars, signed (Cash card)
    var item: String? = nil // item or decoration sent
    /// Item column: the stored item, or the item named in an older "Gift: …" entry.
    var itemText: String? {
        if let item { return item }
        guard kind.hasPrefix("Gift: ") else { return nil }
        let rest = kind.dropFirst(6)
        return String(rest.split(separator: "(").first ?? rest).trimmingCharacters(in: .whitespaces)
    }
}

struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var crystalID: String? = nil     // the one Pokémon Crystal save this account is linked to (trainer ID, hex)
    var crystalName: String? = nil   // that save's player name
    var decos: [Int]? = nil          // decorations that save already has
    var loans: [Loan]? = nil         // Credit
    var creditLevel: Int? = nil
    var cash: Int? = nil             // Cash card: PokéDollars moved out of this trainer's saves
    var savePath: String? = nil      // the game save loaded for this trainer (shows the Trainer and Mom cards)
    var balance: Int = 0
    var totalIn: Int = 0
    var totalOut: Int = 0
    var history: [Entry] = []
}

// ----- Credit: per account. Fees never compound, so a loan can never grow past 120% of what was borrowed.
enum CreditRules {
    static let fee = 0.10            // added once, when you borrow
    static let lateFee = 0.10        // added once, if not repaid within `days`
    static let days = 7.0
    static let baseLimit = 500       // ₽ at level 0; each level doubles it
    static let maxLevel = 7          // ₽500 · 1k · 2k · 4k · 8k · 16k · 32k · 64k
    static let levelUpShare = 0.25   // a loan must be ≥ 25% of the limit to count toward leveling up
}

struct Loan: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var what: String
    var principal: Int
    var fee: Int
    var lateFee: Int = 0
    var paid: Int = 0
    var due: Date
    var late = false
    var counts = true                // big enough to raise the credit level when repaid on time
    var total: Int { principal + fee + lateFee }
    var owed: Int { max(0, total - paid) }
}

struct CrystalSave: Codable { var name: String; var decos: [Int] = [] }

/// The account's name is the trainer's: the name from the game save (or the ID if it has none).
func trainerName(_ name: String, _ id: String) -> String { name.isEmpty ? "TRAINER \(trainerID(id))" : name }

/// Trainer ID as the game shows it (decimal, 5 digits).
func trainerID(_ hex: String) -> String { String(format: "%05d", Int(hex, radix: 16) ?? 0) }

/// Crystal text bytes → String (A–Z 0x80…, a–z 0xA0…, 0–9 0xF6…, space 0x7F, end 0x50).
func crystalText(_ hex: String) -> String {
    var out = ""; var i = hex.startIndex
    while i < hex.endIndex, let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), let b = UInt8(hex[i..<j], radix: 16) {
        i = j
        switch b {
        case 0x50: return out
        case 0x80...0x99: out.append(Character(UnicodeScalar(b - 0x80 + 65)))
        case 0xA0...0xB9: out.append(Character(UnicodeScalar(b - 0xA0 + 97)))
        case 0xF6...0xFF: out.append(Character(UnicodeScalar(b - 0xF6 + 48)))
        case 0x7F: out.append(" ")
        default: out.append("?")
        }
    }
    return out
}

struct BankData: Codable {
    var version = 1
    var accounts: [Account]
    var active: Int = 0
    var sentDecos: [Int]? = nil      // (v1.7) decorations with no save attached yet; moved to the first save seen
    var saves: [String: CrystalSave]? = nil   // by trainer ID: name + decorations it already has
    var lastSave: String? = nil      // (v1.8 only; migrated into the accounts)
    var healthAccount: UUID? = nil   // (v2.9 only; exercise now lands on the Calories card)
    var calories: Double? = nil      // Calories card balance (kcal), shared by every account: it's one body
    var calorieRate: Double? = nil   // kcal per W, from the iPhone (weight + stride); 0.8 until the first sync
    var cash: Int? = nil             // Cash card balance (PokéDollars), moved out of game saves; shared by every account
    var saveFiles: [SaveRef]? = nil  // save files used before (newest first)
    var cardOrder: [String]? = nil   // card grid order: debit, credit, calories, cash
    var pendingWrites: [String: PendingWrite]? = nil   // save edits not yet confirmed in the game, by save path
}

/// A change Watt Bank wrote into a save that also moved Debit money. If the cartridge later puts the old save back
/// (an EverDrive copies the game's memory over the file when it boots to its menu), the Debit side is undone.
struct PendingWrite: Codable {
    var account: UUID
    var beforeMoney: Int, beforeMom: Int?
    var afterMoney: Int? = nil, afterMom: Int? = nil
    var cashDelta: Int                 // what the Debit card gained (+) or lost (−) for this edit
}

/// A game save Watt Bank has moved money from.
struct SaveRef: Codable, Hashable { var path: String; var game: String; var trainer: String; var tid: String }

/// Answers from the bundled save helper (wbsave, built on PKHeX.Core: reads/writes money in every generation).
struct SaveInfo: Decodable {
    let ok: Bool
    var error: String? = nil
    var game: String? = nil, generation: Int? = nil, trainer: String? = nil
    var tid: UInt32? = nil, tidDigits: Int? = nil
    var money: Int? = nil, maxMoney: Int? = nil, momMoney: Int? = nil
    var moved: Int? = nil, after: Int? = nil
    var tidText: String { String(format: "%0\(tidDigits ?? 5)u", tid ?? 0) }
}

enum SaveTool {
    static var url: URL? { Bundle.main.url(forResource: "wbsave", withExtension: nil) }
    static func run(_ args: [String]) async -> SaveInfo {
        guard let exe = url else { return SaveInfo(ok: false, error: "save helper missing from the app") }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = exe; p.arguments = args
                let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: SaveInfo(ok: false, error: error.localizedDescription)); return }
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let line = String(decoding: out, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
                cont.resume(returning: (try? JSONDecoder().decode(SaveInfo.self, from: Data(line.utf8)))
                            ?? SaveInfo(ok: false, error: "no answer from the save helper"))
            }
        }
    }
    /// PKHeX version codes → game names.
    static func gameName(_ code: String) -> String {
        let names: [String: String] = [
            "RD": "Red", "GN": "Red/Green/Blue", "BU": "Blue", "YW": "Yellow", "RBY": "Red/Blue/Yellow",
            "GD": "Gold", "SI": "Silver", "C": "Crystal", "GS": "Gold/Silver", "GSC": "Gold/Silver/Crystal",
            "R": "Ruby", "S": "Sapphire", "E": "Emerald", "FR": "FireRed", "LG": "LeafGreen", "RS": "Ruby/Sapphire",
            "FRLG": "FireRed/LeafGreen", "CXD": "Colosseum/XD", "COLO": "Colosseum", "XD": "XD",
            "D": "Diamond", "P": "Pearl", "Pt": "Platinum", "DP": "Diamond/Pearl", "HG": "HeartGold", "SS": "SoulSilver",
            "HGSS": "HeartGold/SoulSilver", "BATREV": "Battle Revolution",
            "B": "Black", "W": "White", "B2": "Black 2", "W2": "White 2", "BW": "Black/White", "B2W2": "Black 2/White 2",
            "X": "X", "Y": "Y", "AS": "Alpha Sapphire", "OR": "Omega Ruby", "XY": "X/Y", "ORAS": "Omega Ruby/Alpha Sapphire",
            "SN": "Sun", "MN": "Moon", "US": "Ultra Sun", "UM": "Ultra Moon", "SM": "Sun/Moon", "USUM": "Ultra Sun/Ultra Moon",
            "GP": "Let's Go Pikachu", "GE": "Let's Go Eevee", "GG": "Let's Go",
            "SW": "Sword", "SH": "Shield", "SWSH": "Sword/Shield", "BD": "Brilliant Diamond", "SP": "Shining Pearl",
            "BDSP": "Brilliant Diamond/Shining Pearl", "PLA": "Legends: Arceus",
            "SL": "Scarlet", "VL": "Violet", "SV": "Scarlet/Violet", "ZA": "Legends: Z-A"]
        return names[code] ?? code
    }
}

@MainActor
final class Bank: ObservableObject {
    @Published var data: BankData
    private let url: URL
    private var bak: URL { url.appendingPathExtension("bak") }
    private var lateTimer: Timer?

    init() {
        let dir = demoDataDir.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Watt Bank", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("bank.json")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: url), let b = try? dec.decode(BankData.self, from: d) {
            data = b
        } else if let d = try? Data(contentsOf: url.appendingPathExtension("bak")),
                  let b = try? dec.decode(BankData.self, from: d) {
            data = b                                  // main file damaged: fall back to the backup
        } else {
            data = BankData(version: 2, accounts: [Account(name: "Main")])
        }
        if data.version < 2 {                       // v1 had 4 fixed accounts: drop the untouched extras
            data.accounts.removeAll { $0.balance == 0 && $0.history.isEmpty && ["Account 2", "Account 3", "Account 4"].contains($0.name) }
            if data.accounts.isEmpty { data.accounts = [Account(name: "Main")] }
            data.version = 2
        }
        data.active = min(max(0, data.active), data.accounts.count - 1)
        if demoDataDir == nil { DispatchQueue.main.async { self.startHealthSync(); self.startSaveWatch() } }
        lateTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkLate() }
        }
        DispatchQueue.main.async { self.checkLate() }
        for i in data.accounts.indices {
            if let id = data.accounts[i].crystalID { data.accounts[i].name = trainerName(data.accounts[i].crystalName ?? "", id) }
        }
        if data.version < 3 {                       // v1.8 kept saves globally: give the last one to the active account
            if let key = data.lastSave, let sv = data.saves?[key] {
                data.accounts[data.active].crystalID = key
                data.accounts[data.active].crystalName = sv.name
                data.accounts[data.active].decos = sv.decos
            } else if let d = data.sentDecos { data.accounts[data.active].decos = d }
            data.saves = nil; data.lastSave = nil; data.sentDecos = nil
            data.version = 3
            save()
        }
        if data.version < 4 {                       // v3.9 renamed the cards: Debit → Watt, Cash → Debit; reword old history
            for a in data.accounts.indices {
                let renamed = ISO8601DateFormatter().date(from: "2026-10-23T00:44:00Z") ?? Date()   // entries after this already use the new names
                for e in data.accounts[a].history.indices where data.accounts[a].history[e].date < renamed {
                    var t = data.accounts[a].history[e].kind
                    t = t.replacingOccurrences(of: "Debit", with: "\u{1}").replacingOccurrences(of: "Cash", with: "Debit")
                         .replacingOccurrences(of: "\u{1}", with: "Watt")
                    data.accounts[a].history[e].kind = t
                }
            }
            data.version = 4
            save()
        }
        if data.version < 5 {                       // v4.2: the Credit card and its loans are in PokéDollars
            for a in data.accounts.indices {
                guard var loans = data.accounts[a].loans else { continue }
                for k in loans.indices {
                    loans[k].principal = pdOf(loans[k].principal); loans[k].fee = pdOf(loans[k].fee)
                    loans[k].lateFee = pdOf(loans[k].lateFee); loans[k].paid = pdOf(loans[k].paid)
                }
                data.accounts[a].loans = loans
            }
            data.version = 5
            save()
        }
    }

    var current: Account { data.accounts[data.active] }
    var allTotal: Int { data.accounts.reduce(0) { $0 + $1.balance } }

    func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(data) else { return }
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {           // keep the previous save as a backup (two-slot save)
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        try? d.write(to: url, options: .atomic)
    }

    /// Deposit: watts pay off loans first (oldest first); the rest goes to Debit. Returns watts used on loans.
    @discardableResult
    func credit(_ w: Int, to target: Int? = nil, kind: String = "Deposit") -> Int {
        let a = target ?? data.active
        let paidPd = 0                                         // the Credit card is only paid with the Debit card
        let toLoans = 0
        let left = w
        data.accounts[a].balance += left
        data.accounts[a].totalIn += w
        data.accounts[a].history.insert(Entry(date: Date(),
            kind: toLoans > 0 ? "\(kind) (₽\(fmt(paidPd)) paid on Credit)" : kind, amount: w), at: 0)
        save()
        return toLoans
    }

    /// Pays up to `p` ₽ toward account `a`'s loans, oldest first (on-time payoffs raise the level). Returns ₽ used.
    @discardableResult
    func applyToLoans(_ a: Int, _ p: Int) -> Int {
        var left = p, used = 0
        var loans = data.accounts[a].loans ?? []
        for k in loans.indices where loans[k].owed > 0 && left > 0 {
            let pay = min(loans[k].owed, left)
            loans[k].paid += pay; left -= pay; used += pay
            if loans[k].owed == 0 && !loans[k].late && loans[k].counts {
                data.accounts[a].creditLevel = min(CreditRules.maxLevel, (data.accounts[a].creditLevel ?? 0) + 1)
            }
        }
        data.accounts[a].loans = loans.filter { $0.owed > 0 } + loans.filter { $0.owed == 0 }.suffix(20)
        return used
    }

    /// Pay account `to`'s Credit with account `from`'s Debit. Watts stay in the bank, so in/out totals don't change.
    func payCredit(from: Int, to: Int, _ p: Int) {
        let amt = min(p, pdValue(ofW: max(0, data.accounts[from].balance)), owed(data.accounts[to]))
        guard amt > 0 else { return }
        let usedPd = applyToLoans(to, amt)
        let w = min(data.accounts[from].balance, wCost(ofPd: usedPd))
        data.accounts[from].balance -= w
        let now = Date()
        if from == to {
            data.accounts[from].history.insert(Entry(date: now, kind: "Credit card payment (from Watt)", amount: -w, pd: usedPd), at: 0)
        } else {
            data.accounts[from].history.insert(Entry(date: now, kind: "Paid \(data.accounts[to].name)'s Credit", amount: -w, pd: usedPd), at: 0)
            data.accounts[to].history.insert(Entry(date: now, kind: "Credit paid by \(data.accounts[from].name): ₽\(fmt(usedPd))", amount: 0), at: 0)
        }
        save()
    }

    // ----- Apple Health, via the iPhone Shortcut "Watt Bank Health Sync"
    // The Shortcut saves WattBankHealth.txt ("rate <kcal per W>" + "yyyy-MM-dd <active kcal>" for 14 days) to
    // iCloud Drive/Shortcuts. Watt Bank pays it out with the same rules and the SAME ledger (WattBankEnergy.txt)
    // as the "Watt Bank Calories" Shortcut, so calories are never paid twice (cartridge or Mac).
    @Published var healthNote: String? = nil
    private var healthStamp: Date? = nil
    private var healthTimer: Timer?
    static let shortcutsDocs = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents")
    var calories: Double { data.calories ?? 0 }
    var calorieRate: Double { (data.calorieRate ?? 0) > 0 ? data.calorieRate! : 0.8 }
    /// Watts the Calories card can buy right now.
    var calorieWatts: Int { Int((calories / calorieRate + 1e-9).rounded(.down)) }

    // ----- The loaded save's in-game balances (Trainer and Mom cards), re-read whenever the file changes
    @Published var saveInfo: [String: SaveInfo] = [:]
    private var saveStamps: [String: Date] = [:]
    private var saveTimer: Timer?
    var currentSave: SaveInfo? { current.savePath.flatMap { saveInfo[$0] }.flatMap { $0.ok ? $0 : nil } }
    func linkSave(_ path: String, to a: Int, info: SaveInfo) {
        data.accounts[a].savePath = path
        saveInfo[path] = info
        saveStamps[path] = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        save()
        startSaveWatch()
    }
    func refreshSave(_ path: String, force: Bool = false) {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        if !force, saveInfo[path] != nil, stamp == saveStamps[path] { return }
        saveStamps[path] = stamp
        Task { @MainActor in
            let i = await SaveTool.run(["info", path])
            self.saveInfo[path] = i
            if i.ok { self.checkPending(path, i) }
        }
    }
    /// Remember a save edit that moved Debit money, so it can be undone if the game never sees it.
    func noteWrite(_ path: String, cashDelta: Int, on a: Int) {
        let b = saveInfo[path]
        var pw = data.pendingWrites ?? [:]
        if var old = pw[path] {                               // several edits before the game loads: keep the oldest "before"
            old.cashDelta += cashDelta; old.afterMoney = nil; old.afterMom = nil; pw[path] = old
        } else if let b, b.ok {
            pw[path] = PendingWrite(account: data.accounts[a].id, beforeMoney: b.money ?? 0, beforeMom: b.momMoney, cashDelta: cashDelta)
        }
        data.pendingWrites = pw; save()
    }
    private func checkPending(_ path: String, _ i: SaveInfo) {
        guard var pw = data.pendingWrites, var p = pw[path] else { return }
        let now = (i.money ?? 0, i.momMoney)
        if p.afterMoney == nil {                              // our own read right after writing
            p.afterMoney = now.0; p.afterMom = now.1; pw[path] = p
        } else if now.0 == p.afterMoney && now.1 == p.afterMom {
            return                                            // still our edit, not played yet
        } else if now.0 == p.beforeMoney && now.1 == p.beforeMom {
            // the cartridge wrote its old copy back: the game never got Watt Bank's edit → undo the Debit side
            if let a = data.accounts.firstIndex(where: { $0.id == p.account }) {
                data.accounts[a].cash = max(0, (data.accounts[a].cash ?? 0) - p.cashDelta)
                data.accounts[a].history.insert(Entry(date: Date(), kind: "Save edit didn't reach the game: undone", amount: 0, pd: -p.cashDelta), at: 0)
                healthNote = "The cartridge kept its old save, so Watt Bank undid ₽\(fmt(abs(p.cashDelta))) on Debit"
                NSSound(named: "Basso")?.play()
            }
            pw[path] = nil
        } else {
            pw[path] = nil                                    // the game has played since: the edit was used
        }
        data.pendingWrites = pw; save()
    }
    func startSaveWatch() {
        guard saveTimer == nil else { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { if let p = self?.current.savePath { self?.refreshSave(p) } }
        }
        // also re-read right away when Watt Bank comes to the front (e.g. after saving in the emulator)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if let p = self?.current.savePath { self?.refreshSave(p, force: true) } }
        }
        if let p = current.savePath { refreshSave(p) }
    }

    // ----- Card grid order
    var cardOrder: [String] {
        let all = ["debit", "credit", "calories", "cash", "trainer", "mom"]
        let o = (data.cardOrder ?? []).filter { all.contains($0) }
        return o + all.filter { !o.contains($0) }
    }
    /// The cards shown for the active account: Trainer appears once a save is loaded, Mom when that game has Mom's savings.
    var visibleCards: [String] {
        cardOrder   // Trainer and Mom always show; they're greyed out until a save (with Mom's savings) is loaded
    }
    func swapCards(_ a: String, _ b: String) {
        var o = cardOrder
        guard let i = o.firstIndex(of: a), let j = o.firstIndex(of: b) else { return }
        o.swapAt(i, j); data.cardOrder = o; save()
    }
    func moveCard(_ k: String, to j: Int) {
        let o = visibleCards
        guard o.indices.contains(j), let i = o.firstIndex(of: k), i != j else { return }
        swapCards(k, o[j])
    }

    // ----- Cash card (PokéDollars from game saves). Same rate used to price items: 0.83 W per ₽.
    static let cashRate = 0.83
    /// Cash belongs to each trainer (account); these read the active account.
    var cash: Int { current.cash ?? 0 }
    var cashWatts: Int { watts(forCash: cash) }
    func watts(forCash p: Int) -> Int { Int((Double(p) * Bank.cashRate + 1e-9).rounded(.down)) }
    func cashCost(_ w: Int) -> Int { min(cash, Int((Double(w) / Bank.cashRate - 1e-9).rounded(.up))) }

    /// The account for a save's trainer: same name and ID, or the active account if it isn't linked yet, else a new one.
    func accountForTrainer(name: String, tid: UInt32) -> (index: Int, isNew: Bool) {
        let same: (Account) -> Bool = { a in
            guard let h = a.crystalID, let v = UInt32(h, radix: 16) else { return false }
            return v == tid && (a.crystalName ?? "").caseInsensitiveCompare(name) == .orderedSame
        }
        if let i = data.accounts.firstIndex(where: same) { return (i, false) }
        let hex = String(tid, radix: 16, uppercase: true)
        let a = data.active
        if data.accounts[a].crystalID == nil {
            data.accounts[a].crystalID = hex; data.accounts[a].crystalName = name
            data.accounts[a].name = trainerName(name, hex); data.accounts[a].decos = data.accounts[a].decos ?? []
            save(); return (a, false)
        }
        data.accounts.append(Account(name: trainerName(name, hex), crystalID: hex, crystalName: name, decos: []))
        save()
        return (data.accounts.count - 1, true)
    }
    func addCash(_ p: Int, from ref: SaveRef, on a: Int) {
        noteWrite(ref.path, cashDelta: p, on: a)
        data.accounts[a].cash = (data.accounts[a].cash ?? 0) + p
        data.accounts[a].history.insert(Entry(date: Date(), kind: "Debit ← \(SaveTool.gameName(ref.game))", amount: 0, pd: p), at: 0)
        healthNote = "+₽\(fmt(p)) from \(SaveTool.gameName(ref.game)) → \(data.accounts[a].name)"
        save()
    }
    /// Watt card → Debit card (PokéDollars) at the same 0.83 W per ₽.
    var cashFromWatts: Int { Int((Double(max(0, current.balance)) / Bank.cashRate + 1e-9).rounded(.down)) }
    func wattCost(_ p: Int) -> Int { Int((Double(p) * Bank.cashRate - 1e-9).rounded(.up)) }
    func wattsToCash(_ p: Int, on a: Int) {
        let w = wattCost(p)
        guard p > 0, w <= data.accounts[a].balance else { return }
        data.accounts[a].balance -= w
        data.accounts[a].cash = (data.accounts[a].cash ?? 0) + p
        data.accounts[a].history.insert(Entry(date: Date(), kind: "Watt → Debit", amount: -w, pd: p), at: 0)
        save()
    }
    /// Cash put back into the loaded save (Trainer or Mom card).
    func cashToSave(_ p: Int, card: String, game: String, path: String, on a: Int) {
        noteWrite(path, cashDelta: -p, on: a)
        data.accounts[a].cash = max(0, (data.accounts[a].cash ?? 0) - p)
        data.accounts[a].history.insert(Entry(date: Date(), kind: "Debit → \(card) (\(SaveTool.gameName(game)))", amount: 0, pd: -p), at: 0)
        save()
    }
    /// PokéDollars that left a save straight into Debit (0.83 W per ₽).
    func saveToDebit(_ p: Int, from label: String, on a: Int) {
        let w = watts(forCash: p)
        data.accounts[a].balance += w
        data.accounts[a].totalIn += w
        data.accounts[a].history.insert(Entry(date: Date(), kind: "\(label) → Watt", amount: w, pd: -p), at: 0)
        save()
    }
    func rememberSave(_ ref: SaveRef) {
        var list = (data.saveFiles ?? []).filter { $0.path != ref.path }
        list.insert(ref, at: 0); data.saveFiles = Array(list.prefix(12)); save()
    }
    func cashToDebit(_ w: Int, on a: Int) {
        let w = min(w, cashWatts); guard w > 0 else { return }
        let cost = cashCost(w)
        data.accounts[a].cash = cash - cost
        data.accounts[a].balance += w
        data.accounts[a].totalIn += w
        data.accounts[a].history.insert(Entry(date: Date(), kind: "Debit → Watt", amount: w, pd: -cost), at: 0)
        save()
    }
    func cashToCredit(_ p: Int, on a: Int) {
        let p = min(p, data.accounts[a].cash ?? 0, owed(data.accounts[a])); guard p > 0 else { return }
        let used = applyToLoans(a, p)
        data.accounts[a].cash = (data.accounts[a].cash ?? 0) - used
        data.accounts[a].history.insert(Entry(date: Date(), kind: "Debit → Credit card payment", amount: 0, pd: -used), at: 0)
        save()
    }

    /// Calories card → this account's Debit (straight to Debit; loans aren't touched).
    func caloriesToDebit(_ w: Int, on a: Int) {
        let w = min(w, calorieWatts); guard w > 0 else { return }
        let kcal = Double(w) * calorieRate
        data.calories = max(0, calories - kcal)
        data.accounts[a].balance += w
        data.accounts[a].totalIn += w
        data.accounts[a].history.insert(Entry(date: Date(), kind: "Calories → Watt (\(fmt(Int(kcal.rounded()))) kcal)", amount: w), at: 0)
        save()
    }
    func startHealthSync() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkHealth() }
        }
        DispatchQueue.main.async { self.checkHealth() }
    }

    func checkHealth(force: Bool = false) {
        let hu = Self.shortcutsDocs.appendingPathComponent("WattBankHealth.txt")
        let lu = Self.shortcutsDocs.appendingPathComponent("WattBankEnergy.txt")
        try? FileManager.default.startDownloadingUbiquitousItem(at: hu)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: hu.path),
              let stamp = attrs[.modificationDate] as? Date else { return }
        if !force, let last = healthStamp, last >= stamp { return }
        healthStamp = stamp
        guard let text = try? String(contentsOf: hu, encoding: .utf8) else { return }
        var rate = 0.0
        var days: [(String, Int)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ")
            if f.count == 2, f[0] == "rate" { rate = Double(f[1]) ?? 0 }
            else if f.count == 2, f[0].count == 10, let v = Int(f[1]) ?? Double(f[1]).map({ Int($0) }) { days.append((String(f[0]), v)) }
        }
        guard rate > 0, !days.isEmpty else { return }
        // shared ledger
        var seen: [String: Int] = [:]
        var carry = 0.0
        if let l = try? String(contentsOf: lu, encoding: .utf8) {
            for line in l.split(whereSeparator: \.isNewline) {
                let f = line.split(separator: " ")
                if f.count == 2, f[0] == "carry" { carry = Double(f[1]) ?? 0 }
                else if f.count == 2, let v = Int(f[1]) { seen[String(f[0])] = v }
            }
        }
        var avail = carry, kcalNew = 0
        for (d, v) in days {
            let diff = v - (seen[d] ?? 0)
            if Double(diff) > 0.5 { avail += Double(diff); kcalNew += diff }
        }
        guard kcalNew > 0 else { return }                       // nothing new since the last sync
        // Everything new (plus the cartridge Shortcut's leftover carry) moves onto the Calories card,
        // and the ledger marks it as claimed so the flashlight Shortcut won't pay it again.
        var out = days.map { "\($0.0) \($0.1)" }.joined(separator: "\n")
        out += "\ncarry 0.00"
        guard (try? out.write(to: lu, atomically: true, encoding: .utf8)) != nil else { return }
        data.calories = calories + avail
        data.calorieRate = rate
        save()
        healthNote = "+\(fmt(kcalNew)) kcal from exercise"
        NSSound(named: "Glass")?.play()
    }

    // ----- Credit
    func creditLevel(_ a: Account) -> Int { min(CreditRules.maxLevel, max(0, a.creditLevel ?? 0)) }
    func creditLimit(_ a: Account) -> Int { CreditRules.baseLimit << creditLevel(a) }
    func owed(_ a: Account) -> Int { (a.loans ?? []).reduce(0) { $0 + $1.owed } }
    /// Largest purchase Credit can cover right now (the 10% fee must fit under the limit too).
    /// ₽ you can still borrow (the 10% fee has to fit under the limit too).
    func maxBorrow(_ a: Account) -> Int { max(0, Int(Double(creditLimit(a) - owed(a)) / (1 + CreditRules.fee))) }
    /// The same, as watts you can spend on credit (withdraw, gifts, Watt card top-up).
    func maxBorrowW(_ a: Account) -> Int { wValue(ofPd: maxBorrow(a)) }
    func nextDue(_ a: Account) -> Loan? { (a.loans ?? []).filter { $0.owed > 0 }.min { $0.due < $1.due } }

    /// Pay with Credit: the watts leave, Debit stays the same, and a loan (with its fee) is opened.
    func borrow(on i: Int, _ w: Int, _ label: String) {
        let a = data.accounts[i]
        let p = pdCost(ofW: w)                                   // the loan is in ₽
        let fee = Int((Double(p) * CreditRules.fee).rounded(.up))
        let loan = Loan(date: Date(), what: label, principal: p, fee: fee,
                        due: Date().addingTimeInterval(CreditRules.days * 86_400),
                        counts: Double(p) >= Double(creditLimit(a)) * CreditRules.levelUpShare)
        data.accounts[i].loans = (data.accounts[i].loans ?? []) + [loan]
        data.accounts[i].totalOut += w
        data.accounts[i].history.insert(Entry(date: Date(), kind: "\(label) · Credit (owe ₽\(fmt(p + fee)))", amount: -w), at: 0)
        save()
    }

    /// Once a loan passes its due date: one late fee, one level down. Never anything more.
    func checkLate() {
        var changed = false
        for i in data.accounts.indices {
            guard var loans = data.accounts[i].loans else { continue }
            for k in loans.indices where loans[k].owed > 0 && !loans[k].late && Date() > loans[k].due {
                loans[k].late = true
                loans[k].lateFee = Int((Double(loans[k].principal) * CreditRules.lateFee).rounded(.up))
                data.accounts[i].creditLevel = max(0, (data.accounts[i].creditLevel ?? 0) - 1)
                data.accounts[i].history.insert(Entry(date: Date(), kind: "Late: +\(fmt(loans[k].lateFee)) W added to loan, credit level down", amount: 0), at: 0)
                changed = true
            }
            data.accounts[i].loans = loans
        }
        if changed { save() }
    }

    func debit(_ w: Int) {
        let a = data.active
        data.accounts[a].balance -= w
        data.accounts[a].totalOut += w
        data.accounts[a].history.insert(Entry(date: Date(), kind: "Withdraw", amount: -w), at: 0)
        save()
    }

    func spend(_ w: Int, _ label: String) {
        let a = data.active
        data.accounts[a].balance -= w
        data.accounts[a].totalOut += w
        data.accounts[a].history.insert(Entry(date: Date(), kind: label, amount: -w), at: 0)
        save()
    }

    // ----- one Crystal save per account
    func saveLabel(_ a: Account) -> String? {
        guard let id = a.crystalID else { return nil }
        return "\(a.crystalName ?? "?") · ID \(trainerID(id))"
    }
    func decoAlreadySent(_ code: Int) -> Bool { current.decos?.contains(code) ?? false }
    func toggleDecoOwned(_ code: Int) {
        var d = current.decos ?? []
        if d.contains(code) { d.removeAll { $0 == code } } else { d.append(code) }
        data.accounts[data.active].decos = d
        save()
    }
    func addDeco(_ i: Int, _ code: Int) {
        if !(data.accounts[i].decos ?? []).contains(code) { data.accounts[i].decos = (data.accounts[i].decos ?? []) + [code]; save() }
    }
    /// A gift reached save `id`. Returns the account that pays for it:
    /// the active account if it is (or becomes) linked to that save; otherwise the account linked to it;
    /// otherwise a brand-new account for that save (starting at 0, so the gift puts it in debt).
    func accountForSave(id: String, name: String) -> (index: Int, isNew: Bool) {
        let a = data.active
        if data.accounts[a].crystalID == id || (data.accounts[a].crystalID == nil && !data.accounts.contains { $0.crystalID == id }) {
            data.accounts[a].crystalID = id; data.accounts[a].crystalName = name
            data.accounts[a].name = trainerName(name, id); save()
            return (a, false)
        }
        if let j = data.accounts.firstIndex(where: { $0.crystalID == id }) {
            data.accounts[j].crystalName = name; data.accounts[j].name = trainerName(name, id); save()
            return (j, false)
        }
        data.accounts.append(Account(name: trainerName(name, id), crystalID: id, crystalName: name, decos: []))
        save()
        return (data.accounts.count - 1, true)
    }
    func spend(on i: Int, _ w: Int, _ label: String) {
        data.accounts[i].balance -= w
        data.accounts[i].totalOut += w
        data.accounts[i].history.insert(Entry(date: Date(), kind: label, amount: -w), at: 0)
        save()
    }

    func rename(_ i: Int, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        data.accounts[i].name = String(n.prefix(16))
        save()
    }

    func select(_ i: Int) {
        guard data.accounts.indices.contains(i) else { return }
        data.active = i; save()
        if let p = data.accounts[i].savePath { refreshSave(p, force: true) }
    }

    /// Adds an account, selects it and returns its index.
    func addAccount() -> Int {
        let names = Set(data.accounts.map { $0.name })
        var n = 1
        while names.contains("NEW TRAINER \(n)") { n += 1 }
        data.accounts.append(Account(name: "NEW TRAINER \(n)"))   // renamed to the trainer on its first GSC link
        data.active = data.accounts.count - 1
        save()
        return data.active
    }

    /// Deletes an empty account (never the last one).
    func deleteAccount(_ i: Int) {
        guard data.accounts.count > 1, data.accounts.indices.contains(i), data.accounts[i].balance == 0 else { return }   // debt must be paid first
        data.accounts.remove(at: i)
        if data.active > i || data.active >= data.accounts.count { data.active = max(0, data.active - 1) }
        save()
    }

    /// Moves watts between accounts (not counted as Pikachu in/out).
    /// Credit → this account's Debit: a loan (10% fee, 7 days) whose watts land on Debit.
    func cashAdvance(on i: Int, _ w: Int) {
        let w = min(w, maxBorrowW(data.accounts[i])); guard w > 0 else { return }
        let a = data.accounts[i]
        let p = min(pdCost(ofW: w), maxBorrow(a))
        let fee = Int((Double(p) * CreditRules.fee).rounded(.up))
        let loan = Loan(date: Date(), what: "Credit → Watt", principal: p, fee: fee,
                        due: Date().addingTimeInterval(CreditRules.days * 86_400),
                        counts: Double(p) >= Double(creditLimit(a)) * CreditRules.levelUpShare)
        data.accounts[i].loans = (data.accounts[i].loans ?? []) + [loan]
        data.accounts[i].balance += w
        data.accounts[i].history.insert(Entry(date: Date(), kind: "Credit → Watt (owe ₽\(fmt(p + fee)))", amount: w), at: 0)
        save()
    }
    func move(_ w: Int, from: Int, to: Int) {
        guard w > 0, from != to, data.accounts.indices.contains(from), data.accounts.indices.contains(to),
              data.accounts[from].balance >= w else { return }
        let now = Date()
        data.accounts[from].balance -= w
        data.accounts[to].balance += w
        data.accounts[from].history.insert(Entry(date: now, kind: "Moved to \(data.accounts[to].name)", amount: -w), at: 0)
        data.accounts[to].history.insert(Entry(date: now, kind: "Moved from \(data.accounts[from].name)", amount: w), at: 0)
        save()
    }
}

// MARK: - Serial link to the ESP32 IR head

@MainActor
final class IRLink: ObservableObject {
    @Published var port: String? = nil
    @Published var ready = false
    var onEvent: ((String) -> Void)?
    private var fd: Int32 = -1
    private var timer: Timer?
    private var openedAt = Date()
    var lastHeard = Date()
    private(set) var paused = false
    @Published var silent = false            // a board is plugged in but never said #READY: no Watt Bank firmware on it
    @Published var stuck = false             // the USB link keeps repeating the same line: needs an unplug/replug
    /// Lets go of the port (for the firmware installer) and stops reconnecting until resume().
    /// Lets go of the port and calls `then` once it is really closed (or after 3 s, whichever comes first).
    func pause(then: @escaping () -> Void = {}) {
        paused = true
        var called = false
        let once = { if !called { called = true; then() } }
        if let c = reader { c.onClosed = once; close() } else { close(); once() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once() }
    }
    func resume() { paused = false; openedAt = Date() }
    /// Shared between the main thread and the reader thread of one open port.
    final class Reader: @unchecked Sendable {
        private let lock = NSLock(); private var _stop = false
        var onClosed: (() -> Void)?
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stop }
        func stop() { lock.lock(); _stop = true; lock.unlock() }
    }
    private var reader: Reader?

    init() {
        if demoDataDir != nil { return }                 // demo/screenshot mode: never touch the USB port
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
        DispatchQueue.main.async { self.tick() }
    }

    static func findPort() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names.sorted().first {
            $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.SLAB_USBtoUART") || $0.hasPrefix("cu.wchusbserial")
        }.map { "/dev/" + $0 }
    }

    private func tick() {
        if paused { return }
        silent = fd >= 0 && !ready && Date().timeIntervalSince(openedAt) > 6
        if fd < 0 {
            if let p = Self.findPort() { open(p) }
        } else {
            if let p = port, !FileManager.default.fileExists(atPath: p) { close(); return }
            if !ready && Date().timeIntervalSince(openedAt) > 1.0 { send("?") }
        }
    }

    private func open(_ p: String) {
        let f = Darwin.open(p, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard f >= 0 else { return }
        var t = termios()
        tcgetattr(f, &t)
        cfmakeraw(&t)
        cfsetspeed(&t, speed_t(B115200))
        t.c_cflag |= tcflag_t(CLOCAL | CREAD)
        t.c_cflag &= ~tcflag_t(HUPCL)
        t.c_lflag &= ~tcflag_t(ECHO | ECHOE | ECHOK | ECHONL | ICANON | ISIG | IEXTEN)   // never echo back to the board
        withUnsafeMutableBytes(of: &t.c_cc) { cc in cc[Int(VMIN)] = 0; cc[Int(VTIME)] = 1 }   // reads wake every 0.1 s
        guard tcsetattr(f, TCSANOW, &t) == 0 else { Darwin.close(f); return }
        tcflush(f, TCIOFLUSH)                         // drop anything left over from before (installer, old session)
        _ = fcntl(f, F_SETFL, 0)                      // blocking reads (with the 0.1 s timeout) on the reader thread
        fd = f; port = p; ready = false; openedAt = Date()
        let ctl = Reader(); reader = ctl
        let thread = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 512)
            var line = [UInt8]()
            var lastLine = "", lastAt = Date.distantPast, repeats = 0
            // the reader thread alone closes the port, without waiting for unsent bytes, so nothing can hang the app
            func release() { tcflush(f, TCIOFLUSH); _ = fcntl(f, F_SETFL, O_NONBLOCK); Darwin.close(f) }
            while true {
                if ctl.stopped { release(); DispatchQueue.main.async { ctl.onClosed?(); ctl.onClosed = nil }; return }
                let n = read(f, &buf, buf.count)
                if n == 0 { continue }
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    release(); DispatchQueue.main.async { self?.lost(f); ctl.onClosed?(); ctl.onClosed = nil }; return
                }
                for b in buf[0..<n] {
                    if b == 10 {
                        let s = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        line.removeAll()
                        guard !s.isEmpty else { continue }
                        // a board stuck repeating itself must not flood the app: same line again within 0.25 s is dropped
                        let now = Date()
                        if s == lastLine && now.timeIntervalSince(lastAt) < 0.25 && !s.hasPrefix("#IR ") {
                            repeats += 1; lastAt = now
                            if repeats == 50 { DispatchQueue.main.async { self?.logLine("(board repeating \"\(s)\", ignoring repeats)") } }
                            if repeats == 2000 { DispatchQueue.main.async { self?.stuck = true } }
                            continue
                        }
                        lastLine = s; lastAt = now; repeats = 0
                        DispatchQueue.main.async { self?.handle(s) }
                    } else if b != 13 && line.count < 4000 { line.append(b) }
                }
            }
        }
        thread.start()
    }

    private func lost(_ f: Int32) { if f == fd { reader = nil; fd = -1; close() } }

    private func close() {
        if let c = reader { c.stop(); reader = nil }        // the reader thread closes the fd within 0.1 s
        else if fd >= 0 { let f = fd; DispatchQueue.global().async { Darwin.close(f) } }
        fd = -1; port = nil; ready = false; silent = false; stuck = false
        onEvent?("#DISCONNECTED")
    }

    private lazy var logURL: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Watt Bank.log")
        if !FileManager.default.fileExists(atPath: u.path) { FileManager.default.createFile(atPath: u.path, contents: nil) }
        return u
    }()
    func logLine(_ s: String) {
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]) as? Int, size > 5_000_000 {
            let old = logURL.deletingPathExtension().appendingPathExtension("old.log")      // keep one previous log, max ~5 MB each
            try? FileManager.default.removeItem(at: old); try? FileManager.default.moveItem(at: logURL, to: old)
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write("\(stamp) \(s)\n".data(using: .utf8)!); try? h.close() }
    }

    // live light meter (idle IR head)
    @Published var irPulses = 0
    @Published var irWidest = 0
    @Published var irSeen = Date.distantPast

    private func handle(_ s: String) {
        if s.hasPrefix("#IR ") {                     // ~10/s while light is seen: not logged
            let f = s.split(separator: " ")
            if f.count >= 3 { irPulses = Int(f[1]) ?? 0; irWidest = Int(f[2]) ?? 0; irSeen = Date() }
            return
        }
        logLine("< " + s)
        lastHeard = Date()
        if s.hasPrefix("#READY") { ready = true }
        if s.hasPrefix("#") { onEvent?(s) }
    }

    func send(_ s: String) {
        logLine("> " + s.trimmingCharacters(in: .whitespacesAndNewlines))
        guard fd >= 0 else { return }
        let bytes = Array(s.utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}

// MARK: - Transfers

enum Mode { case deposit, withdraw, gift }

struct Prompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let yes: String
    let no: String
    let onYes: () -> Void
    let onNo: () -> Void
}

@MainActor
final class Session: ObservableObject {
    let bank: Bank
    let link: IRLink
    @Published var mode: Mode? = nil
    @Published var running = false
    @Published var linked = false
    @Published var step = 0
    @Published var status = ""
    @Published var result: String? = nil
    @Published var resultGood = false
    @Published var prompt: Prompt? = nil
    @Published var partIndex = 0
    @Published var parts: [Int] = []
    @Published var sentSoFar = 0
    @Published var received: [Int] = []      // deposits in the current deposit window
    @Published var lastNote: String? = nil

    private var watchdog: Timer?
    private var startedAt = Date()
    private var cancelAsked: Date? = nil
    private var gotWatts: Int? = nil

    init(bank: Bank, link: IRLink) {
        self.bank = bank; self.link = link
        link.onEvent = { [weak self] e in self?.event(e) }
        watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.checkStuck() }
        }
    }

    /// Never leave the window stuck: the IR head always answers within ~62 s of a start, and a
    /// linked transfer never goes 10 s without a message. If it does, give up on the app side.
    private func checkStuck() {
        guard running else { return }
        let quiet = Date().timeIntervalSince(link.lastHeard)
        let total = Date().timeIntervalSince(startedAt)
        if let c = cancelAsked, Date().timeIntervalSince(c) > 3 { cancelAsked = nil; giveUp("Cancelled."); return }
        if (linked && quiet > 10) || total > 75 { giveUp("The IR head stopped answering.") }
    }

    private func giveUp(_ why: String) {
        running = false
        link.logLine("! app gave up: \(why) (mode \(String(describing: mode)), step \(step))")
        if mode == .deposit {
            if let w = gotWatts { lateDeposit(w, why) }
            else if why == "Cancelled." { endDeposits() }
            else if received.isEmpty { finish("\(why) Nothing changed.", good: false) }
            else { lastNote = why; endDeposits() }
        } else if mode == .gift {
            if why == "Cancelled." && step < 4 { close() }
            else if step >= 4, let g = gift {
                prompt = Prompt(title: why, message: "Did GSC say it received \(g.name)?",
                                yes: "Yes, charge \(fmt(self.giftCost(g))) W", no: "No",
                                onYes: { [weak self] in self?.giftAccepted(g) },
                                onNo: { [weak self] in self?.finish("No watts charged.", good: false) })
            } else { finish("\(why) No watts charged.", good: false) }
        } else {
            partialOrClose(step >= 4 ? "\(why) Check the Pikachu: the watts may or may not have arrived. Nothing was taken from this account for that part." : "\(why) Nothing changed.")
        }
    }

    // ----- Mystery Gift
    @Published var gift: Gift? = nil
    var anotherSave = false
    var payCredit = false            // this withdraw / gift is paid with Credit
    var giftTarget: (index: Int, isNew: Bool)? = nil          // picker's S toggle: sending to a save other than the last one linked
    func beginGift(_ g: Gift) {
        if g.isDeco && bank.decoAlreadySent(g.code) && !anotherSave { return }   // that save has it: never send
        mode = .gift; gift = g; result = nil; prompt = nil
        startedAt = Date(); link.lastHeard = Date(); cancelAsked = nil
        running = true; linked = false; step = 0
        status = "Calling Pokémon GSC…"
        link.send("g\(g.isDeco ? 1 : 0),\(g.code),\(g.isDeco ? decoFallback(g).code : 0)\n")
    }
    func giftCost(_ g: Gift) -> Int { g.price }

    private func giftAccepted(_ g: Gift) {
        let t = giftTarget ?? (bank.data.active, false)
        giftTarget = nil
        let acct = bank.data.accounts[t.index]
        let save = acct.crystalName ?? "your save"
        var text: String
        if g.isDeco {
            let fb = decoFallback(g)
            if (acct.decos ?? []).contains(g.code) {     // that save already had it → Crystal gave the fallback item
                chargeGift(t.index, fb.price, "Gift: \(fb.name) (for \(g.name), already in room)")
                text = "\(save)'s room already had the \(g.name), so GSC got a \(fb.name) instead (−\(fmt(fb.price)) W). Pick it up from the deliveryman at any Pokémon Center 2F."
            } else {
                chargeGift(t.index, g.price, "Gift: \(g.name)")
                bank.addDeco(t.index, g.code)
                text = "\(g.name) sent to \(save)'s room (−\(fmt(g.price)) W). If it already had one from somewhere else, GSC gives a \(fb.name) instead — pick it up at a Pokémon Center 2F."
            }
        } else {
            chargeGift(t.index, g.price, "Gift: \(g.name)")
            text = "\(g.name) sent to \(save) (−\(fmt(g.price)) W). Pick it up from the deliveryman at any Pokémon Center 2F."
        }
        if t.index != bank.data.active {
            let a = bank.data.accounts[t.index]
            text += t.isNew
                ? "\n\nThis was a different save (\(bank.saveLabel(a) ?? "")), so it got its own new account, \u{201C}\(a.name)\u{201D}, which paid for it and is now at \(fmt(a.balance)) W. \(bank.current.name) wasn't charged. Press P on that account to pay its debt from another account."
                : "\n\nThis was \u{201C}\(a.name)\u{201D}'s save (\(bank.saveLabel(a) ?? "")), so that account paid for it (now \(fmt(a.balance)) W). \(bank.current.name) wasn't charged."
        }
        finish(text, good: true)
    }

    // ----- start / cancel
    func beginDeposit() {
        mode = .deposit; result = nil; prompt = nil; received = []; lastNote = nil
        startDeposit()
    }
    private func startDeposit() {
        gotWatts = nil; startedAt = Date(); link.lastHeard = Date(); cancelAsked = nil
        running = true; linked = false; step = 0; result = nil
        status = "Waiting for the Pikachu…"
        link.send("d")
    }

    func beginWithdraw(_ total: Int) {
        mode = .withdraw; result = nil; prompt = nil
        var p: [Int] = []; var left = total
        while left > 0 { let x = min(maxPerTransfer, left); p.append(x); left -= x }
        parts = p; partIndex = 0; sentSoFar = 0
        startPart()
    }
    private func startPart() {
        startedAt = Date(); link.lastHeard = Date(); cancelAsked = nil
        running = true; linked = false; step = 0; result = nil
        status = parts.count > 1 ? "Part \(partIndex + 1) of \(parts.count): calling the Pikachu…" : "Calling the Pikachu…"
        link.send("w\(parts[partIndex])\n")
    }

    func cancel() {
        if running { link.send("x"); cancelAsked = Date() } else { close() }
    }
    func close() { mode = nil; running = false; prompt = nil; result = nil }

    // ----- events from the IR head
    private func event(_ e: String) {
        let f = e.split(separator: " ").map(String.init)
        guard let head = f.first else { return }
        let arg = f.count > 1 ? f[1] : ""
        let num = f.count > 2 ? Int(f[2]) : (f.count > 1 ? Int(f[1]) : nil)
        switch head {
        case "#READY":
            if running { running = false; giveUp("The IR head restarted.") }
        case "#DISCONNECTED":
            if running { running = false; finish("The IR head was unplugged.", good: false) }
        case "#GOT":
            gotWatts = Int(arg)
        case "#LINK":
            linked = true; status = "Linked! Hold still…"
        case "#STEP":
            step = Int(arg) ?? step
            if step >= 4 { status = "Almost done…" }
        case "#DEPOSIT":
            running = false
            switch arg {
            case "OK":
                let w = num ?? 0
                let toLoans = bank.credit(w); received.append(w)
                lastNote = toLoans > 0 ? "\(fmt(toLoans)) W of that went to Credit (loans)." : nil
                NSSound(named: "Glass")?.play()
                rearm()                                     // keep listening: batches arrive one part at a time
            case "CANCEL": endDeposits()
            case "TIMEOUT": rearm()
            case "NOTPIKA": lastNote = "Something that isn't a Pikachu 2 tried to link. Nothing changed."; rearm()
            case "BADDATA": lastNote = "Received an unreadable amount. Nothing changed."; rearm()
            case "FAIL" where f.count > 2 && f[2] == "LATE":
                lateDeposit(f.count > 3 ? Int(f[3]) ?? 0 : 0, "The link broke near the end.")
            default: lastNote = "A link broke before any watts moved. Nothing changed."; NSSound(named: "Basso")?.play(); rearm()
            }
        case "#GIFT":
            running = false
            guard let g = gift else { break }
            switch arg {
            case "OK":
                giftTarget = nil
                if f.count > 4 { giftTarget = bank.accountForSave(id: f[3], name: crystalText(f[4])) }
                if let w = num, w != 0 {
                    finish("GSC already has a gift waiting. Pick it up from the deliveryman at a Pokémon Center 2F, then send again. No watts charged.", good: false)
                } else { giftAccepted(g) }
            case "CANCEL": close()
            case "TIMEOUT": finish("GSC didn't answer. In GSC choose MYSTERY GIFT on the main menu and press A, then try again.", good: false)
            case "NOTGAME": finish("That's a Pikachu, not a game. Nothing changed.", good: false)
            case "FAIL" where f.count > 2 && f[2] == "LATE":
                prompt = Prompt(title: "Link broke near the end",
                                message: "The gift card reached GSC, then the link broke. Did GSC say it received \(g.name)?",
                                yes: "Yes, charge \(fmt(self.giftCost(g))) W", no: "No",
                                onYes: { [weak self] in self?.giftAccepted(g) },
                                onNo: { [weak self] in self?.finish("No watts charged.", good: false) })
            default: finish("The link broke before the gift was sent. No watts charged — try again.", good: false)
            }
        case "#WITHDRAW":
            running = false
            switch arg {
            case "OK":
                let w = num ?? 0
                chargeWithdraw(w); sentSoFar += w
                nextPartOrFinish()
            case "CANCEL": partialOrClose("Cancelled.")
            case "TIMEOUT": partialOrClose("No Pikachu answered. Set it to Watts → Receive and try again.")
            case "NOTPIKA": partialOrClose("That isn't a Pikachu 2. Nothing was sent.")
            case "FAIL" where f.count > 2 && f[2] == "LATE":
                let w = f.count > 3 ? Int(f[3]) ?? 0 : 0
                prompt = Prompt(title: "Link broke near the end",
                                message: "\(fmt(w)) W were sent, then the link broke. Did the Pikachu's watts go up by \(fmt(w))?",
                                yes: "Yes, it got them", no: "No",
                                onYes: { [weak self] in
                                    guard let self else { return }
                                    self.chargeWithdraw(w); self.sentSoFar += w; self.prompt = nil; self.nextPartOrFinish() },
                                onNo: { [weak self] in self?.partialOrClose("Nothing was taken from this account for that part.") })
            default: partialOrClose("The link broke before any watts moved. Nothing changed — try again.")
            }
        default: break
        }
    }

    private func lateDeposit(_ w: Int, _ why: String) {
        running = false
        prompt = Prompt(title: why,
                        message: "The Pikachu sent \(fmt(w)) W, then the link broke. Did the Pikachu's watts go down by \(fmt(w))?",
                        yes: "Yes, add \(fmt(w)) W", no: "No",
                        onYes: { [weak self] in guard let self else { return }
                            self.bank.credit(w); self.received.append(w); self.prompt = nil; self.rearm() },
                        onNo: { [weak self] in guard let self else { return }
                            self.lastNote = "\(fmt(w)) W not added."; self.prompt = nil; self.rearm() })
    }

    private func rearm() { if mode == .deposit { startDeposit() } }

    /// Deposit window closed by the user: summarize what came in, or just close.
    private func endDeposits() {
        running = false
        if received.isEmpty { close() }
        else {
            let t = received.reduce(0, +)
            finish(received.count == 1 ? "+\(fmt(t)) W deposited" : "+\(fmt(t)) W deposited in \(received.count) transfers", good: true)
        }
    }

    private func chargeWithdraw(_ w: Int) {
        if payCredit { bank.borrow(on: bank.data.active, w, "Withdraw") } else { bank.debit(w) }
    }
    private func chargeGift(_ i: Int, _ w: Int, _ label: String) {
        if payCredit && i == bank.data.active { bank.borrow(on: i, w, label) } else { bank.spend(on: i, w, label) }
    }

    private func nextPartOrFinish() {
        if partIndex + 1 < parts.count {
            let next = parts[partIndex + 1]
            prompt = Prompt(title: "Part \(partIndex + 1) of \(parts.count) done",
                            message: "Sent \(fmt(sentSoFar)) W so far. Set the Pikachu to Watts → Receive again for the next \(fmt(next)) W.",
                            yes: "Send next part", no: "Stop here",
                            onYes: { [weak self] in guard let self else { return }
                                self.prompt = nil; self.partIndex += 1; self.startPart() },
                            onNo: { [weak self] in guard let self else { return }
                                self.finish("−\(fmt(self.sentSoFar)) W sent to the Pikachu", good: true) })
        } else {
            finish("−\(fmt(sentSoFar)) W sent to the Pikachu", good: true)
        }
    }

    private func partialOrClose(_ why: String) {
        if sentSoFar > 0 { finish("\(why)\nSent \(fmt(sentSoFar)) W before that.", good: false) }
        else if why == "Cancelled." { close() }
        else { finish(why, good: false) }
    }

    func finish(_ text: String, good: Bool) {
        running = false; prompt = nil; result = text; resultGood = good
        if good { NSSound(named: "Glass")?.play() } else { NSSound(named: "Basso")?.play() }
    }
}

// MARK: - Look

extension Color {
    static let wbBG = Color(red: 0.93, green: 0.93, blue: 0.95)
    static let wbCard = Color.white
    static let wbInk = Color(red: 0.08, green: 0.08, blue: 0.1)
    static let wbSub = Color(red: 0.42, green: 0.42, blue: 0.47)
    static let wbGreen = Color(red: 0.12, green: 0.62, blue: 0.27)
    static let wbRed = Color(red: 0.82, green: 0.18, blue: 0.18)
    static let wbOrange = Color(red: 0.96, green: 0.55, blue: 0.08)
    static let wbBlue = Color(red: 0.22, green: 0.52, blue: 0.95)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.wbCard))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

/// "IR head ready" badge that lights up when the IR head sees light — a quick aim/strength test.
/// Strong = pulses long enough to link (the same 150 µs rule the head uses for deposits).
struct IRMeter: View {
    @EnvironmentObject var link: IRLink
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
            let age = ctx.date.timeIntervalSince(link.irSeen)
            let on = age < 0.35
            let strong = link.irWidest >= 150
            let bars = !on ? 0 : link.irWidest >= 150 ? 3 : link.irWidest >= 60 ? 2 : 1
            HStack(spacing: 6) {
                Image(systemName: on ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill").font(.system(size: 11, weight: .bold))
                Text(!on ? "IR head ready" : strong ? "IR light · strong" : "IR light · weak")
                    .font(.system(size: 11, weight: .semibold))
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<3, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1).frame(width: 3, height: CGFloat(5 + i * 3))
                            .opacity(i < bars ? 1 : 0.25)
                    }
                }
                if on { Text("\(link.irWidest) µs").font(.system(size: 10, design: .monospaced)).opacity(0.8) }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill((on ? (strong ? Color.wbOrange : Color.yellow) : Color.wbGreen).opacity(on ? 0.9 : 0.15)))
            .foregroundColor(on ? .white : .wbGreen)
            .animation(.easeOut(duration: 0.12), value: on)
            .help("Lights up whenever the IR head sees infrared light. Strong = good enough to link.")
        }
    }
}

/// The Watt Bank logo (yellow bolt badge), from the app bundle; falls back to a drawn bolt-in-circle.
let wattBankLogoImage: NSImage? = Bundle.main.url(forResource: "logo", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
struct WattBankLogo: View {
    let size: CGFloat
    var name = "logo"                   // "logo" (Lightning), "debit_logo" (Grass), "credit_logo" (Water)
    var body: some View {
        if let img = (name == "logo" ? wattBankLogoImage
                      : Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) }) {
            Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
        } else if name == "calories_logo" {          // Fire energy ball, drawn
            ZStack {
                Circle().fill(RadialGradient(colors: [Color(red: 1, green: 0.85, blue: 0.4), Color(red: 0.95, green: 0.4, blue: 0.08),
                                                      Color(red: 0.6, green: 0.1, blue: 0.02)],
                                             center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.6))
                Circle().stroke(Color.black.opacity(0.45), lineWidth: max(1, size * 0.05))
                Image(systemName: "flame.fill").font(.system(size: size * 0.55, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.white, Color(red: 1, green: 0.95, blue: 0.6)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.4), radius: 0.5, y: 0.5)
            }.frame(width: size, height: size)
        } else {
            ZStack {
                Circle().fill(Color.yellow).frame(width: size, height: size)
                Image(systemName: "bolt.fill").font(.system(size: size * 0.5, weight: .bold)).foregroundColor(.black)
            }
        }
    }
}

struct Pill: View {
    let text: String; let color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundColor(color)
    }
}

/// One of the cartridge's four 100-line batteries. `lines` is 0...99.
struct Battery: View {
    let lines: Int
    let label: String
    var small = false                   // compact size, for the top bar
    var tint: Color { lines <= 33 ? .wbRed : lines <= 66 ? .wbOrange : .wbGreen }
    var body: some View {
        VStack(spacing: small ? 2 : 4) {
            RoundedRectangle(cornerRadius: 2).fill(Color.wbInk).frame(width: small ? 9 : 14, height: small ? 3 : 5)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7).fill(Color.wbBG)
                RoundedRectangle(cornerRadius: 7).stroke(Color.wbInk, lineWidth: 2)
                GeometryReader { g in
                    VStack { Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 4).fill(tint)
                            .frame(height: max(0, (g.size.height - 8) * CGFloat(lines) / 99))
                    }
                    .padding(4)
                }
                .animation(.easeOut(duration: 0.6), value: lines)
            }
            .frame(width: small ? 24 : 44, height: small ? 44 : 92)
            Text("\(lines)").font(.system(size: small ? 11 : 14, weight: .bold, design: .rounded))
            Text(label).font(.system(size: small ? 8 : 9, weight: .medium)).foregroundColor(.wbSub)
        }
        .frame(width: small ? 44 : 66)
    }
}

/// As many 100-line batteries as the balance needs (always at least one):
/// battery k counts lines of 100^k W, so 8,991 W = 91 lines of 1 W + 89 lines of 100 W.
struct Batteries: View {
    let watts: Int
    var small = false
    var cells: [(lines: Int, unit: Int)] {
        var out: [(Int, Int)] = []
        var v = max(0, watts), unit = 1
        repeat {
            out.append((v % 100, unit))
            v /= 100
            if v > 0 { unit = unit.multipliedReportingOverflow(by: 100).partialValue }
        } while v > 0
        return out
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 6) {
                ForEach(cells.reversed(), id: \.unit) { c in          // biggest on the left, 1 W on the right
                    Battery(lines: c.lines, label: fmt(c.unit) + " W", small: small)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.4), value: cells.count)
        }
        .frame(maxWidth: (small ? 44 : 66) * 6 + 30)
        .fixedSize(horizontal: cells.count <= 6, vertical: false)
        .help("Each line of a battery = the W shown under it; a new battery appears on the left when one fills up")
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var bank: Bank
    @EnvironmentObject var link: IRLink
    @EnvironmentObject var session: Session
    @State private var askAmount = false
    @State private var deleting: Int? = nil
    @State private var choosingGift = false
    @State private var showingIRGuide = false
    @State private var irGuideStart = 0
    @ObservedObject private var flasher = Flasher.shared
    @State private var payingDebt = false
    @State private var payingCredit = false
    @State private var usingCalories = false
    @State private var toppingUp = false
    @State private var buyingWatts = false       // Top-up window limited to buying watts (Debit or Credit)
    @State private var usingCash = false
    @State private var cashStart: CashSheet.Start = .none
    @State private var movingFrom: SaveMoneySheet.Source? = nil
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 14) {
            header
            HStack(alignment: .center, spacing: 12) {
                accountsBar
                if bank.current.balance > 0 { Batteries(watts: bank.current.balance, small: true) }   // Watt card batteries, top right
            }
            // the middle scrolls when the window is shorter than the cards + buttons, so the header (IR status)
            // and the tips bar always stay on screen
            GeometryReader { g in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 14) {               // cards, with the IR and buy/sell buttons under them
                            balanceCard
                            HStack(alignment: .top, spacing: 14) {
                                actions.frame(width: 300)       // IR buttons stacked on the left
                                exchange.frame(width: 260)      // buy / sell watts with the Debit card
                            }
                        }
                        .frame(width: 574)
                        historyCard.frame(maxHeight: .infinity, alignment: .top).frame(height: max(g.size.height, 400), alignment: .top)   // history to the right of the cards
                    }
                    .frame(minHeight: g.size.height, alignment: .top)
                }
                .scrollIndicators(.automatic)
            }
            DonationFooter()
        }
        .padding(20)
        .background(shortcuts)
        .frame(minWidth: 1220, minHeight: 640)
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 16).stroke(Color.wbGreen, style: StrokeStyle(lineWidth: 4, dash: [10, 6]))
                    .overlay(Text("Drop a Pokémon save to top up Debit").font(.system(size: 18, weight: .bold))
                        .padding(14).background(Capsule().fill(Color.wbGreen)).foregroundColor(.white))
                    .padding(6).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { providers in
            guard session.mode == nil, let pr = providers.first else { return false }
            _ = pr.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await addDroppedSave(url) }
            }
            return true
        }
        .background(Color.wbBG)
        .foregroundColor(.wbInk)
        .sheet(isPresented: Binding(get: { session.mode != nil }, set: { if !$0 { session.close() } })) {
            TransferSheet().environmentObject(session).environmentObject(bank)
        }
        .sheet(isPresented: $payingCredit) {
            PayCreditSheet(account: bank.current.id) { action in
                payingCredit = false
                if action == .deposit { DispatchQueue.main.async { session.beginDeposit() } }
            }
            .environmentObject(bank)
        }
        .sheet(isPresented: $toppingUp) {
            TopUpSheet(account: bank.current.id, buyOnly: buyingWatts) { deposit in
                toppingUp = false; buyingWatts = false
                if deposit { DispatchQueue.main.async { session.beginDeposit() } }
            }
            .environmentObject(bank)
        }
        .sheet(item: $movingFrom) { src in
            SaveMoneySheet(source: src) { movingFrom = nil }.environmentObject(bank)
        }
        .sheet(isPresented: $usingCash) {
            CashSheetHost(account: bank.current.id, start: $cashStart) { usingCash = false; cashStart = .none }.environmentObject(bank)
        }
        .sheet(isPresented: $showingIRGuide) { IRGuideSheet(link: link, start: irGuideStart) { showingIRGuide = false; irGuideStart = 0 } }
        .sheet(isPresented: $usingCalories) {
            CaloriesSheet(account: bank.current.id) { usingCalories = false }.environmentObject(bank)
        }
        .sheet(isPresented: $payingDebt) {
            PayDebtSheet(debtor: bank.current.id) { payingDebt = false }.environmentObject(bank)
        }
        .sheet(isPresented: $choosingGift) {
            GiftSheet(balance: bank.current.balance, creditMax: bank.maxBorrowW(bank.current), cost: { session.giftCost($0) },
                      sentBefore: { $0.isDeco && bank.decoAlreadySent($0.code) },
                      toggleOwned: { bank.toggleDecoOwned($0.code) },
                      saveName: bank.saveLabel(bank.current)) { g, other, credit in
                choosingGift = false
                session.anotherSave = other
                session.payCredit = credit
                if let g { DispatchQueue.main.async { session.beginGift(g) } }
            }
        }
        .sheet(isPresented: $askAmount) {
            AmountSheet(debitMax: max(0, bank.current.balance), creditMax: bank.maxBorrowW(bank.current)) { amt, credit in
                askAmount = false
                session.payCredit = credit
                if let amt { session.beginWithdraw(amt) }
            }
        }
        .sheet(isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            if let i = deleting, bank.data.accounts.indices.contains(i) {
                DeleteSheet(id: bank.data.accounts[i].id) { action in
                    deleting = nil
                    DispatchQueue.main.async {           // change the accounts only after the sheet is gone
                    switch action {
                    case .delete: bank.deleteAccount(i)
                    case .move(let to): bank.move(bank.data.accounts[i].balance, from: i, to: to); bank.deleteAccount(i)
                    case .moveToNew:
                        let from = bank.data.accounts[i].id
                        let n = bank.addAccount()
                        if let f = bank.data.accounts.firstIndex(where: { $0.id == from }) {
                            bank.move(bank.data.accounts[f].balance, from: f, to: n); bank.deleteAccount(f)
                        }
                    case .withdraw: bank.select(i); askAmount = true
                    case .cancel: break
                    }
                    }
                }
                .environmentObject(bank)
            }
        }
    }

    var canDeposit: Bool { link.ready && session.mode == nil && !askAmount && !choosingGift && !payingDebt && !payingCredit && !usingCalories && !toppingUp && !usingCash && movingFrom == nil }
    var canWithdraw: Bool { canDeposit && (bank.current.balance > 0 || bank.maxBorrowW(bank.current) > 0) }

    /// Keyboard: ↑ or + = Deposit, ↓ or − = Withdraw, ← → or 1–9 = switch account, P = pay debt, ⌘N = new, ⌘⌫ = delete.
    var shortcuts: some View {
        ZStack {
            Button("Deposit") { if canDeposit { session.beginDeposit() } }.keyboardShortcut(.upArrow, modifiers: [])
            Button("Deposit+") { if canDeposit { session.beginDeposit() } }.keyboardShortcut("+", modifiers: [])
            Button("Deposit=") { if canDeposit { session.beginDeposit() } }.keyboardShortcut("=", modifiers: [])
            Button("Withdraw") { if canWithdraw { askAmount = true } }.keyboardShortcut(.downArrow, modifiers: [])
            Button("Withdraw-") { if canWithdraw { askAmount = true } }.keyboardShortcut("-", modifiers: [])
            Button("Gift*") { if canWithdraw { choosingGift = true } }.keyboardShortcut("*", modifiers: [])
            Button("Gift G") { if canWithdraw { choosingGift = true } }.keyboardShortcut("g", modifiers: [])
            Button("Next account") { if session.mode == nil { bank.select((bank.data.active + 1) % bank.data.accounts.count) } }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Previous account") { if session.mode == nil {
                let n = bank.data.accounts.count; bank.select((bank.data.active + n - 1) % n) } }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("New account") { if session.mode == nil { addAccount() } }
                .keyboardShortcut("n", modifiers: [.command])
            Button("Delete account") { if session.mode == nil && bank.data.accounts.count > 1 { deleting = bank.data.active } }
                .keyboardShortcut(.delete, modifiers: [.command])
            Button("Credit card") { if session.mode == nil { payingCredit = true } }
                .keyboardShortcut("c", modifiers: [])
            Button("Calories /") { if session.mode == nil { usingCalories = true } }
                .keyboardShortcut("/", modifiers: [])
            Button("Calories K") { if session.mode == nil { usingCalories = true } }
                .keyboardShortcut("k", modifiers: [])
            Button("Debit $") { if session.mode == nil { usingCash = true } }
                .keyboardShortcut("$", modifiers: [])
            Button("Debit M") { if session.mode == nil { usingCash = true } }
                .keyboardShortcut("m", modifiers: [])
            Button("Buy watts B") { if session.mode == nil && (bank.cashWatts > 0 || bank.maxBorrowW(bank.current) > 0) { buyingWatts = true; toppingUp = true } }
                .keyboardShortcut("b", modifiers: [])
            Button("Sell watts S") { if session.mode == nil && bank.cashFromWatts > 0 { cashStart = .sellWatts; usingCash = true } }
                .keyboardShortcut("s", modifiers: [])
            Button("Top up Watt") { if session.mode == nil { toppingUp = true } }
                .keyboardShortcut("p", modifiers: [])
            Button("IR guide") { if session.mode == nil { showingIRGuide = true } }
                .keyboardShortcut("i", modifiers: [])
            ForEach(0..<9, id: \.self) { i in
                Button("Account \(i + 1)") { if session.mode == nil { bank.select(i) } }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
            }
        }
        .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
    }

    var header: some View {
        HStack(spacing: 10) {
            WattBankLogo(size: 34)
            Text("Watt Bank").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("v\(appVersion)").font(.system(size: 11)).foregroundColor(.wbSub)
            Spacer()
            if case .flashing(let p) = flasher.state {
                Pill(text: "Installing IR head firmware… \(Int(p * 100))%", color: .wbBlue)
            }
            else if link.stuck {
                Pill(text: "IR head stuck repeating · unplug it and plug it back in", color: .wbRed)
                    .help("The USB link keeps sending the same line over and over. Unplugging resets it.")
            }
            else if link.ready { IRMeter() }
            else if link.silent {
                Button { irGuideStart = IRGuideSheet.flashStep; showingIRGuide = true } label: {
                    Pill(text: "No Watt Bank firmware on the ESP32 · Install", color: .wbOrange)
                }.buttonStyle(.plain).help("Install the IR head firmware from Watt Bank, no Arduino IDE needed")
            }
            else if link.port != nil { Pill(text: "IR head starting…", color: .wbOrange) }
            else { Pill(text: "IR head not connected", color: .wbRed) }
        }
    }

    var accountsBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(bank.data.accounts.enumerated()), id: \.element.id) { i, a in
                        let on = i == bank.data.active
                        Button { bank.select(i) } label: {
                            VStack(spacing: 2) {
                                Text(a.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                if let id = a.crystalID {
                                    Text("ID \(trainerID(id))").font(.system(size: 9)).opacity(0.75)
                                }
                                Text("\(fmt(a.balance)) W").font(.system(size: 11, weight: a.balance < 0 ? .bold : .regular))
                                    .foregroundColor(a.balance < 0 ? (on ? .white : .wbRed) : nil).opacity(0.85)
                            }
                            .frame(width: 140).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 12).fill(on ? Color.wbBlue : Color.wbCard))
                            .foregroundColor(on ? .white : .wbInk)
                        }
                        .buttonStyle(.plain)
                        .id(a.id)
                        .contextMenu {
                            Button("Delete…") { deleting = i }.disabled(bank.data.accounts.count < 2)
                        }
                        .disabled(session.mode != nil)
                    }
                    Button { addAccount() } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.wbCard))
                    }
                    .buttonStyle(.plain).help("New account (⌘N)")
                    .disabled(session.mode != nil)
                }
                .padding(.vertical, 2)
            }
            .onChange(of: bank.data.active) { _, _ in
                withAnimation { proxy.scrollTo(bank.current.id, anchor: .center) }
            }
        }
    }

    func addAccount() { _ = bank.addAccount() }

    @ViewBuilder func cardView(_ k: String) -> some View {
        switch k {
        case "credit": CreditCardView(account: bank.current) { payingCredit = true }
        case "calories": CaloriesCardView(account: bank.current) { usingCalories = true }
        case "cash": CashCardView(account: bank.current) { usingCash = true }
        case "trainer": TrainerCardView(account: bank.current) { movingFrom = .trainer }
        case "mom": MomCardView(account: bank.current) { movingFrom = .mom }
        default: DebitCardView(account: bank.current) { toppingUp = true }
        }
    }
    func gridCard(_ k: String) -> some View {
        let order = bank.visibleCards, i = order.firstIndex(of: k) ?? 0
        return cardView(k)
            .draggable(k) { cardView(k).frame(width: 250, height: 162).opacity(0.85) }
            .dropDestination(for: String.self) { items, _ in
                guard let from = items.first, from != k else { return false }
                withAnimation(.spring(duration: 0.35)) { bank.swapCards(from, k) }
                return true
            }
            .contextMenu {
                Button("Move Left") { withAnimation { bank.moveCard(k, to: i - 1) } }.disabled(i % 2 == 0)
                Button("Move Right") { withAnimation { bank.moveCard(k, to: i + 1) } }.disabled(i % 2 == 1 || i + 1 >= order.count)
                Button("Move Up") { withAnimation { bank.moveCard(k, to: i - 2) } }.disabled(i < 2)
                Button("Move Down") { withAnimation { bank.moveCard(k, to: i + 2) } }.disabled(i + 2 >= order.count)
            }
    }

    /// A save dropped anywhere on the window: read it, find (or start) that trainer's account; its Trainer/Mom cards appear.
    func addDroppedSave(_ url: URL) async {
        let i = await SaveTool.run(["info", url.path])
        guard i.ok else { bank.healthNote = "Can't read that file: " + (i.error ?? "not a Pokémon save"); NSSound.beep(); return }
        let (k, isNew) = bank.accountForTrainer(name: i.trainer ?? "", tid: i.tid ?? 0)
        bank.select(k)
        bank.rememberSave(SaveRef(path: url.path, game: i.game ?? "?", trainer: i.trainer ?? "", tid: i.tidText))
        bank.linkSave(url.path, to: k, info: i)
        bank.healthNote = (isNew ? "New account for " : "Loaded ") + "\(i.trainer ?? "") · \(SaveTool.gameName(i.game ?? ""))"
        NSSound(named: "Pop")?.play()
    }

    var balanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    if bank.current.crystalID != nil {
                        Label("Linked to a GSC save", systemImage: "gamecontroller.fill")
                            .font(.system(size: 11)).foregroundColor(.wbSub)
                    } else {
                        Label("Not linked yet: the first GSC Mystery Gift links this account to that trainer",
                              systemImage: "gamecontroller").font(.system(size: 11)).foregroundColor(.wbSub)
                    }
                    Spacer()
                    if let n = bank.healthNote {
                        Text(n).font(.system(size: 11, weight: .semibold)).foregroundColor(.wbGreen).lineLimit(1)
                    }
                    Text("All accounts: \(fmt(bank.allTotal)) W").font(.system(size: 11)).foregroundColor(.wbSub)
                }
                HStack(alignment: .center, spacing: 16) {
                    // 2 × 2 grid; drag a card onto another to swap places (or right-click → Move)
                    let order = bank.visibleCards
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(0..<((order.count + 1) / 2), id: \.self) { row in
                            HStack(spacing: 16) {
                                ForEach(order[(row * 2)..<min(row * 2 + 2, order.count)], id: \.self) { k in gridCard(k) }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    Label("\(fmt(bank.current.totalIn)) in", systemImage: "arrow.up.circle.fill").foregroundColor(.wbGreen)
                    Label("\(fmt(bank.current.totalOut)) out", systemImage: "arrow.down.circle.fill").foregroundColor(.wbRed)
                    Spacer()
                    Text("P = top up Watt   C = pay off Credit   / or K = Calories   $ or M = Debit")
                        .foregroundColor(.wbSub).lineLimit(1).minimumScaleFactor(0.7)
                }.font(.system(size: 11))
            }
        }
    }

    var creditRow: some View {
        let a = bank.current
        let owed = bank.owed(a)
        let due = bank.nextDue(a)
        return HStack(spacing: 8) {
            Image(systemName: "creditcard.fill").foregroundColor(.wbBlue)
            Text("CREDIT").font(.system(size: 10, weight: .bold)).foregroundColor(.wbSub)
            Text("₽\(fmt(bank.maxBorrow(a))) available").font(.system(size: 12, weight: .semibold))
            Text("· level \(bank.creditLevel(a)) · limit ₽\(fmt(bank.creditLimit(a)))").font(.system(size: 11)).foregroundColor(.wbSub)
            if owed > 0, let d = due {
                Text("· owes ₽\(fmt(owed))").font(.system(size: 11, weight: .bold)).foregroundColor(.wbRed)
                Text(d.late ? "LATE" : "due \(d.due.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 11, weight: d.late ? .bold : .regular)).foregroundColor(d.late ? .wbRed : .wbSub)
            }
        }
        .padding(.top, 4)
        .help("Pay with Credit (Tab in Withdraw or GSC). Each loan costs 10% once; if not repaid in 7 days, one more 10% and the level drops. Deposits pay loans first. Repaying a loan on time (one of at least a quarter of your limit) raises the level: the limit doubles.")
    }

    var actions: some View {
        VStack(spacing: 10) {
            bigButton("Deposit", "Pikachu → bank   ↑ or +", "arrow.up", .wbGreen) { session.beginDeposit() }
                .disabled(!link.ready)
            bigButton("Withdraw", "bank → Pikachu   ↓ or −", "arrow.down", .wbOrange) { askAmount = true }
                .disabled(!link.ready || (bank.current.balance <= 0 && bank.maxBorrowW(bank.current) == 0))
            bigButton("GSC", "Mystery Gift   * or G", "gift.fill", .wbBlue) { choosingGift = true }
                .disabled(!link.ready || (bank.current.balance <= 0 && bank.maxBorrowW(bank.current) == 0))
            Button { showingIRGuide = true } label: {
                Label("Build the IR head   I", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).stroke(Color.wbBlue.opacity(0.6), lineWidth: 1.5))
                    .foregroundColor(.wbBlue).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Step-by-step guide: wire the ESP32 IR head and load its firmware")
        }
    }

    /// Watts ↔ PokéDollars, Watt card ↔ Debit card at 0.83 W per ₽.
    var exchange: some View {
        VStack(spacing: 10) {
            bigButton("Buy Watts", "Debit or Credit → Watt   B", "bolt.fill", Color(red: 0.85, green: 0.62, blue: 0.08)) {
                buyingWatts = true; toppingUp = true
            }
            .disabled(session.mode != nil || (bank.cashWatts == 0 && bank.maxBorrowW(bank.current) == 0))
            bigButton("Sell Watts", "Watt → Debit ₽   S", "dollarsign.circle.fill", Color(red: 0.12, green: 0.55, blue: 0.28)) {
                cashStart = .sellWatts; usingCash = true
            }
            .disabled(session.mode != nil || bank.cashFromWatts == 0)
            Text("0.83 W = ₽1").font(.system(size: 11)).foregroundColor(.wbSub)
        }
    }

    func bigButton(_ t: String, _ sub: String, _ icon: String, _ c: Color, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18, weight: .bold))
                    .frame(width: 36, height: 36).background(Circle().fill(.white.opacity(0.25)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t).font(.system(size: 16, weight: .bold))
                    Text(sub).font(.system(size: 11)).opacity(0.85)
                }
                Spacer()
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 14).fill(c))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    func histCell(_ t: String?, _ pos: Bool, _ w: CGFloat) -> some View {
        Text(t ?? "—").font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(t == nil ? .wbSub.opacity(0.5) : pos ? .wbGreen : .wbRed)
            .frame(width: w, alignment: .trailing)
    }

    var historyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("History").font(.system(size: 13, weight: .semibold)).foregroundColor(.wbSub)
                    Spacer()
                    Text("PokéDollars").frame(width: 100, alignment: .trailing)
                    Text("Watts").frame(width: 90, alignment: .trailing)
                    Text("Items").frame(width: 170, alignment: .trailing)
                }.font(.system(size: 11, weight: .semibold)).foregroundColor(.wbSub)
                if bank.current.history.isEmpty {
                    Text("No transfers yet. Set your Pikachu to Watts → Send and press Deposit.")
                        .font(.system(size: 12)).foregroundColor(.wbSub).padding(.vertical, 8)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(bank.current.history) { e in
                                let up = e.amount > 0 || (e.amount == 0 && (e.pd ?? 0) > 0)
                                HStack {
                                    Image(systemName: up ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                        .foregroundColor(up ? .wbGreen : .wbRed)
                                    Text(e.kind).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Spacer()
                                    Text(e.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11)).foregroundColor(.wbSub)
                                    histCell(e.pd.map { ($0 >= 0 ? "+" : "−") + "₽" + fmt(abs($0)) }, (e.pd ?? 0) >= 0, 100)
                                    histCell(e.amount == 0 ? nil : (e.amount > 0 ? "+" : "−") + fmt(abs(e.amount)) + " W", e.amount >= 0, 90)
                                    Text(e.itemText ?? "—").font(.system(size: 12, weight: .medium))
                                        .foregroundColor(e.itemText == nil ? .wbSub.opacity(0.5) : .wbBlue).lineLimit(1)
                                        .frame(width: 170, alignment: .trailing)
                                }
                                .padding(.vertical, 7)
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

struct AmountSheet: View {
    let debitMax: Int
    let creditMax: Int
    let done: (Int?, Bool) -> Void
    @State private var useCredit = false
    var max: Int { Swift.min(useCredit ? creditMax : debitMax, maxBatch) }
    @State private var amount = 1
    @State private var typed = ""
    @State private var held = 0
    @State private var typing = false        // typing digits replaces the amount
    @FocusState private var focused: Bool
    var top: Int { Swift.max(1, max) }
    var parts: Int { (amount + maxPerTransfer - 1) / maxPerTransfer }
    func clamp(_ v: Int) -> Int { Swift.min(Swift.max(1, v), top) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundColor(.wbOrange)
                Text("Withdraw to the Pikachu").font(.system(size: 17, weight: .bold))
            }
            PayWith(useCredit: $useCredit, debit: debitMax, credit: creditMax) { amount = clamp(amount) }
            HStack(spacing: 14) {
                Button { amount = clamp(amount - 1); typed = "" } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).font(.system(size: 22, weight: .bold)).foregroundColor(.secondary)
                Text("\(fmt(amount)) W")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .contentTransition(.numericText()).animation(.easeOut(duration: 0.12), value: amount)
                    .frame(minWidth: 220)
                Button { amount = clamp(amount + 1); typed = "" } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).font(.system(size: 22, weight: .bold)).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            ProgressView(value: Double(amount), total: Double(top)).tint(.wbOrange)
            Text(amount > maxPerTransfer
                 ? "Sent in \(parts) parts of up to 999 W. You'll set the Pikachu to Receive before each part."
                 : "Up to 999 W per transfer; more is split into parts automatically.")
                .font(.system(size: 12)).foregroundColor(.secondary)
            Text("→ / ← ±1 (hold to speed up)   ↑ / ↓ ±100   ⇧→ max   ⇧← 1   or type the number\nTab = Watt / Credit   Return = withdraw   Esc = cancel")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done(nil, useCredit) }
                Button("Withdraw \(fmt(amount)) W") { done(clamp(amount), useCredit) }.buttonStyle(.borderedProminent).tint(.wbOrange)
            }
        }
        .padding(22).frame(width: 460)
        .foregroundStyle(.primary)   // sheets follow light/dark mode; don't inherit the main window's dark ink
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; useCredit = debitMax <= 0 && creditMax > 0 }
        .onKeyPress(phases: [.down, .repeat]) { k in handle(k) }
    }

    func handle(_ k: KeyPress) -> KeyPress.Result {
        held = k.phase == .repeat ? held + 1 : 0
            if [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow].contains(k.key) { typing = false }
        let step = held > 40 ? 100 : held > 15 ? 10 : 1
        let shift = k.modifiers.contains(.shift)
        switch k.key {
        case .rightArrow: amount = shift ? top : clamp(amount + step); typed = ""
        case .leftArrow:  amount = shift ? 1 : clamp(amount - step); typed = ""
        case .upArrow:    amount = clamp(amount + 100); typed = ""
        case .downArrow:  amount = clamp(amount - 100); typed = ""
        case .return:     done(clamp(amount), useCredit)
        case .tab:        if creditMax > 0 && debitMax > 0 { useCredit.toggle(); amount = clamp(amount) }
        case .escape:     done(nil, useCredit)
        default:
            // Backspace arrives as U+007F on macOS (SwiftUI's .delete is U+0008), so accept both.
            if k.key == .delete || k.key == .deleteForward || k.characters == "\u{7F}" || k.characters == "\u{8}" {
                let base = typed.isEmpty ? String(amount) : typed     // also edits a value set with the arrows
                typed = String(base.dropLast())
                amount = clamp(Int(typed) ?? 1)
                return .handled
            }
            guard let c = k.characters.first, c.isASCII, c.isNumber else { return .ignored }
            if typed.count < 5 { typed.append(c) }
            amount = clamp(Int(typed) ?? 1)
        }
        return .handled
    }
}

/// What Crystal gets instead of a decoration it already owns: the most valuable item that costs no more
/// than the decoration (so a repeat is never worth less than about what was paid).
func decoFallback(_ d: Gift) -> Gift {
    giftItems.filter { $0.price <= d.price }.max { ($0.price, $1.name) < ($1.price, $0.name) } ?? giftItems[0]
}

/// Picker order: cheapest first (ties by name). The codes stay attached, so sorting never changes what is sent.
let giftItemsByPrice = giftItems.sorted { ($0.price, $0.name) < ($1.price, $1.name) }
let giftDecosByPrice = giftDecos.sorted { ($0.price, $0.name) < ($1.price, $1.name) }

/// "Pay with" row: two full-width card buttons, Debit and Credit (Tab switches).
struct PayWith: View {
    @Binding var useCredit: Bool
    let debit: Int
    let credit: Int
    var changed: () -> Void = {}
    var body: some View {
        HStack(spacing: 10) {
            option("Watt card", "banknote", debit, !useCredit, Color.wbGreen) { useCredit = false; changed() }
            option("Credit card", "creditcard.fill", credit, useCredit, Color.wbBlue, pd: true) { useCredit = true; changed() }
        }
    }
    func option(_ title: String, _ icon: String, _ avail: Int, _ on: Bool, _ tint: Color, pd: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .bold)).lineLimit(1)
                    Text(pd ? "₽\(fmt(pdOf(avail))) available" : "\(fmt(avail)) W available").font(.system(size: 11)).lineLimit(1).opacity(0.85)
                }
                Spacer(minLength: 4)
                if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 15)) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? tint : Color.primary.opacity(0.07)))
            .foregroundColor(on ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(avail <= 0).opacity(avail <= 0 ? 0.45 : 1)
        .help("Tab switches between Watt and Credit")
    }
}

struct GiftSheet: View {
    let balance: Int
    let creditMax: Int
    @State private var useCredit = false
    var funds: Int { useCredit ? creditMax : balance }
    let cost: (Gift) -> Int
    let sentBefore: (Gift) -> Bool
    let toggleOwned: (Gift) -> Void
    let saveName: String?
    let done: (Gift?, Bool, Bool) -> Void
    @State private var other = false             // S: sending to another save → duplicates allowed
    @State private var refresh = 0                // redraw after marking a decoration owned
    @State private var decos = false
    @State private var sel = giftItemsByPrice.firstIndex { $0.name == "Rare Candy" } ?? 0
    @FocusState private var focused: Bool
    var list: [Gift] { decos ? giftDecosByPrice : giftItemsByPrice }
    var current: Gift { list[min(sel, list.count - 1)] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let _ = refresh                       // re-read "owned" marks after O
            HStack {
                Image(systemName: "gift.fill").font(.system(size: 22)).foregroundColor(.wbBlue)
                Text("Mystery Gift to Pokémon GSC").font(.system(size: 17, weight: .bold))
            }
            PayWith(useCredit: $useCredit, debit: max(0, balance), credit: creditMax)
            Picker("", selection: $decos) {
                Text("Items  (\(giftItems.count))").tag(false)
                Text("Decorations  (\(giftDecos.count))").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, g in
                            let on = i == sel
                            let afford = cost(g) <= funds && !blocked(g)
                            Button { sel = i } label: {
                                HStack {
                                    Text(g.name).font(.system(size: 13, weight: on ? .bold : .regular))
                                    Spacer()
                                    Text(giftRarity(g.code)).font(.system(size: 10)).opacity(0.7)
                                        .frame(width: 70, alignment: .trailing)
                                    if sentBefore(g) {
                                        Text(other ? "dup → \(decoFallback(g).name)" : "In this save's room")
                                            .font(.system(size: 10, weight: .semibold)).opacity(0.8)
                                    }
                                    Text("\(fmt(cost(g))) W").font(.system(size: 13, weight: .semibold, design: .rounded))
                                        .foregroundColor(on ? .white : afford ? .primary : .wbRed)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.wbBlue : Color.clear))
                                .foregroundColor(on ? .white : afford ? .primary : .secondary)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(g.id)
                        }
                    }
                }
                .frame(height: 300)
                .onChange(of: sel) { _, _ in proxy.scrollTo(current.id, anchor: .center) }
                .onChange(of: decos) { _, _ in proxy.scrollTo(current.id, anchor: .center) }
                .onAppear { proxy.scrollTo(current.id, anchor: .center) }
            }
            Text(!current.isDeco
                 ? "Items wait for you at the deliveryman, Pokémon Center 2F. GSC holds one gift at a time."
                 : sentBefore(current) && !other
                    ? "This save already has it, so it can't be sent. Press S if you're sending to another save, or O if it's wrong."
                    : sentBefore(current)
                    ? "Another save: it's sent. If that save has it too, GSC gives a \(decoFallback(current).name) and you're charged for that instead."
                    : "Goes straight to your room. Already have it from somewhere else? Press O to mark it, so it's never sent. (Unmarked repeats arrive as a \(decoFallback(current).name).)")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "gamecontroller.fill").font(.system(size: 11))
                Text(other ? "Sending to: another save (duplicates allowed)"
                           : "Sending to: \(saveName ?? "not linked yet — the first gift links this account")")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("S = switch").font(.system(size: 11)).foregroundColor(.secondary)
            }
            .foregroundColor(other ? .wbOrange : .primary)
            Text("↑ ↓ choose   ← → items / decorations   O = this save has it   S = another save   Tab = Watt / Credit   Return = send   Esc = cancel")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { done(nil, other, useCredit) }
                Button("Send \(current.name) for \(fmt(cost(current))) W") { send() }
                    .buttonStyle(.borderedProminent).tint(.wbBlue)
                    .disabled(cost(current) > funds || blocked(current))
            }
        }
        .padding(22).frame(width: 480)
        .foregroundStyle(.primary)   // sheets follow light/dark mode; don't inherit the main window's dark ink
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; useCredit = balance <= 0 && creditMax > 0 }
        .onKeyPress(phases: [.down, .repeat]) { k in
            switch k.key {
            case .downArrow: sel = min(sel + 1, list.count - 1)
            case .upArrow: sel = max(sel - 1, 0)
            case .rightArrow: decos = true; sel = min(sel, giftDecos.count - 1)
            case .leftArrow: decos = false; sel = min(sel, giftItems.count - 1)
            case .return: send()
            case .escape: done(nil, other, useCredit)
            case .tab: if creditMax > 0 && balance > 0 { useCredit.toggle() }
            default:
                if k.characters.lowercased() == "s" { other.toggle(); return .handled }
                if decos, k.characters.lowercased() == "o" { toggleOwned(current); refresh += 1; return .handled }
                return .ignored
            }
            return .handled
        }
    }

    func blocked(_ g: Gift) -> Bool { sentBefore(g) && !other }
    func send() { if cost(current) <= funds && !blocked(current) { done(current, other, useCredit) } }
}

/// A wavy horizon filled down to the bottom edge (y and amplitude as fractions of the height).
struct WaveShape: Shape {
    var level: CGFloat, amp: CGFloat, waves: CGFloat, phase: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y0 = r.height * level
        p.move(to: CGPoint(x: 0, y: r.height))
        p.addLine(to: CGPoint(x: 0, y: y0))
        let steps = 48
        for i in 0...steps {
            let x = r.width * CGFloat(i) / CGFloat(steps)
            let y = y0 + sin((CGFloat(i) / CGFloat(steps)) * .pi * 2 * waves + phase) * r.height * amp
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.addLine(to: CGPoint(x: r.width, y: r.height))
        p.closeSubpath()
        return p
    }
}

/// Calories card flames: a flame-border design (fire_flames.png), used as a mask.
/// Demo / screenshot mode: WATTBANK_DATA_DIR=/some/folder runs Watt Bank on the accounts in that folder,
/// without Apple Health sync, game-save watching or the IR head, so real data is never touched.
let demoDataDir: String? = ProcessInfo.processInfo.environment["WATTBANK_DATA_DIR"]

/// Your own card art: "~/Library/Application Support/Watt Bank/Card Art/<Card>.pdf" or ".png" (full card, 250 × 162
/// at any scale). Checked every 2 s, so a re-export shows up right away. Drawn over the card's gradient.
final class CardArt: ObservableObject {
    static let shared = CardArt()
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Watt Bank/Card Art")
    @Published private(set) var images: [String: NSImage] = [:]
    private var stamps: [String: Date?] = [:]       // nil inside = checked, no file
    private var timer: Timer?
    init() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.check() }
    }
    static func builtIn(_ card: String) -> NSImage? {
        ["pdf", "png"].lazy.compactMap { Bundle.main.url(forResource: "card_\(card.lowercased())", withExtension: $0) }
            .compactMap { NSImage(contentsOf: $0) }.first
    }
    func check() {
        for card in ["Watt", "Debit", "Credit", "Calories", "Trainer", "Mom"] {
            let url = ["pdf", "png"].map { Self.folder.appendingPathComponent("\(card).\($0)") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            let stamp = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
            if let old = stamps[card], old == stamp { continue }
            stamps[card] = stamp
            images[card] = url.flatMap { NSImage(contentsOf: $0) } ?? Self.builtIn(card)   // locked-in art ships in the app
        }
    }
}

let fireFlamesImage: NSImage? = Bundle.main.url(forResource: "fire_flames", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
/// Middle layer (fire_mid.png): the yellow flames enlarged, in orange. Core (fire_core.png): the yellow flames in the holes.
let fireMidImage: NSImage? = Bundle.main.url(forResource: "fire_mid", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
let fireCoreImage: NSImage? = Bundle.main.url(forResource: "fire_core", withExtension: "png").flatMap { NSImage(contentsOf: $0) }

/// Card wallpapers: Debit = rolling grass hills under a blue sky; Credit = wavy water under a blue sky.
/// Vector lightning: one thick bolt across the whole card at `level` (0 top … 1 bottom), left → right, with a thin
/// companion bolt and short forks branching up and down along it. Midpoint-displaced, filled; same every time for a seed.
struct HLightning: Shape {
    var level: Double
    var seed: UInt64 = 6
    var extra: Double = 0          // added to every width (for the shadow layer)
    struct RNG { var s: UInt64
        mutating func next() -> Double { s &+= 0x9E3779B97F4A7C15; var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53) }
        mutating func r(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() } }
    typealias P = (x: Double, y: Double)
    struct Fork { var a: P; var b: P; var level: Int }
    func md(_ g: inout RNG, _ a: P, _ b: P, _ off: Double, _ depth: Int, _ out: inout [P], _ forks: inout [Fork], _ fork: Int, _ H: Double) {
        if depth == 0 { out.append(b); return }
        let dx = b.x - a.x, dy = b.y - a.y, L = max(hypot(dx, dy), 0.001)
        let o = g.r(-off, off)
        let m: P = ((a.x + b.x) / 2 - dy / L * o, (a.y + b.y) / 2 + dx / L * o)
        md(&g, a, m, off * 0.55, depth - 1, &out, &forks, fork, H)
        if fork > 0, depth == 3 || depth == 4, g.next() < (fork == 2 ? 0.55 : 0.3) {
            let ang = atan2(dy, dx) + (g.next() < 0.5 ? -1 : 1) * g.r(0.7, 1.3)
            let ln = g.r(16, 42) * (fork == 2 ? 1 : 0.55)
            let e: P = (m.x + cos(ang) * ln, min(max(m.y + sin(ang) * ln, H * 0.5), H + 8))   // stays in the bottom half
            forks.append(Fork(a: m, b: e, level: fork - 1))
        }
        md(&g, m, b, off * 0.55, depth - 1, &out, &forks, fork, H)
    }
    func taper(_ p: inout Path, _ pts: [P], _ w: Double, _ main: Bool) {
        let n = pts.count; guard n > 1 else { return }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<n {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, n - 1)]
            let dx = b.x - a.x, dy = b.y - a.y, L = max(hypot(dx, dy), 0.001)
            let t = Double(i) / Double(n - 1)
            let f = main ? 0.55 + 0.45 * sin(.pi * t) : 1 - 0.85 * t        // bolts stay thick; forks thin out
            let ww = (w * f + extra) / 2
            left.append(CGPoint(x: pts[i].x - dy / L * ww, y: pts[i].y + dx / L * ww))
            right.append(CGPoint(x: pts[i].x + dy / L * ww, y: pts[i].y - dx / L * ww))
        }
        p.addLines(left + right.reversed()); p.closeSubpath()
    }
    func path(in rect: CGRect) -> Path {
        var g = RNG(s: seed), p = Path()
        let W = Double(rect.width), H = Double(rect.height)
        for (k, b) in [(3.2, 0.09), (1.3, 0.13)].enumerated() {
            let a: P = (-6, H * level + g.r(-6, 6)), e: P = (W + 6, H * level + g.r(-6, 6))
            var pts: [P] = [a], forks: [Fork] = []
            md(&g, a, e, H * b.1, 7, &pts, &forks, k == 0 ? 2 : 1, H)
            taper(&p, pts, b.0, true)
            while let f = forks.popLast() {
                var fp: [P] = [f.a], more: [Fork] = []
                md(&g, f.a, f.b, 5, 4, &fp, &more, f.level, H)
                taper(&p, fp, k == 0 ? b.0 * (f.level == 1 ? 0.5 : 0.35) : 0.7, false)
                forks += more
            }
        }
        return p
    }
}

struct LandscapeBackground: View {
    enum Kind { case grass, water, fire, hearts, ball, bolt }
    let kind: Kind
    var debt = false
    let colors: [Color]                 // the card's own gradient, above the horizon
    var body: some View {
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            if kind == .grass {
                WaveShape(level: 0.58, amp: 0.07, waves: 0.8, phase: 0.6)
                    .fill(LinearGradient(colors: [Color(red: 0.42, green: 0.72, blue: 0.25), Color(red: 0.2, green: 0.5, blue: 0.14)],
                                         startPoint: .top, endPoint: .bottom))
                WaveShape(level: 0.7, amp: 0.09, waves: 0.6, phase: 3.6)
                    .fill(LinearGradient(colors: [Color(red: 0.38, green: 0.78, blue: 0.2), Color(red: 0.12, green: 0.45, blue: 0.1)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.2), radius: 3, y: -1)
            } else if kind == .ball {
                // a Poké Ball button: a ring and a disc right in the middle of the card
                GeometryReader { g in
                    let d = g.size.height * 0.62
                    // the ball's band and ring as ONE shape (sideways Poke Ball): drawn solid, then faded together
                    let lw = d * 0.09
                    ZStack {
                        Rectangle().fill(Color.white)
                            .frame(width: g.size.width * 1.6, height: lw)
                            .rotationEffect(.degrees(-32))
                        Circle().fill(Color.black).frame(width: d - lw, height: d - lw).blendMode(.destinationOut)
                        Circle().stroke(Color.white, lineWidth: lw).frame(width: d, height: d)
                    }
                    .compositingGroup()
                    .opacity(0.22)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                    ZStack {
                        Circle().fill(Color.white.opacity(0.14)).frame(width: d * 0.55, height: d * 0.55)
                        Circle().stroke(Color.black.opacity(0.18), lineWidth: 2).frame(width: d * 0.55, height: d * 0.55)
                    }
                    .frame(width: d, height: d)
                    .position(x: g.size.width / 2, y: g.size.height / 2)
                }
            } else if kind == .bolt {
                // vector lightning across the bottom half, flowing left → right
                HLightning(level: 0.74, extra: 1.6)
                    .fill(Color(red: 0.62, green: 0.36, blue: 0.02).opacity(0.55)).offset(y: 1)
                HLightning(level: 0.74)
                    .fill(Color(red: 1, green: 0.99, blue: 0.91))
            } else if kind == .hearts {
                HeartsBackground()
            } else if kind == .fire {
                if let img = fireFlamesImage {
                    // flame border
                    GeometryReader { g in
                        let h = g.size.width * img.size.height / img.size.width
                        LinearGradient(colors: [Color(red: 0.92, green: 0.22, blue: 0.05), Color(red: 0.6, green: 0.06, blue: 0.02)],
                                       startPoint: .top, endPoint: .bottom)
                            .mask(Image(nsImage: img).resizable())
                            .frame(width: g.size.width, height: h)
                            .position(x: g.size.width / 2, y: g.size.height - h / 2 + g.size.height * 0.07)
                        // red (above) → orange (middle, smaller) → yellow (core, smallest), each a gradient
                        ForEach(Array([(fireMidImage, Color(red: 1, green: 0.64, blue: 0.14), Color(red: 0.95, green: 0.42, blue: 0.05)),
                                       (fireCoreImage, Color(red: 1, green: 0.95, blue: 0.62), Color(red: 1, green: 0.8, blue: 0.3))].enumerated()),
                                id: \.offset) { _, L in
                            if let m = L.0 {
                                LinearGradient(colors: [L.1, L.2], startPoint: .top, endPoint: .bottom)
                                    .mask(Image(nsImage: m).resizable())
                                    .frame(width: g.size.width, height: h)
                                    .position(x: g.size.width / 2, y: g.size.height - h / 2 + g.size.height * 0.07)
                            }
                        }
                    }
                }
            } else {
                WaveShape(level: 0.6, amp: 0.03, waves: 3, phase: 0)
                    .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.6, blue: 0.95), Color(red: 0.08, green: 0.3, blue: 0.7)],
                                         startPoint: .top, endPoint: .bottom))
                WaveShape(level: 0.7, amp: 0.035, waves: 2.5, phase: 1.5)
                    .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.5, blue: 0.9), Color(red: 0.05, green: 0.22, blue: 0.6)],
                                         startPoint: .top, endPoint: .bottom))
                WaveShape(level: 0.82, amp: 0.04, waves: 2, phase: 3)
                    .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.4, blue: 0.82), Color(red: 0.03, green: 0.15, blue: 0.48)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: .white.opacity(0.35), radius: 1, y: -1)
            }
            if debt { Color(red: 0.75, green: 0.05, blue: 0.05).opacity(0.5) }   // Debit below zero turns red
            // keep the left side readable
            LinearGradient(colors: [Color.black.opacity(0.18), .clear], startPoint: .leading, endPoint: .center)
        }
    }
}

/// Card wallpaper: an energy orb glowing on the right, a soft flame rising from it, faint light streaks.
struct EnergyBackground: View {
    let colors: [Color]
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let orb = CGPoint(x: w * 0.76, y: h * 0.66)
            ZStack {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                // light streaks rising behind
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill(Color.white.opacity(0.13))
                        .frame(width: 10 + CGFloat(i % 2) * 6, height: h * 0.9)
                        .position(x: w * (0.48 + CGFloat(i) * 0.15), y: h * 0.3)
                        .blur(radius: 6)
                }
                // big halo around the orb
                RadialGradient(colors: [Color(red: 1, green: 0.97, blue: 0.75).opacity(0.85),
                                        Color(red: 1, green: 0.9, blue: 0.4).opacity(0.45), .clear],
                               center: UnitPoint(x: orb.x / w, y: orb.y / h), startRadius: 2, endRadius: h * 0.75)
                // flame rising from the orb to the top edge
                Path { p in
                    p.move(to: CGPoint(x: orb.x - 34, y: orb.y))
                    p.addQuadCurve(to: CGPoint(x: orb.x + 4, y: -6), control: CGPoint(x: orb.x - 30, y: h * 0.18))
                    p.addQuadCurve(to: CGPoint(x: orb.x + 34, y: orb.y), control: CGPoint(x: orb.x + 22, y: h * 0.25))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color.white.opacity(0.0), Color.white.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .blur(radius: 7)
                // the orb
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.95, blue: 0.55), Color(red: 0.98, green: 0.78, blue: 0.1),
                                                  Color(red: 0.72, green: 0.5, blue: 0.05)],
                                         center: UnitPoint(x: 0.65, y: 0.3), startRadius: 1, endRadius: 34))
                    .frame(width: 58, height: 58)
                    .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1))
                    .shadow(color: Color(red: 1, green: 0.95, blue: 0.6), radius: 14)
                    .position(orb)
                    .opacity(0.55)
                // darken the left so the text stays readable
                LinearGradient(colors: [Color.black.opacity(0.22), .clear], startPoint: .leading, endPoint: .center)
            }
        }
    }
}

/// Shared card face: label + lightning bolt, chip + contactless (NFC) mark, amount, details, trainer name + ID.
/// Title bar across the top of a card, like a trading card's name bar: logo left, embossed title, tag right.
struct CardTitleBar: View {
    let title: String
    let tag: String?
    var logo = "logo"
    let tint: Color                     // bar color (a lighter shade of the card)
    let ink: Color                      // title color (a darker shade of the card)
    var body: some View {
        HStack(spacing: 7) {
            WattBankLogo(size: 24, name: logo).shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            Text(title)
                .font(.system(size: 19, weight: .black, design: .rounded))
                .tracking(1.5)
                .foregroundColor(ink)
                .shadow(color: .white.opacity(0.7), radius: 0, x: 1, y: 1)       // embossed: light edge
                .shadow(color: .black.opacity(0.35), radius: 0, x: -0.5, y: -0.5) // and a dark one
            Spacer(minLength: 4)
            if let tag {
                Text(tag).font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(ink)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().stroke(ink.opacity(0.8), lineWidth: 1.2))
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [tint.opacity(0.95), tint], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.55), lineWidth: 1).offset(x: -0.5, y: -0.5))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 1).offset(x: 0.5, y: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
    }
}

struct BankCardFace<Details: View>: View {
    @ObservedObject private var art = CardArt.shared
    let kind: String
    var tag: String? = nil
    var logo = "logo"
    var wallpaper: LandscapeBackground.Kind? = nil
    var debt = false
    var barTint: Color = .white
    var barInk: Color = .black
    let colors: [Color]
    let amount: Int
    var unit = "W"
    var prefix = ""
    let account: Account
    let action: () -> Void
    @ViewBuilder var details: Details
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                CardTitleBar(title: kind, tag: tag, logo: logo, tint: barTint, ink: barInk)
                    .padding(.horizontal, -6).padding(.top, -5)
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(prefix + fmtCard(amount) + (unit.isEmpty ? "" : " " + unit)).help(prefix + fmt(amount) + (unit.isEmpty ? "" : " " + unit)).font(.system(size: 26, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5).lineLimit(1)
                            .contentTransition(.numericText()).animation(.easeOut, value: amount)
                        details
                    }
                    Spacer(minLength: 4)
                    // chip + contactless mark, on the right
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [Color(red: 1, green: 0.88, blue: 0.5), Color(red: 0.85, green: 0.65, blue: 0.2)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                            .overlay(Path { p in p.move(to: CGPoint(x: 0, y: 11)); p.addLine(to: CGPoint(x: 32, y: 11))
                                            p.move(to: CGPoint(x: 11, y: 0)); p.addLine(to: CGPoint(x: 11, y: 22))
                                            p.move(to: CGPoint(x: 21, y: 0)); p.addLine(to: CGPoint(x: 21, y: 22)) }
                                        .stroke(Color.black.opacity(0.25), lineWidth: 0.6))
                            .frame(width: 32, height: 22)
                        Image(systemName: "wave.3.right").font(.system(size: 14, weight: .semibold)).opacity(0.9)
                    }
                }
                .padding(.top, 10)
                Spacer(minLength: 2)
                HStack(alignment: .lastTextBaseline) {
                    Text(account.crystalName.map { $0.isEmpty ? "TRAINER" : $0 } ?? account.name)
                        .font(.system(size: 16, weight: .heavy)).tracking(1.5).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Text(account.crystalID.map { "ID \(trainerID($0))" } ?? "NOT LINKED")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced)).opacity(0.9)
                }
            }
            .padding(14)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
            .frame(width: 250, height: 162, alignment: .topLeading)
            .background(Group {
                if !debt, let img = art.images[kind.capitalized] {          // custom art replaces the built-in wallpaper
                    ZStack {
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(nsImage: img).resizable().interpolation(.high)
                    }
                }
                else if let k = wallpaper { LandscapeBackground(kind: k, debt: debt, colors: colors) }
                else { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
            }.clipShape(RoundedRectangle(cornerRadius: 14)))
            // raised look: light rim on top, soft drop shadow underneath
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 2)
            .shadow(color: .black.opacity(0.35), radius: 4, x: 3, y: 6)
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

struct DebitCardView: View {
    @EnvironmentObject var bank: Bank
    let account: Account
    let action: () -> Void
    var body: some View {
        let debt = account.balance < 0
        BankCardFace(kind: "WATT", logo: "logo", wallpaper: debt ? nil : .bolt,
                     barTint: debt ? Color(red: 1, green: 0.62, blue: 0.62) : Color(red: 1, green: 0.93, blue: 0.6),
                     barInk: debt ? Color(red: 0.45, green: 0.05, blue: 0.05) : Color(red: 0.45, green: 0.32, blue: 0.0),
                     colors: debt ? [Color(red: 0.75, green: 0.15, blue: 0.15), Color(red: 0.45, green: 0.05, blue: 0.05)]
                                  : [Color(red: 0.98, green: 0.78, blue: 0.2), Color(red: 0.78, green: 0.55, blue: 0.05)],
                     amount: account.balance, account: account, action: action) {
            Text(debt ? "owed · press P to top up" : "balance").font(.system(size: 10)).opacity(0.9)
        }
    }
}

struct CreditCardView: View {
    @EnvironmentObject var bank: Bank
    let account: Account
    let action: () -> Void
    var body: some View {
        let owed = bank.owed(account)
        let due = bank.nextDue(account)
        BankCardFace(kind: "CREDIT", tag: "LV \(bank.creditLevel(account))", logo: "credit_logo", wallpaper: .water,
                     barTint: Color(red: 0.7, green: 0.84, blue: 1), barInk: Color(red: 0.06, green: 0.2, blue: 0.5),
                     colors: [Color(red: 0.32, green: 0.6, blue: 1), Color(red: 0.1, green: 0.28, blue: 0.72)],   // GSC-button blue: Credit is for spending
                     amount: bank.maxBorrow(account), unit: "", prefix: "₽", account: account, action: action) {
            if owed > 0, let d = due {
                Text("available · owes ₽\(fmt(owed)) · " + (d.late ? "LATE" : "due \(d.due.formatted(.dateTime.month(.abbreviated).day()))"))
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .foregroundColor(d.late ? Color(red: 1, green: 0.85, blue: 0.85) : .white)
            } else {
                Text("available · limit ₽\(fmt(bank.creditLimit(account)))").font(.system(size: 10)).opacity(0.9)
            }
        }
        .help("Loans are in PokéDollars and are paid off with the Debit card. Each loan: 10% once. 7 days to repay, then one more 10% and the level drops. Repaying on time raises the level (limit doubles).")
    }
}

/// Calories card: exercise calories from Apple Health (via the iPhone Shortcut), waiting to become watts.
struct CaloriesCardView: View {
    @EnvironmentObject var bank: Bank
    let account: Account
    let action: () -> Void
    var body: some View {
        BankCardFace(kind: "CALORIES", logo: "calories_logo", wallpaper: .fire,
                     barTint: Color(red: 1, green: 0.8, blue: 0.55), barInk: Color(red: 0.5, green: 0.12, blue: 0.02),
                     colors: [Color(red: 1, green: 0.55, blue: 0.15), Color(red: 0.75, green: 0.2, blue: 0.05)],
                     amount: Int(bank.calories.rounded(.down)), unit: "kcal", account: account, action: action) {
            Text(bank.data.calorieRate == nil ? "waiting for the iPhone sync"
                 : "≈ \(fmt(bank.calorieWatts)) W · \(String(format: "%.2f", bank.calorieRate)) kcal per W")
                .font(.system(size: 10)).opacity(0.9).lineLimit(1).minimumScaleFactor(0.8)
        }
        .help("Exercise calories from Apple Health. Click it (or press / or K) to top up Watt or pay off Credit.")
    }
}

/// Top up this account's Debit card: from Calories, a Credit advance, another account's Debit, or a deposit.
struct TopUpSheet: View {
    @EnvironmentObject var bank: Bank
    let account: UUID
    var buyOnly = false                   // "Buy Watts": pay with the Debit or Credit card only
    let done: (Bool) -> Void              // true = start a Deposit
    enum Source: Hashable { case calories, cash, credit, account(UUID), deposit }
    @State private var method = 0
    @State private var amount = 0
    @State private var held = 0
    @State private var typing = false        // typing digits replaces the amount
    @FocusState private var focused: Bool
    var ai: Int { bank.data.accounts.firstIndex { $0.id == account } ?? 0 }
    var me: Account { bank.data.accounts[ai] }
    var debt: Int { max(0, -me.balance) }
    var sources: [Source] {
        var out: [Source] = []
        if bank.calorieWatts > 0 { out.append(.calories) }
        if bank.cashWatts > 0 { out.append(.cash) }
        if bank.maxBorrowW(me) > 0 { out.append(.credit) }
        for a in bank.data.accounts where a.id != account && a.balance > 0 { out.append(.account(a.id)) }
        if buyOnly { return out.filter { $0 == .cash || $0 == .credit } }
        return out + [.deposit]
    }
    var source: Source { sources[min(method, sources.count - 1)] }
    func top(_ s: Source) -> Int {
        switch s {
        case .calories: return bank.calorieWatts
        case .cash: return bank.cashWatts
        case .credit: return bank.maxBorrowW(me)
        case .account(let id): return bank.data.accounts.first { $0.id == id }?.balance ?? 0
        case .deposit: return 0
        }
    }
    var top: Int { top(source) }
    func clamp(_ v: Int) -> Int { min(max(top > 0 ? 1 : 0, v), top) }
    func start() -> Int { debt > 0 ? min(debt, top) : top }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WattBankLogo(size: 26, name: "debit_logo")
                Text(buyOnly ? "Buy Watts" : "Top up the Watt card").font(.system(size: 17, weight: .bold))
                Spacer()
                Text(debt > 0 ? "Owes \(fmt(debt)) W" : "\(fmt(me.balance)) W now").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(debt > 0 ? .wbRed : .wbGreen)
            }
            Text("Top up from:").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            VStack(spacing: 4) {
                ForEach(Array(sources.enumerated()), id: \.offset) { m, s in
                    let on = m == min(method, sources.count - 1)
                    Button { method = m; amount = start(); typing = false; focused = true } label: {
                        HStack {
                            switch s {
                            case .calories:
                                Image(systemName: "flame.fill"); Text("Calories card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("\(fmt(Int(bank.calories))) kcal ≈ \(fmt(bank.calorieWatts)) W").font(.system(size: 12, design: .rounded))
                            case .cash:
                                Image(systemName: "dollarsign.circle.fill"); Text("Debit card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(bank.cash)) ≈ \(fmt(bank.cashWatts)) W").font(.system(size: 12, design: .rounded))
                            case .credit:
                                Image(systemName: "creditcard.fill"); Text("Credit card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(bank.maxBorrow(me))) available · 10% fee").font(.system(size: 12, design: .rounded))
                            case .account(let id):
                                let a = bank.data.accounts.first { $0.id == id }
                                Image(systemName: "banknote"); Text("\(a?.name ?? "")'s Watt card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("\(fmt(a?.balance ?? 0)) W").font(.system(size: 12, design: .rounded))
                            case .deposit:
                                Image(systemName: "figure.walk"); Text("Walk it off: deposit watts").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("Pikachu or Game Boy").font(.system(size: 11))
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.wbGreen : Color.primary.opacity(0.06)))
                        .foregroundColor(on ? .white : .primary)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            if source == .deposit {
                Text("Opens Deposit. The watts go to the Watt card.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                HStack {
                    Text("Amount:").font(.system(size: 12, weight: .semibold))
                    AmountField(text: "\(fmt(amount)) W", typing: typing)
                    Text(note).font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Text("↑ ↓ choose   ← → amount (hold to speed up, ⇧ = min/max) or type it   Return = top up   Esc = cancel")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack { Spacer()
                Button("Cancel") { done(false) }
                Button(source == .deposit ? "Start Deposit" : "Top up \(fmt(amount)) W") { go() }
                    .buttonStyle(.borderedProminent).tint(.wbGreen)
            }
        }
        .padding(22).frame(width: 490)
        .foregroundStyle(.primary)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; amount = start() }
        .onAppear { AmountKeys.handler = { c, back in var a = amount, t = typing; let ok = typeAmountChar(c, back, &a, &t, top); amount = a; typing = t; return ok } }
        .onDisappear { AmountKeys.handler = nil }
        .onKeyPress(phases: [.down, .repeat]) { k in
            held = k.phase == .repeat ? held + 1 : 0
            if [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow].contains(k.key) { typing = false }
            let step = held > 40 ? 100 : held > 15 ? 10 : 1
            let shift = k.modifiers.contains(.shift)
            switch k.key {
            case .escape: done(false)
            case .return: go()
            case .downArrow: method = min(method + 1, sources.count - 1); amount = start()
            case .upArrow: method = max(min(method, sources.count - 1) - 1, 0); amount = start()
            case .rightArrow: amount = shift ? top : clamp(amount + step)
            case .leftArrow: amount = shift ? clamp(1) : clamp(amount - step)
            default: return typeAmount(k, &amount, &typing, top) ? .handled : .ignored
            }
            return .handled
        }
    }

    var note: String {
        switch source {
        case .calories: return "= \(fmt(Int((Double(amount) * bank.calorieRate).rounded()))) kcal"
        case .cash: return "= ₽\(fmt(bank.cashCost(amount)))"
        case .credit: let p = pdCost(ofW: amount); return "you'll owe ₽\(fmt(p + Int((Double(p) * CreditRules.fee).rounded(.up)))) in 7 days"
        default: return debt > 0 && amount >= debt ? "clears the debt" : ""
        }
    }

    func go() {
        let s = source, w = clamp(amount), a = ai
        if s == .deposit { done(true); return }
        done(false)
        guard w > 0 else { return }
        DispatchQueue.main.async {
            switch s {
            case .calories: bank.caloriesToDebit(w, on: a)
            case .cash: bank.cashToDebit(w, on: a)
            case .credit: bank.cashAdvance(on: a, w)
            case .account(let id): if let f = bank.data.accounts.firstIndex(where: { $0.id == id }) { bank.move(w, from: f, to: a) }
            case .deposit: break
            }
        }
    }
}

/// Cash card: PokéDollars moved out of game saves (any generation), worth 0.83 W per ₽.
struct CashCardView: View {
    @EnvironmentObject var bank: Bank
    let account: Account
    let action: () -> Void
    var body: some View {
        BankCardFace(kind: "DEBIT", logo: "debit_logo", wallpaper: .grass,
                     barTint: Color(red: 0.62, green: 0.9, blue: 0.62), barInk: Color(red: 0.05, green: 0.33, blue: 0.15),
                     colors: [Color(red: 0.15, green: 0.65, blue: 0.32), Color(red: 0.05, green: 0.38, blue: 0.2)],
                     amount: account.cash ?? 0, unit: "", prefix: "₽", account: account, action: action) {
            Text((account.cash ?? 0) > 0 ? "≈ \(fmt(bank.watts(forCash: account.cash ?? 0))) W · 0.83 W per ₽" : "drop a save here, or press $ or M")
                .font(.system(size: 10)).opacity(0.9).lineLimit(1).minimumScaleFactor(0.8)
        }
        .help("PokéDollars moved out of your game saves. Click it (or press $ or M) to top up from a save, top up Watt or pay off Credit.")
    }
}

/// Reads the start option when the sheet opens (a plain value would be captured stale by .sheet).
struct CashSheetHost: View {
    let account: UUID
    @Binding var start: CashSheet.Start
    let done: () -> Void
    var body: some View { CashSheet(account: account, start: start, done: done) }
}

/// Trainer card: the PokéDollars in the loaded save's wallet, live from the file.
struct TrainerCardView: View {
    @EnvironmentObject var bank: Bank
    let account: Account
    let action: () -> Void
    var body: some View {
        let i = bank.currentSave
        BankCardFace(kind: "TRAINER", tag: i?.generation.map { "GEN \($0)" }, logo: "trainer_logo", wallpaper: .ball,
                     barTint: Color(red: 0.86, green: 0.88, blue: 0.92), barInk: Color(red: 0.2, green: 0.24, blue: 0.32),
                     colors: [Color(red: 0.55, green: 0.6, blue: 0.68), Color(red: 0.28, green: 0.32, blue: 0.4)],
                     amount: i?.money ?? 0, unit: "", prefix: "₽", account: account, action: action) {
            Text(i == nil ? "no save loaded · drop one on Watt Bank" : "in \(SaveTool.gameName(i?.game ?? "")) · click to move")
                .font(.system(size: 10)).opacity(0.9).lineLimit(1).minimumScaleFactor(0.8)
        }
        .opacity(i == nil ? 0.45 : 1).allowsHitTesting(i != nil)
        .help("The money your trainer carries in the loaded save. Click to move some to Debit.")
    }
}

/// Mom card: Mom's savings in the loaded save (Gold/Silver/Crystal, HeartGold/SoulSilver).
struct MomCardView: View {
    @EnvironmentObject var bank: Bank
    let account: Account
    let action: () -> Void
    var body: some View {
        let i = bank.currentSave
        BankCardFace(kind: "MOM", tag: i?.generation.map { "GEN \($0)" }, logo: "mom_logo", wallpaper: .hearts,
                     barTint: Color(red: 1, green: 0.8, blue: 0.9), barInk: Color(red: 0.55, green: 0.1, blue: 0.35),
                     colors: [Color(red: 0.98, green: 0.55, blue: 0.75), Color(red: 0.8, green: 0.3, blue: 0.55)],
                     amount: i?.momMoney ?? 0, unit: "", prefix: "₽", account: account, action: action) {
            Text(i == nil ? "no save loaded" : i?.momMoney == nil ? "no Mom's savings in \(SaveTool.gameName(i?.game ?? ""))" : "Mom's savings · click to move")
                .font(.system(size: 10)).opacity(0.9).lineLimit(1).minimumScaleFactor(0.8)
        }
        .opacity(i?.momMoney == nil ? 0.45 : 1).allowsHitTesting(i?.momMoney != nil)
        .help("Money Mom is saving for you in the loaded save. Click to move some to Debit.")
    }
}

/// Hearts along the bottom of the Mom card, in rows like the other cards' horizons.
struct HeartsBackground: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                ForEach(0..<20, id: \.self) { n in
                    let row = n % 3
                    let x = (CGFloat((n * 37) % 100) / 100) * w
                    let y = h * (0.7 + CGFloat(row) * 0.12) + CGFloat((n * 13) % 9) - 4
                    let size = CGFloat(14 + (n * 7) % 12) + CGFloat(row) * 4
                    Image(systemName: "heart.fill")
                        .font(.system(size: size))
                        .foregroundStyle(row == 2 ? Color.white.opacity(0.4) : row == 1 ? Color(red: 1, green: 0.75, blue: 0.88).opacity(0.6)
                                                  : Color(red: 0.75, green: 0.2, blue: 0.48).opacity(0.6))
                        .rotationEffect(.degrees(Double((n * 23) % 40) - 20))
                        .position(x: x, y: y)
                }
            }
        }
    }
}

/// Trainer or Mom card clicked: move that money somewhere else (never to itself).
struct SaveMoneySheet: View {
    @EnvironmentObject var bank: Bank
    enum Source: String, Identifiable { case trainer, mom; var id: String { rawValue } }
    enum Dest: Hashable { case cash, fromCash, other, fromOther, debit }
    let source: Source
    let done: () -> Void
    @State private var method = 0
    @State private var amount = 0
    @State private var held = 0
    @State private var typing = false        // typing digits replaces the amount
    @State private var busy = false
    @State private var message: String? = nil
    @FocusState private var focused: Bool
    var a: Int { bank.data.active }
    var path: String? { bank.current.savePath }
    var info: SaveInfo? { bank.currentSave }
    var have: Int { (source == .trainer ? info?.money : info?.momMoney) ?? 0 }
    var name: String { source == .trainer ? "Trainer" : "Mom" }
    var otherName: String { source == .trainer ? "Mom" : "Trainer" }
    /// Both ways with the Debit card and (when the game has one) the other in-game card. Only the Debit card trades ₽ for watts.
    var dests: [Dest] { [.cash, .fromCash] + (info?.momMoney != nil ? [.other, .fromOther] : []) }
    var dest: Dest { dests[min(method, dests.count - 1)] }
    var otherHave: Int { (source == .trainer ? info?.momMoney : info?.money) ?? 0 }
    var room: Int { (source == .trainer ? (info?.maxMoney ?? 999_999) : 999_999) - have }          // space left on this card
    var otherRoom: Int { (source == .trainer ? 999_999 : (info?.maxMoney ?? 999_999)) - otherHave }
    var top: Int { topFor(dest) }
    func topFor(_ d: Dest) -> Int {
        switch d {
        case .cash: return have
        case .fromCash: return max(0, min(bank.cash, room))
        case .other: return max(0, min(have, otherRoom))
        case .fromOther: return max(0, min(otherHave, room))
        case .debit: return have
        }
    }
    func clamp(_ v: Int) -> Int { min(max(top > 0 ? 1 : 0, v), top) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WattBankLogo(size: 26, name: source == .mom ? "mom_logo" : "trainer_logo")
                Text(source == .mom ? "Mom card" : "Trainer card").font(.system(size: 17, weight: .bold))
                Spacer()
                Text("₽\(fmt(have)) in \(SaveTool.gameName(info?.game ?? ""))").font(.system(size: 13, weight: .semibold)).foregroundColor(.wbOrange)
            }
            Text("Move:").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            VStack(spacing: 4) {
                ForEach(Array(dests.enumerated()), id: \.offset) { m, d in
                    let on = m == min(method, dests.count - 1)
                    Button { method = m; amount = top; typing = false; focused = true } label: {
                        HStack {
                            switch d {
                            case .cash:
                                Image(systemName: "arrow.right.circle.fill"); Text("To Debit card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(bank.cash)) there now").font(.system(size: 12, design: .rounded))
                            case .fromCash:
                                Image(systemName: "arrow.left.circle.fill"); Text("From Debit card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(bank.cash)) there now").font(.system(size: 12, design: .rounded))
                            case .other:
                                Image(systemName: "arrow.right.circle.fill")
                                Text("To " + (source == .trainer ? "Mom card" : "Trainer card")).font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(otherHave)) there now").font(.system(size: 12, design: .rounded))
                            case .fromOther:
                                Image(systemName: "arrow.left.circle.fill")
                                Text("From " + (source == .trainer ? "Mom card" : "Trainer card")).font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(otherHave)) there now").font(.system(size: 12, design: .rounded))
                            case .debit:
                                Image(systemName: "bolt.fill"); Text("Watt card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("\(fmt(bank.current.balance)) W now").font(.system(size: 12, design: .rounded))
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.wbOrange : Color.primary.opacity(0.06)))
                        .foregroundColor(on ? .white : .primary)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Text("Amount:").font(.system(size: 12, weight: .semibold))
                AmountField(text: "₽\(fmt(amount))", typing: typing)
                if dest == .debit { Text("= \(fmt(bank.watts(forCash: amount))) W").font(.system(size: 11)).foregroundColor(.secondary) }
            }
            if top == 0 { Text("Nothing to move this way right now. Press ↑ ↓ to pick another.").font(.system(size: 12, weight: .semibold)).foregroundColor(.wbRed) }
            Text(saveTip(path))
                .font(.system(size: 11)).foregroundColor(.secondary)
            if let m = message { Text(m).font(.system(size: 12, weight: .semibold)).foregroundColor(.wbRed) }
            Text("↑ ↓ choose   ← → amount (hold to speed up, ⇧ = min/max) or type it   Return = move   Esc = close")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack { Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Close") { done() }
                Button("Move ₽\(fmt(amount))") { go() }.buttonStyle(.borderedProminent).tint(.wbOrange).disabled(busy || amount == 0)
            }
        }
        .padding(22).frame(width: 520)
        .foregroundStyle(.primary)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear {
            focused = true
            if topFor(dest) == 0, let m = dests.firstIndex(where: { topFor($0) > 0 }) { method = m }   // start where there's money to move
            amount = top
        }
        .onAppear { AmountKeys.handler = { c, back in var a = amount, t = typing; let ok = typeAmountChar(c, back, &a, &t, top); amount = a; typing = t; return ok } }
        .onDisappear { AmountKeys.handler = nil }
        .onKeyPress(phases: [.down, .repeat]) { k in
            held = k.phase == .repeat ? held + 1 : 0
            if [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow].contains(k.key) { typing = false }
            let step = held > 40 ? 10_000 : held > 25 ? 1_000 : held > 10 ? 100 : 10
            let shift = k.modifiers.contains(.shift)
            switch k.key {
            case .escape: done()
            case .return: go()
            case .downArrow: method = min(method + 1, dests.count - 1); amount = top
            case .upArrow: method = max(min(method, dests.count - 1) - 1, 0); amount = top
            case .rightArrow: amount = shift ? top : clamp(amount + step)
            case .leftArrow: amount = shift ? clamp(1) : clamp(amount - step)
            default: return typeAmount(k, &amount, &typing, top) ? .handled : .ignored
            }
            return .handled
        }
    }

    func go() {
        guard !busy, let p = path, amount > 0 else { return }
        let w = clamp(amount), d = dest, k = a
        let ref = SaveRef(path: p, game: info?.game ?? "?", trainer: info?.trainer ?? "", tid: info?.tidText ?? "")
        let verb: String = {
            switch d {
            case .other: return source == .trainer ? "t2m" : "m2t"
            case .fromOther: return source == .trainer ? "m2t" : "t2m"
            case .fromCash: return source == .trainer ? "give" : "givemom"
            default: return source == .trainer ? "take" : "takemom"
            }
        }()
        busy = true; message = nil
        Task {
            let r = await SaveTool.run([verb, p, String(w)])
            busy = false
            guard r.ok, let moved = r.moved else { message = r.error ?? "Couldn't change the save."; return }
            switch d {
            case .cash: bank.addCash(moved, from: ref, on: k)
            case .debit: bank.saveToDebit(moved, from: "\(name) (\(SaveTool.gameName(ref.game)))", on: k)
            case .fromCash: bank.cashToSave(moved, card: "\(name) card", game: ref.game, path: p, on: k)
            case .other, .fromOther:
                let (f, t) = d == .other ? (name, otherName) : (otherName, name)
                bank.data.accounts[k].history.insert(Entry(date: Date(), kind: "\(f) → \(t) ₽\(fmt(moved)) (\(SaveTool.gameName(ref.game)))", amount: 0), at: 0)
                bank.save()
            }
            bank.refreshSave(p, force: true)
            NSSound(named: "Glass")?.play()
            done()
        }
    }
}

/// Cash: move PokéDollars out of a save file, or spend Cash on Debit / Credit.
struct CashSheet: View {
    @EnvironmentObject var bank: Bank
    let account: UUID
    var start: Start = .none
    let done: () -> Void
    enum Start { case none, trainer, mom, buyWatts, sellWatts }
    enum Option: Hashable { case save(String), mom(String), toTrainer, toMom, fromWatt, choose, debit, credit }
    @State private var method = 0
    @State private var amount = 0
    @State private var held = 0
    @State private var typing = false        // typing digits replaces the amount
    @State private var infos: [String: SaveInfo] = [:]
    @State private var busy = false
    @State private var message: String? = nil
    @FocusState private var focused: Bool
    var ai: Int { bank.data.active }
    var owed: Int { bank.owed(bank.data.accounts[ai]) }
    var saves: [SaveRef] { bank.data.saveFiles ?? [] }
    var options: [Option] {
        // the loaded save's Trainer and Mom cards, both ways; then other ways to top up / spend Cash
        var o: [Option] = []
        if let p = bank.current.savePath, let i = infos[p], i.ok {
            o.append(.save(p))
            if i.momMoney != nil { o.append(.mom(p)) }
            if bank.cash > 0 { o.append(.toTrainer); if i.momMoney != nil { o.append(.toMom) } }
        }
        let all = o + (bank.cashFromWatts > 0 ? [.fromWatt] : []) + [.choose] + (bank.cashWatts > 0 ? [.debit] : []) + (bank.cash > 0 && owed > 0 ? [.credit] : [])
        switch start {                                   // opened for one job: show only that
        case .sellWatts: return [.fromWatt]
        case .buyWatts: return [.debit]
        default:                                         // Debit card: transfers only (Trainer/Mom ⇄ Debit, pay off Credit); Watt ⇄ Debit is an exchange
            let t = all.filter { o in
                switch o { case .choose, .fromWatt, .debit: return false; default: return true }
            }
            return t.isEmpty ? [.choose] : t             // nothing to transfer yet: offer loading a save
        }
    }
    var option: Option { options[min(method, options.count - 1)] }
    func top(_ o: Option) -> Int {
        switch o {
        case .save(let p): return infos[p]?.money ?? 0
        case .mom(let p): return infos[p]?.momMoney ?? 0
        case .toTrainer: let i = bank.current.savePath.flatMap { infos[$0] }; return min(bank.cash, (i?.maxMoney ?? 999_999) - (i?.money ?? 0))
        case .toMom: let i = bank.current.savePath.flatMap { infos[$0] }; return min(bank.cash, 999_999 - (i?.momMoney ?? 0))
        case .choose: return 0
        case .debit: return bank.cashWatts
        case .fromWatt: return bank.cashFromWatts > 0 ? max(0, bank.current.balance) : 0   // in watts
        case .credit: return min(bank.cash, owed)
        }
    }
    var top: Int { top(option) }
    func clamp(_ v: Int) -> Int { min(max(top > 0 ? 1 : 0, v), top) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WattBankLogo(size: 26)
                Text(start == .sellWatts ? "Sell Watts" : "Debit").font(.system(size: 17, weight: .bold))
                Spacer()
                Text("₽\(fmt(bank.cash)) ≈ \(fmt(bank.cashWatts)) W").font(.system(size: 13, weight: .semibold)).foregroundColor(.wbOrange)
            }
            Text(start == .sellWatts ? "Watt card → Debit card, 0.83 W per ₽:" : "Transfer with the Trainer or Mom card, or pay off Credit:").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            VStack(spacing: 4) {
                ForEach(Array(options.enumerated()), id: \.offset) { m, o in
                    let on = m == min(method, options.count - 1)
                    Button { method = m; amount = top; typing = false; focused = true } label: {
                        HStack {
                            switch o {
                            case .save(let p):
                                Image(systemName: "person.fill"); Text("From Trainer card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(infos[p]?.money ?? 0)) in \(SaveTool.gameName(infos[p]?.game ?? ""))").font(.system(size: 12, design: .rounded))
                            case .mom(let p):
                                Image(systemName: "house.fill"); Text("From Mom card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(infos[p]?.momMoney ?? 0)) with Mom").font(.system(size: 12, design: .rounded))
                            case .toTrainer:
                                Image(systemName: "person.fill"); Text("To Trainer card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(bank.cash)) in Debit").font(.system(size: 12, design: .rounded))
                            case .toMom:
                                Image(systemName: "house.fill"); Text("To Mom card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("₽\(fmt(bank.cash)) in Debit").font(.system(size: 12, design: .rounded))
                            case .choose:
                                Image(systemName: "folder"); Text("Choose a save file…").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("any generation").font(.system(size: 11))
                            case .fromWatt:
                                Image(systemName: "bolt.fill"); Text("From Watt card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("\(fmt(bank.current.balance)) W ≈ ₽\(fmt(bank.cashFromWatts))").font(.system(size: 12, design: .rounded))
                            case .debit:
                                Image(systemName: "banknote"); Text("To Watt card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("\(fmt(bank.data.accounts[ai].balance)) W now").font(.system(size: 12, design: .rounded))
                            case .credit:
                                Image(systemName: "creditcard.fill"); Text("Pay off the Credit card").font(.system(size: 13, weight: .semibold))
                                Spacer(); Text("owes ₽\(fmt(owed))").font(.system(size: 12, design: .rounded))
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.wbOrange : Color.primary.opacity(0.06)))
                        .foregroundColor(on ? .white : .primary)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            switch option {
            case .choose:
                Text("Pick a save from a cartridge dump, an emulator, a 3DS or a Switch. Close the game or emulator first.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            case .save, .mom:
                HStack {
                    Text("Move:").font(.system(size: 12, weight: .semibold))
                    AmountField(text: "₽\(fmt(amount))", typing: typing)
                    Text((isMom ? "Mom card" : "Trainer card") + " → Debit").font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text(saveTip(bank.current.savePath))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            case .fromWatt:
                HStack {
                    Text("Sell:").font(.system(size: 12, weight: .semibold))
                    AmountField(text: "\(fmt(amount)) W", typing: typing)
                    Text("you get ₽\(fmt(pdValue(ofW: amount))) on the Debit card (0.83 W per ₽)").font(.system(size: 11)).foregroundColor(.secondary)
                }
            case .toTrainer, .toMom:
                HStack {
                    Text("Move:").font(.system(size: 12, weight: .semibold))
                    AmountField(text: "₽\(fmt(amount))", typing: typing)
                    Text("Debit → " + (option == .toMom ? "Mom card" : "Trainer card")).font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text(saveTip(bank.current.savePath))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            case .credit:
                HStack {
                    Text("Pay:").font(.system(size: 12, weight: .semibold))
                    AmountField(text: "₽\(fmt(amount))", typing: typing)
                    Text(amount >= owed ? "pays the Credit card off" : "₽\(fmt(owed - amount)) left after").font(.system(size: 11)).foregroundColor(.secondary)
                }
            default:
                HStack {
                    Text("Amount:").font(.system(size: 12, weight: .semibold))
                    AmountField(text: "\(fmt(amount)) W", typing: typing)
                    Text("= ₽\(fmt(bank.cashCost(amount)))").font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            if let m = message { Text(m).font(.system(size: 12, weight: .semibold)).foregroundColor(.wbRed) }
            Text("↑ ↓ choose   ← → amount (hold to speed up, ⇧ = min/max) or type it   Return = go   Esc = close")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack { Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Close") { done() }
                Button(goTitle) { go() }.buttonStyle(.borderedProminent).tint(.wbOrange).disabled(busy)
            }
        }
        .padding(22).frame(width: 520)
        .foregroundStyle(.primary)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear {
            focused = true
            infos = bank.saveInfo
            if start == .buyWatts, let m = options.firstIndex(of: .debit) { method = m }
            else if start == .sellWatts, let m = options.firstIndex(of: .fromWatt) { method = m }
            else if let p = bank.current.savePath, start == .trainer || start == .mom,
               let m = options.firstIndex(of: start == .mom ? .mom(p) : .save(p)) { method = m }
            if top == 0, let m = options.firstIndex(where: { top($0) > 0 }) { method = m }   // start where there's money to move
            amount = top
            for r in saves { load(r.path) }
        }
        .onAppear { AmountKeys.handler = { c, back in var a = amount, t = typing; let ok = typeAmountChar(c, back, &a, &t, top); amount = a; typing = t; return ok } }
        .onDisappear { AmountKeys.handler = nil }
        .onKeyPress(phases: [.down, .repeat]) { k in
            held = k.phase == .repeat ? held + 1 : 0
            if [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow].contains(k.key) { typing = false }
            let isSave: Bool = { switch option { case .save, .mom, .toTrainer, .toMom, .fromWatt, .credit: return true; default: return false } }()
            let step = isSave ? (held > 40 ? 10_000 : held > 25 ? 1_000 : held > 10 ? 100 : 10) : (held > 40 ? 100 : held > 15 ? 10 : 1)
            let shift = k.modifiers.contains(.shift)
            switch k.key {
            case .escape: done()
            case .return: go()
            case .downArrow: method = min(method + 1, options.count - 1); amount = top
            case .upArrow: method = max(min(method, options.count - 1) - 1, 0); amount = top
            case .rightArrow: amount = shift ? top : clamp(amount + step)
            case .leftArrow: amount = shift ? clamp(1) : clamp(amount - step)
            default: return typeAmount(k, &amount, &typing, top) ? .handled : .ignored
            }
            return .handled
        }
    }

    var isMom: Bool { if case .mom = option { return true }; return false }
    var goTitle: String {
        switch option {
        case .choose: return "Choose…"
        case .save, .mom, .toTrainer, .toMom: return "Move ₽\(fmt(amount))"
        case .debit: return "Top up \(fmt(amount)) W"
        case .fromWatt: return "Sell \(fmt(amount)) W"
        case .credit: return "Pay ₽\(fmt(amount))"
        }
    }

    func load(_ path: String) {
        Task { let i = await SaveTool.run(["info", path]); infos[path] = i; if case .save(let p) = option, p == path { amount = top } }
    }

    func go() {
        guard !busy else { return }
        message = nil
        switch option {
        case .choose:
            let panel = NSOpenPanel()
            panel.title = "Choose a Pokémon save file"
            panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            busy = true
            Task {
                let i = await SaveTool.run(["info", url.path])
                busy = false
                guard i.ok else { message = i.error ?? "Not a save file Watt Bank can read."; return }
                let (k, _) = bank.accountForTrainer(name: i.trainer ?? "", tid: i.tid ?? 0)
                bank.select(k)
                bank.rememberSave(SaveRef(path: url.path, game: i.game ?? "?", trainer: i.trainer ?? "", tid: i.tidText))
                bank.linkSave(url.path, to: k, info: i)
                infos[url.path] = i
                method = 0; amount = i.money ?? 0
            }
        case .save(let p), .mom(let p):
            let w = clamp(amount)
            guard w > 0, let ref = saves.first(where: { $0.path == p }) else { return }
            busy = true
            let verb = isMom ? "takemom" : "take"
            Task {
                let r = await SaveTool.run([verb, p, String(w)])
                busy = false
                guard r.ok, let moved = r.moved else { message = r.error ?? "Couldn't change the save."; return }
                let (k, _) = bank.accountForTrainer(name: ref.trainer, tid: UInt32(ref.tid) ?? 0)   // same trainer name + ID, or a new account
                bank.select(k)
                bank.addCash(moved, from: ref, on: k)
                if bank.data.accounts[k].savePath == nil { bank.data.accounts[k].savePath = p }
                bank.refreshSave(p, force: true)
                NSSound(named: "Glass")?.play()
                load(p)
                done()
            }
        case .toTrainer, .toMom:
            guard let p = bank.current.savePath else { return }
            let w = clamp(amount), a = ai, toMom = option == .toMom
            guard w > 0 else { return }
            busy = true
            Task {
                let r = await SaveTool.run([toMom ? "givemom" : "give", p, String(w)])
                busy = false
                guard r.ok, let moved = r.moved else { message = r.error ?? "Couldn't change the save."; return }
                bank.cashToSave(moved, card: toMom ? "Mom card" : "Trainer card", game: infos[p]?.game ?? "", path: p, on: a)
                bank.refreshSave(p, force: true)
                NSSound(named: "Glass")?.play()
                done()
            }
        case .fromWatt:
            let p = pdValue(ofW: clamp(amount)), a = ai; done()
            if p > 0 { DispatchQueue.main.async { bank.wattsToCash(p, on: a) } }
        case .debit:
            let w = clamp(amount), a = ai; done()
            DispatchQueue.main.async { bank.cashToDebit(w, on: a) }
        case .credit:
            let w = clamp(amount), a = ai; done()
            DispatchQueue.main.async { bank.cashToCredit(w, on: a) }
        }
    }
}

/// Spend the Calories card: top up this account's Debit card, or pay off its Credit card.
struct CaloriesSheet: View {
    @EnvironmentObject var bank: Bank
    let account: UUID
    let done: () -> Void
    @State private var method = 0          // 0 = Debit, 1 = Credit
    @State private var amount = 0
    @State private var held = 0
    @State private var typing = false        // typing digits replaces the amount
    @FocusState private var focused: Bool
    var ai: Int { bank.data.accounts.firstIndex { $0.id == account } ?? 0 }
    var owed: Int { bank.owed(bank.data.accounts[ai]) }
    var top: Int { method == 0 ? bank.calorieWatts : min(bank.calorieWatts, owed) }
    func clamp(_ v: Int) -> Int { min(max(top > 0 ? 1 : 0, v), top) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WattBankLogo(size: 26, name: "calories_logo")
                Text("Use Calories").font(.system(size: 17, weight: .bold))
                Spacer()
                Text("\(fmt(Int(bank.calories))) kcal ≈ \(fmt(bank.calorieWatts)) W").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.wbOrange)
            }
            if bank.calorieWatts == 0 {
                Text(bank.data.calorieRate == nil
                     ? "No calories yet. Run “Watt Bank Health Sync” on the iPhone; new exercise lands here."
                     : "Not enough calories for 1 W yet (\(String(format: "%.2f", bank.calorieRate)) kcal per W). Keep moving.")
                    .font(.system(size: 13))
                ShortcutSetupBox()
                HStack { Spacer(); Button("Close  (Esc)") { done() } }
            } else {
                Text("Use them to:").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                VStack(spacing: 4) {
                    row(0, "banknote", "Top up the Watt card", "\(fmt(bank.data.accounts[ai].balance)) W now")
                }
                HStack {
                    Text("Amount:").font(.system(size: 12, weight: .semibold))
                    AmountField(text: "\(fmt(amount)) W", typing: typing)
                    Text("= \(fmt(Int((Double(amount) * bank.calorieRate).rounded()))) kcal" +
                         (method == 1 && amount >= owed && owed > 0 ? " · pays it all off" : ""))
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Text("↑ ↓ choose   ← → amount (hold to speed up, ⇧ = min/max) or type it   Return = use   Esc = cancel")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack { Spacer()
                    Button("Cancel") { done() }
                    Button(method == 0 ? "Top up \(fmt(amount)) W" : "Pay \(fmt(amount)) W") { use() }
                        .buttonStyle(.borderedProminent).tint(.wbOrange).disabled(amount == 0)
                }
                ShortcutSetupBox()
            }
        }
        .padding(22).frame(width: 470)
        .foregroundStyle(.primary)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; amount = top }
        .onAppear { AmountKeys.handler = { c, back in var a = amount, t = typing; let ok = typeAmountChar(c, back, &a, &t, top); amount = a; typing = t; return ok } }
        .onDisappear { AmountKeys.handler = nil }
        .onKeyPress(phases: [.down, .repeat]) { k in
            held = k.phase == .repeat ? held + 1 : 0
            if [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow].contains(k.key) { typing = false }
            let step = held > 40 ? 100 : held > 15 ? 10 : 1
            let shift = k.modifiers.contains(.shift)
            switch k.key {
            case .escape: done()
            case .return: if bank.calorieWatts > 0 { use() } else { done() }
            case .downArrow: amount = top
            case .upArrow: method = 0; amount = top
            case .rightArrow: amount = shift ? top : clamp(amount + step)
            case .leftArrow: amount = shift ? clamp(1) : clamp(amount - step)
            default:
                if k.characters.lowercased() == "a" { Bundled.addShortcut(); return .handled }
                if k.characters.lowercased() == "h" { NotificationCenter.default.post(name: .showShortcutGuide, object: nil); return .handled }
                return typeAmount(k, &amount, &typing, top) ? .handled : .ignored
            }
            return .handled
        }
    }

    func row(_ m: Int, _ icon: String, _ title: String, _ note: String) -> some View {
        let on = m == method
        let off = m == 1 && owed == 0
        return Button { method = m; amount = top; typing = false; focused = true } label: {
            HStack {
                Image(systemName: icon)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(note).font(.system(size: 12, design: .rounded))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.wbOrange : Color.primary.opacity(0.06)))
            .foregroundColor(on ? .white : .primary)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(off).opacity(off ? 0.45 : 1)
    }

    func use() {
        let w = clamp(amount), a = ai, m = method
        guard w > 0 else { done(); return }
        done()
        _ = m
        DispatchQueue.main.async { bank.caloriesToDebit(w, on: a) }   // Calories only ever become watts
    }
}

enum PayCreditAction { case paid, deposit, cancel }

/// Pay off the Credit card (₽): with the Debit card, a Watt card (converted at 0.83 W per ₽), or by depositing.
struct PayCreditSheet: View {
    @EnvironmentObject var bank: Bank
    let account: UUID
    let done: (PayCreditAction) -> Void
    @State private var method = 0
    @State private var amount = 0
    @State private var held = 0
    @State private var typing = false        // typing digits replaces the amount
    @FocusState private var focused: Bool
    var ai: Int { bank.data.accounts.firstIndex { $0.id == account } ?? 0 }
    var owed: Int { bank.owed(bank.data.accounts[ai]) }      // ₽
    var cashPd: Int { bank.data.accounts[ai].cash ?? 0 }
    var hasCash: Bool { cashPd > 0 }
    /// Methods: this Debit card (₽) if it has any, Watt cards with watts (this one first), then "deposit".
    var sources: [Int] {
        [ai].filter { bank.data.accounts[$0].balance > 0 } +
        bank.data.accounts.indices.filter { $0 != ai && bank.data.accounts[$0].balance > 0 }
    }
    var off: Int { hasCash ? 1 : 0 }
    var count: Int { off }                                   // the Credit card is paid off with the Debit card only
    var isCash: Bool { hasCash && method == 0 }
    var isDeposit: Bool { false }
    var top: Int {
        if isDeposit { return owed }
        if isCash { return min(owed, cashPd) }
        return min(owed, pdValue(ofW: bank.data.accounts[sources[method - off]].balance))
    }
    func clamp(_ v: Int) -> Int { min(max(top > 0 ? 1 : 0, v), top) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "creditcard.fill").font(.system(size: 22)).foregroundColor(.wbBlue)
                Text("Pay off the Credit card").font(.system(size: 17, weight: .bold))
                Spacer()
                Text(owed > 0 ? "Owes ₽\(fmt(owed))" : "Nothing owed").font(.system(size: 13, weight: .semibold))
                    .foregroundColor(owed > 0 ? .wbRed : .wbGreen)
            }
            if owed == 0 {
                Text("This card is paid off. Available: ₽\(fmt(bank.maxBorrow(bank.data.accounts[ai]))) at level \(bank.creditLevel(bank.data.accounts[ai])).")
                    .font(.system(size: 13))
                HStack { Spacer(); Button("Close  (Esc)") { done(.cancel) } }
            } else {
                Text(hasCash ? "Pay with:" : "The Credit card is paid off with the Debit card, and it's empty. Top it up first (from a save, or From Watt card).")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                VStack(spacing: 4) {
                    ForEach(0..<count, id: \.self) { m in
                        let on = m == method
                        Button { method = m; amount = top; typing = false; focused = true } label: {
                            HStack {
                                if hasCash && m == 0 {
                                    Image(systemName: "dollarsign.circle.fill")
                                    Text("Debit card").font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text("₽\(fmt(cashPd))").font(.system(size: 12, design: .rounded))
                                } else if m - off < sources.count {
                                    let a = bank.data.accounts[sources[m - off]]
                                    Image(systemName: "bolt.fill")
                                    Text(sources[m - off] == ai ? "Watt card" : "\(a.name)'s Watt card").font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text("\(fmt(a.balance)) W").font(.system(size: 12, design: .rounded))
                                } else {
                                    Image(systemName: "figure.walk")
                                    Text("Walk it off: deposit watts").font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text("Pikachu or Game Boy").font(.system(size: 11))
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.wbBlue : Color.primary.opacity(0.06)))
                            .foregroundColor(on ? .white : .primary)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                if isDeposit {
                    Text("Opens Deposit. Every watt you deposit pays this card first; anything left goes to Watt.")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                } else {
                    HStack {
                        Text("Amount:").font(.system(size: 12, weight: .semibold))
                        AmountField(text: "₽\(fmt(amount))", typing: typing)
                        Text((isCash ? "" : "costs \(fmt(wCost(ofPd: amount))) W · ") + (amount >= owed ? "pays it all off" : "₽\(fmt(owed - amount)) left after"))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                }
                Text("↑ ↓ choose how   ← → amount (hold to speed up, ⇧ = min/max) or type it   Return = pay   Esc = cancel")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack { Spacer()
                    Button("Cancel") { done(.cancel) }
                    Button(isDeposit ? "Start Deposit" : "Pay ₽\(fmt(amount))") { pay() }
                        .buttonStyle(.borderedProminent).tint(.wbBlue)
                }
            }
        }
        .padding(22).frame(width: 470)
        .foregroundStyle(.primary)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; amount = top }
        .onAppear { AmountKeys.handler = { c, back in var a = amount, t = typing; let ok = typeAmountChar(c, back, &a, &t, top); amount = a; typing = t; return ok } }
        .onDisappear { AmountKeys.handler = nil }
        .onKeyPress(phases: [.down, .repeat]) { k in
            held = k.phase == .repeat ? held + 1 : 0
            if [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow].contains(k.key) { typing = false }
            let step = held > 40 ? 1_000 : held > 25 ? 100 : held > 10 ? 10 : 1
            let shift = k.modifiers.contains(.shift)
            switch k.key {
            case .escape: done(.cancel)
            case .return: if owed > 0 { pay() } else { done(.cancel) }
            case .downArrow: method = min(method + 1, count - 1); amount = top
            case .upArrow: method = max(method - 1, 0); amount = top
            case .rightArrow: amount = shift ? top : clamp(amount + step)
            case .leftArrow: amount = shift ? clamp(1) : clamp(amount - step)
            default: return typeAmount(k, &amount, &typing, top) ? .handled : .ignored
            }
            return .handled
        }
    }

    func pay() {
        if isDeposit { done(.deposit); return }
        let p = clamp(amount), a = ai
        guard isCash, p > 0 else { done(.cancel); return }
        done(.paid); DispatchQueue.main.async { bank.cashToCredit(p, on: a) }
    }
}

struct PayDebtSheet: View {
    @EnvironmentObject var bank: Bank
    let debtor: UUID
    let done: () -> Void
    @State private var pick = 0
    @FocusState private var focused: Bool
    var di: Int { bank.data.accounts.firstIndex { $0.id == debtor } ?? 0 }
    var debt: Int { max(0, -bank.data.accounts[di].balance) }
    var sources: [Int] { bank.data.accounts.indices.filter { $0 != di && bank.data.accounts[$0].balance > 0 } }
    var amount: Int { sources.isEmpty ? 0 : min(debt, bank.data.accounts[sources[min(pick, sources.count - 1)]].balance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 24)).foregroundColor(.wbBlue)
                Text("Pay \u{201C}\(bank.data.accounts[di].name)\u{201D}'s debt").font(.system(size: 17, weight: .bold))
            }
            Text("It owes \(fmt(debt)) W.").font(.system(size: 13))
            if sources.isEmpty {
                Text("No other account has watts to pay with. Deposit some first.").font(.system(size: 12)).foregroundColor(.secondary)
                HStack { Spacer(); Button("Close  (Esc)") { done() } }
            } else {
                Text("Pay from:").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { pos, i in
                            let on = pos == pick
                            Button { pick = pos } label: {
                                VStack(spacing: 2) {
                                    Text(bank.data.accounts[i].name).font(.system(size: 13, weight: .semibold))
                                    Text("\(fmt(bank.data.accounts[i].balance)) W").font(.system(size: 11)).opacity(0.8)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.wbBlue : Color.primary.opacity(0.08)))
                                .foregroundColor(on ? .white : .primary)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Text(amount < debt ? "Pays \(fmt(amount)) W — all that account has; \(fmt(debt - amount)) W stays owed."
                                   : "Pays the whole debt.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                Text("← → choose   Return = pay   Esc = cancel").font(.system(size: 11)).foregroundColor(.secondary)
                HStack { Spacer()
                    Button("Cancel") { done() }
                    Button("Pay \(fmt(amount)) W") { pay() }.buttonStyle(.borderedProminent).tint(.wbBlue)
                }
            }
        }
        .padding(22).frame(width: 460)
        .foregroundStyle(.primary)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: [.down, .repeat]) { k in
            switch k.key {
            case .escape: done()
            case .return: pay()
            case .rightArrow: pick = min(pick + 1, max(0, sources.count - 1))
            case .leftArrow: pick = max(pick - 1, 0)
            default: return .ignored
            }
            return .handled
        }
    }

    func pay() {
        guard !sources.isEmpty, amount > 0 else { done(); return }
        let from = sources[min(pick, sources.count - 1)], to = di, w = amount
        done()
        DispatchQueue.main.async { bank.move(w, from: from, to: to) }
    }
}

enum DeleteAction { case delete, move(Int), moveToNew, withdraw, cancel }

struct DeleteSheet: View {
    @EnvironmentObject var bank: Bank
    let id: UUID
    let done: (DeleteAction) -> Void
    @State private var target = 0          // position in `others`; others.count = "New account"
    @FocusState private var focused: Bool
    var index: Int { bank.data.accounts.firstIndex { $0.id == id } ?? -1 }
    var acct: Account { bank.data.accounts.first { $0.id == id } ?? Account(name: "") }
    var others: [Int] { bank.data.accounts.indices.filter { $0 != index } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "trash.circle.fill").font(.system(size: 24)).foregroundColor(.wbRed)
                Text("Delete \u{201C}\(acct.name)\u{201D}").font(.system(size: 17, weight: .bold))
            }
            if acct.balance < 0 {
                Text("It owes \(fmt(-acct.balance)) W. Pay its debt first (P on that account).").font(.system(size: 13))
                HStack { Spacer(); Button("OK  (Esc)") { done(.cancel) }.keyboardShortcut(.cancelAction) }
            } else if acct.balance == 0 {
                Text("The account is empty. Its history will be deleted too.").font(.system(size: 13))
                HStack { Spacer()
                    Button("Cancel  (Esc)") { done(.cancel) }
                    Button("Delete  (Return)") { done(.delete) }.buttonStyle(.borderedProminent).tint(.wbRed)
                }
            } else {
                Text("It still has \(fmt(acct.balance)) W. Move them to another account, or withdraw them to the Pikachu first.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Text("Move to:").font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array((others + [-1]).enumerated()), id: \.offset) { pos, i in
                            let on = pos == target
                            Button { target = pos } label: {
                                Text(i < 0 ? "+ New account" : bank.data.accounts[i].name)
                                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Color.wbBlue : Color.primary.opacity(0.08)))
                                    .foregroundColor(on ? .white : .primary)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Text("← → choose   Return = move & delete   ↓ = withdraw to Pikachu instead   Esc = cancel")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack { Spacer()
                    Button("Cancel") { done(.cancel) }
                    Button("Withdraw instead") { done(.withdraw) }
                    Button("Move \(fmt(acct.balance)) W & delete") { confirm() }.buttonStyle(.borderedProminent).tint(.wbBlue)
                }
            }
        }
        .padding(22).frame(width: 480)
        .foregroundStyle(.primary)   // sheets follow light/dark mode; don't inherit the main window's dark ink
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(phases: [.down, .repeat]) { k in
            switch k.key {
            case .escape: done(.cancel)
            case .return: if acct.balance == 0 { done(.delete) } else if acct.balance > 0 { confirm() } else { done(.cancel) }
            case .rightArrow: target = min(target + 1, others.count)
            case .leftArrow: target = max(target - 1, 0)
            case .downArrow: if acct.balance > 0 { done(.withdraw) } else { return .ignored }
            default: return .ignored
            }
            return .handled
        }
    }

    func confirm() { done(target < others.count ? .move(others[target]) : .moveToNew) }
}

struct TransferSheet: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var bank: Bank

    var title: String {
        switch session.mode {
        case .deposit: return "Deposit"
        case .gift: return "Send \(session.gift?.name ?? "gift") to GSC"
        default: return "Withdraw"
        }
    }
    var instruction: String {
        switch session.mode {
        case .deposit: return "On the Pikachu: Watts → Send. Point its IR window at the dark receiver on the IR head."
        case .gift: return "In Pokémon GSC choose MYSTERY GIFT on the main menu and press A. Point the GBC's IR port at the IR head, about 4–6 inches away."
        default: return "On the Pikachu: Watts → Receive. Point its IR window at the dark receiver on the IR head."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: session.mode == .deposit ? "arrow.up.circle.fill" : session.mode == .gift ? "gift.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 26)).foregroundColor(session.mode == .deposit ? .wbGreen : .wbOrange)
                Text(title).font(.system(size: 20, weight: .bold))
                Spacer()
                Text(bank.current.name).font(.system(size: 12)).foregroundColor(.secondary)
            }

            if let p = session.prompt {
                Text(p.title).font(.system(size: 15, weight: .semibold))
                Text(p.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(p.no + "  (Esc)") { p.onNo() }.keyboardShortcut(.cancelAction)
                    Button(p.yes + "  (Return)") { p.onYes() }.keyboardShortcut(.defaultAction)
                }
            } else if let r = session.result {
                HStack(spacing: 10) {
                    Image(systemName: session.resultGood ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 28)).foregroundColor(session.resultGood ? .wbGreen : .wbOrange)
                    Text(r).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                }
                Text("Balance: \(fmt(bank.current.balance)) W").font(.system(size: 13)).foregroundColor(.secondary)
                HStack {
                    Spacer()
                    if !session.resultGood {
                        Button(session.mode == .deposit ? "Try again  (↑)" : session.mode == .gift ? "Try again  (*)" : "Try again  (↓)") {
                            if session.mode == .deposit { session.beginDeposit() }
                            else if session.mode == .gift, let g = session.gift { if bank.current.balance >= session.giftCost(g) { session.beginGift(g) } }
                            else { let left = session.parts.dropFirst(session.partIndex).reduce(0, +)
                                   if left > 0 && left <= bank.current.balance { session.beginWithdraw(left) } }
                        }
                        .keyboardShortcut(session.mode == .deposit ? .upArrow : session.mode == .gift ? "*" : .downArrow, modifiers: [])
                    }
                    Button("Done  (Return)") { session.close() }.keyboardShortcut(.defaultAction)
                }
            } else {
                Text(instruction).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Circle().fill(session.linked ? Color.wbBlue : Color.gray.opacity(0.35)).frame(width: 12, height: 12)
                    Text(session.status).font(.system(size: 13, weight: .medium))
                    Spacer()
                    if !session.linked { ProgressView().controlSize(.small) }
                }
                ProgressView(value: Double(session.step), total: 8).tint(.wbBlue)
                if session.mode == .deposit {
                    if !session.received.isEmpty {
                        let t = session.received.reduce(0, +)
                        HStack {
                            Text("Received: +\(fmt(t)) W").font(.system(size: 15, weight: .bold)).foregroundColor(.wbGreen)
                            Text(session.received.count == 1 ? "1 transfer" : "\(session.received.count) transfers")
                                .font(.system(size: 12)).foregroundColor(.secondary)
                        }
                        Text(session.received.map { "+" + fmt($0) }.joined(separator: "  "))
                            .font(.system(size: 11, design: .rounded)).foregroundColor(.secondary).lineLimit(2)
                    }
                    if let n = session.lastNote { Text(n).font(.system(size: 11)).foregroundColor(.wbOrange) }
                }
                Text(session.linked ? "Don't move the Pikachu until it's done."
                     : session.mode == .deposit
                        ? "Keeps listening for more transfers (batches from the GBC arrive part by part). Weak signals are ignored — move closer if nothing happens."
                        : "Waiting up to 60 seconds. Weak signals are ignored — move closer if nothing happens.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                HStack {
                    Spacer()
                    if session.mode == .deposit {
                        Button("Done") { session.cancel() }.keyboardShortcut(.defaultAction).opacity(0).frame(width: 0)
                        Button(session.received.isEmpty ? "Cancel  (Esc)" : "Done  (Return / Esc)") { session.cancel() }
                            .keyboardShortcut(.cancelAction)
                    } else {
                        Button("Cancel  (Esc)") { session.cancel() }.keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .padding(22).frame(width: 440)
        .foregroundStyle(.primary)   // sheets follow light/dark mode; don't inherit the main window's dark ink
    }
}

// MARK: - App

@main
struct WattBankApp: App {
    @StateObject private var bank: Bank
    @StateObject private var link: IRLink
    @StateObject private var session: Session

    init() {
        // Enter (keypad / fn-Return, key code 76) always acts exactly like Return (key code 36),
        // in every window, sheet and alert.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { e in
            guard let h = AmountKeys.handler, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            let back = e.keyCode == 51 || e.keyCode == 117
            let c = e.charactersIgnoringModifiers ?? ""
            if back || (c.count == 1 && Int(c) != nil) { return h(c, back) ? nil : e }
            return e
        }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard e.keyCode == 76 else { return e }
            return NSEvent.keyEvent(with: e.type, location: e.locationInWindow,
                                    modifierFlags: e.modifierFlags.subtracting(.numericPad),
                                    timestamp: e.timestamp, windowNumber: e.windowNumber, context: nil,
                                    characters: "\r", charactersIgnoringModifiers: "\r",
                                    isARepeat: e.isARepeat, keyCode: 36) ?? e
        }
        let b = Bank(); let l = IRLink()
        _bank = StateObject(wrappedValue: b)
        _link = StateObject(wrappedValue: l)
        _session = StateObject(wrappedValue: Session(bank: b, link: l))
    }

    var body: some Scene {
        WindowGroup("Watt Bank") {
            ContentView()
                .environmentObject(bank).environmentObject(link).environmentObject(session)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

// MARK: - Help: IR head guide, iPhone Shortcut, donations

/// Opens or saves a file that ships inside the app (firmware, Shortcut).
enum Bundled {
    static var firmware: URL? { Bundle.main.url(forResource: "wattbank_ir", withExtension: "ino") }
    static var shortcut: URL? { Bundle.main.url(forResource: "Watt Bank Health Sync", withExtension: "shortcut") }
    /// Copies a bundled file to Downloads and shows it in Finder. Returns the copy.
    static func addShortcut() { if let u = shortcut { NSWorkspace.shared.open(u) } else { NSSound.beep() } }
    @discardableResult static func saveToDownloads(_ src: URL?, folder: String? = nil) -> URL? {
        guard let src else { NSSound.beep(); return nil }
        var dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        if let folder { dir = dir.appendingPathComponent(folder) }   // Arduino wants the .ino in a folder of the same name
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: src, to: dst)) != nil else { NSSound.beep(); return nil }
        NSWorkspace.shared.activateFileViewerSelecting([dst])
        return dst
    }
}

/// A guide picture shipped in the app (Resources/guide/<name>.png).
func guideImage(_ name: String) -> NSImage? {
    Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "guide").flatMap { NSImage(contentsOf: $0) }
}

struct GuideStep { let title: String; let image: String; let lines: [String] }

/// A picture-led stepper used by the IR head and Shortcut guides. ← → / Return step through, Esc closes.
struct GuideSheet: View {
    let title: String, icon: String, tint: Color
    let steps: [GuideStep]
    var extra: (Int) -> AnyView = { _ in AnyView(EmptyView()) }
    var keys: (String) -> Bool = { _ in false }
    var start = 0
    let done: () -> Void
    @State private var step = 0
    @FocusState private var focused: Bool
    var body: some View {
        let s = steps[min(step, steps.count - 1)]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).font(.system(size: 20, weight: .bold)).foregroundColor(tint)
                Text(title).font(.system(size: 18, weight: .bold))
                Spacer()
                Text("Step \(step + 1) of \(steps.count)").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule().fill(i <= step ? tint : Color.primary.opacity(0.12)).frame(height: 5)
                        .contentShape(Rectangle()).onTapGesture { step = i }
                }
            }
            Text(s.title).font(.system(size: 16, weight: .semibold))
            if let img = guideImage(s.image) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 430)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(s.lines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.system(size: 13, design: l.contains("http") ? .monospaced : .default))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                extra(step)
                Spacer()
                Button("Close") { done() }
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == steps.count - 1 ? "Done" : "Next") { if step == steps.count - 1 { done() } else { step += 1 } }
                    .buttonStyle(.borderedProminent).tint(tint)
            }
            Text("← → or Return = step   Esc = close").font(.system(size: 11)).foregroundColor(.secondary)
        }
        .padding(22).frame(width: 760)
        .focusable().focused($focused).focusEffectDisabled()
        .onAppear { focused = true; step = start }
        .onKeyPress(phases: .down) { k in
            switch k.key {
            case .escape: done()
            case .return, .rightArrow: if step == steps.count - 1 { done() } else { step += 1 }
            case .leftArrow: step = max(0, step - 1)
            default: return keys(k.characters.lowercased()) ? .handled : .ignored
            }
            return .handled
        }
    }
}

/// Step-by-step: build the ESP32 IR head and load its firmware (one click from Watt Bank; Arduino IDE as a backup).
struct IRGuideSheet: View {
    @ObservedObject var link: IRLink
    @ObservedObject private var flasher = Flasher.shared
    var start = 0
    let done: () -> Void
    static let flashStep = 4
    static let boardsURL = "https://espressif.github.io/arduino-esp32/package_esp32_index.json"
    static let steps: [GuideStep] = [
        GuideStep(title: "1. What you need", image: "ir_step1_parts", lines: [
            "ESP32 dev board, a clear 940 nm IR LED (sends), a dark-blue 940 nm IR receiver (receives), a 100 Ω and a 10 kΩ resistor, a breadboard, jumper wires and a USB data cable.",
            "The receiver must be a raw IR receiver diode or phototransistor, not a TV-remote module (TSOP/VS1838): the Pikachu and Game Boy send plain light pulses.",
        ]),
        GuideStep(title: "2. Power rails", image: "ir_step2_power", lines: [
            "Seat the ESP32 across the middle of the breadboard.",
            "Red wire: 3V3 → the + rail.   Black wire: GND → the − rail.",
        ]),
        GuideStep(title: "3. IR LED (sends)", image: "ir_step3_led", lines: [
            "Orange wire: D18 → 100 Ω resistor (brown·black·brown) → long leg of the clear IR LED.",
            "Short leg (flat side) → black wire → − rail.",
        ]),
        GuideStep(title: "4. IR receiver (receives)", image: "ir_step4_receiver", lines: [
            "Blue wire: D19 → one leg of the dark-blue receiver. The 10 kΩ resistor (brown·black·orange) goes from that same row to the + rail (red wire).",
            "Other leg → black wire → − rail. Point the LED and the receiver the same way, side by side.",
            "If the receiver never reacts later, turn it around (swap its legs).",
        ]),
        GuideStep(title: "5. Install the firmware (one click)", image: "ir_step5_flash", lines: [
            "Plug the ESP32 into this Mac with a USB data cable and click Install firmware (F). Watt Bank writes the IR head firmware itself; no Arduino IDE needed. It takes about 20 seconds; the bar shows the progress.",
            "If the board already runs the IR head firmware, its blue light blinks first so you know it was found. While it is being written the board can't light anything; when it restarts, the blue light blinks 3 times: installed.",
            "Stuck at “Connecting”? Hold the board's BOOT button while you click Install. No board found? Install the CP210x or CH340 USB driver (the chip name is next to the USB port).",
        ]),
        GuideStep(title: "6. Plug it into the Mac", image: "ir_step7_connect", lines: [
            "With the ESP32 plugged in, the badge at the top right of Watt Bank turns green: IR head ready.",
        ]),
        GuideStep(title: "7. Deposit, withdraw, Mystery Gift", image: "ir_step8_use", lines: [
            "Deposit (↑): Pikachu 2 GS → Watts → Send.   Withdraw (↓): Watts → Receive.",
            "GSC (G): Mystery Gift from the title menu of Gold, Silver or Crystal on a Game Boy Color or Chromatic.",
        ]),
        GuideStep(title: "Backup A. Arduino IDE + ESP32 support", image: "ir_step5_arduino", lines: [
            "Only if the one-click install doesn't work. Install Arduino IDE 2. In Settings, paste the boards URL into “Additional boards manager URLs”:",
            "   \(IRGuideSheet.boardsURL)",
            "Then Boards Manager → search esp32 → install “esp32 by Espressif Systems”.",
        ]),
        GuideStep(title: "Backup B. Upload from Arduino IDE", image: "ir_step6_upload", lines: [
            "Save firmware source (S) puts wattbank_ir.ino in Downloads › wattbank_ir. Open it in Arduino IDE.",
            "Tools → Board: ESP32 Dev Module, Tools → Port: cu.usbserial / SLAB_USBtoUART / wchusbserial, then Upload. Stuck on “Connecting…”? Hold BOOT.",
            "Serial Monitor at 115200 should say #READY WATTBANK-IR. Then close the Serial Monitor.",
        ]),
    ]
    var body: some View {
        GuideSheet(title: "Build the IR head", icon: "wrench.and.screwdriver", tint: .wbBlue, steps: Self.steps,
                   extra: { i in
                       if i == Self.flashStep { return AnyView(FlashPanel(link: link)) }
                       if i == 7 { return AnyView(HStack {
                           Button("Get Arduino IDE") { NSWorkspace.shared.open(URL(string: "https://www.arduino.cc/en/software")!) }
                           Button("Copy boards URL  U") { copyBoards() } }) }
                       if i == 8 { return AnyView(Button("Save firmware source  S") { saveSource() }) }
                       return AnyView(EmptyView())
                   },
                   keys: { c in
                       if c == "f" { flasher.flash(link: link); return true }
                       if c == "s" { saveSource(); return true }
                       if c == "u" { copyBoards(); return true }
                       return false
                   }, start: start, done: done)
    }
    func saveSource() { Bundled.saveToDownloads(Bundled.firmware, folder: "wattbank_ir") }
    func copyBoards() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.boardsURL, forType: .string) }
}

/// Install button, progress and result for the one-click firmware install.
struct FlashPanel: View {
    @ObservedObject var link: IRLink
    @ObservedObject private var flasher = Flasher.shared
    var body: some View {
        HStack(spacing: 10) {
            Button(flasher.busy ? "Installing…" : "Install firmware  F") { flasher.flash(link: link) }
                .buttonStyle(.borderedProminent).tint(.wbGreen).disabled(flasher.busy || !Flasher.available)
            switch flasher.state {
            case .idle:
                Text(!Flasher.available ? "Installer missing from this build: use the Arduino IDE backup."
                     : link.port != nil || IRLink.findPort() != nil ? "ESP32 found." : "Plug in the ESP32 first.")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            case .flashing(let p):
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        ProgressView(value: max(p, 0.02)).frame(width: 220).tint(.wbGreen)
                        Text("\(Int(p * 100))%").font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                        Image(systemName: "bolt.fill").foregroundColor(.yellow).symbolEffect(.pulse)
                    }
                    Text(flasher.phase).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                }
            case .done:
                Label(link.ready ? "Installed. IR head ready." : "Installed. Waiting for the IR head…", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.wbGreen)
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.wbRed).lineLimit(2)
                    .help(flasher.log.suffix(12).joined(separator: "\n"))
            }
        }
    }
}

/// Writes the bundled IR head firmware to the ESP32 with esptool (shipped inside the app), like Arduino IDE's Upload.
@MainActor final class Flasher: ObservableObject {
    static let shared = Flasher()
    enum State: Equatable { case idle, flashing(Double), done, failed(String) }
    @Published var state: State = .idle
    @Published var phase = ""
    private(set) var log: [String] = []
    private var proc: Process?
    private var part = -1, pct = 0.0
    var busy: Bool { proc != nil || starting }
    // what goes where (same layout Arduino IDE uses for an ESP32 Dev Module)
    static let parts: [(addr: String, file: String)] = [
        ("0x1000", "wattbank_ir.bootloader"), ("0x8000", "wattbank_ir.partitions"),
        ("0xe000", "boot_app0"), ("0x10000", "wattbank_ir")]
    static var esptool: URL? { Bundle.main.url(forResource: "esptool", withExtension: nil, subdirectory: "firmware") }
    static func bin(_ n: String) -> URL? { Bundle.main.url(forResource: n, withExtension: "bin", subdirectory: "firmware") }
    static var available: Bool { esptool != nil && parts.allSatisfy { bin($0.file) != nil } }
    private lazy var sizes: [Double] = Self.parts.map { p in
        Double((try? FileManager.default.attributesOfItem(atPath: Self.bin(p.file)!.path)[.size] as? Int) ?? 1)
    }

    private var starting = false
    func flash(link: IRLink) {
        guard proc == nil, !starting, Self.available else { return }
        guard let port = link.port ?? IRLink.findPort() else {
            state = .failed("No ESP32 found. Plug it in with a USB data cable (or install its CP210x/CH340 driver)."); return }
        starting = true; log = []; part = -1; pct = 0; state = .flashing(0)
        let go = { [weak self] in link.pause { self?.waitForPort(port, link: link, tries: 30, retry: true) } }
        if link.ready {                       // old firmware answers: blink the board's blue light so you see which one
            phase = "Found it: the blue light on the board is blinking…"
            link.send("f")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { go() }
        } else { phase = "Getting the ESP32 ready…"; go() }
    }

    /// The port can vanish for a moment while it is released: wait up to 3 s for it before starting.
    private func waitForPort(_ port: String, link: IRLink, tries: Int, retry: Bool) {
        if FileManager.default.fileExists(atPath: port) || tries <= 0 { run(port, link: link, retry: retry); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.waitForPort(port, link: link, tries: tries - 1, retry: retry) }
    }

    private func run(_ port: String, link: IRLink, retry: Bool) {
        guard let tool = Self.esptool else { return }
        starting = false
        part = -1; pct = 0; phase = "Connecting to the ESP32…"; state = .flashing(0.01)
        var args = ["--chip", "esp32", "--port", port, "--baud", "460800", "--before", "default-reset", "--after", "hard-reset",
                    "write-flash", "-z", "--flash-mode", "keep", "--flash-freq", "keep", "--flash-size", "keep"]
        for p in Self.parts { args += [p.addr, Self.bin(p.file)!.path] }
        let p = Process(); p.executableURL = tool; p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in self?.consume(s) }
        }
        p.terminationHandler = { [weak self] pr in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.proc = nil
                let missing = self.log.joined(separator: " ").lowercased().contains("no such file")
                if pr.terminationStatus != 0 && missing && retry {           // port re-appearing: one more try
                    self.phase = "Trying again…"
                    self.waitForPort(port, link: link, tries: 30, retry: false); return
                }
                if pr.terminationStatus == 0 { self.state = .done; self.phase = "" } else { self.state = .failed(self.reason()) }
                link.logLine("FLASH exit \(pr.terminationStatus): " + self.log.suffix(6).joined(separator: " | "))
                link.resume()
            }
        }
        do { try p.run(); proc = p } catch { state = .failed("Couldn't start the installer."); link.resume() }
        _ = port
    }

    private func consume(_ chunk: String) {
        for raw in chunk.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if log.last != line { log.append(line); if log.count > 300 { log.removeFirst(100) } }
            let low = line.lowercased()
            if low.contains("connecting") { phase = "Connecting to the ESP32…" }
            if low.hasPrefix("compressed") { part += 1; pct = 0; phase = "Writing part \(part + 1) of \(Self.parts.count)…" }
            if low.contains("writing at"), let r = line.range(of: #"(\d{1,3}(\.\d+)?)\s?%"#, options: .regularExpression) {
                pct = (Double(line[r].filter { $0.isNumber || $0 == "." }) ?? 0) / 100
            }
            if part >= 0 {
                let total = sizes.reduce(0, +), done = sizes.prefix(part).reduce(0, +)
                state = .flashing(min(1, (done + pct * sizes[min(part, sizes.count - 1)]) / total))
            }
            if low.contains("hard resetting") { phase = "Restarting the ESP32…" }
        }
    }

    private func reason() -> String {
        let all = log.joined(separator: " ").lowercased()
        if all.contains("no such file") { return "The ESP32 was unplugged. Plug it back in and try again." }
        if all.contains("busy") || all.contains("could not open") || all.contains("resource") {
            return "The port is busy. Close Arduino's Serial Monitor (or other serial apps) and try again." }
        if all.contains("failed to connect") || all.contains("no serial data") || all.contains("timed out") {
            return "Couldn't reach the ESP32. Hold its BOOT button, click Install again, and let go when writing starts." }
        return log.last ?? "The install failed."
    }
}

/// Step-by-step pictures for the iPhone Shortcut that feeds the Calories card.
struct ShortcutGuideSheet: View {
    let done: () -> Void
    static let steps: [GuideStep] = [
        GuideStep(title: "1. Add the Shortcut", image: "sc_step1_add", lines: [
            "Add to Shortcuts (A) imports it on this Mac and iCloud brings it to your iPhone. Or Save a copy and AirDrop it, then tap Add Shortcut.",
        ]),
        GuideStep(title: "2. Run it once, allow Health", image: "sc_step2_health", lines: [
            "On the iPhone, tap Watt Bank Health Sync. Turn on Active Energy, Steps, Walking + Running Distance and Weight, then Allow.",
        ]),
        GuideStep(title: "3. Make it automatic", image: "sc_step3_automation", lines: [
            "Shortcuts → Automation → + → Time of Day (e.g. 9 PM, Daily) → Run Immediately → Watt Bank Health Sync.",
        ]),
        GuideStep(title: "4. Calories land in Watt Bank", image: "sc_step4_mac", lines: [
            "Each run saves WattBankHealth.txt to iCloud Drive › Shortcuts; Watt Bank adds new exercise to the Calories card within a minute.",
            "Needs the same Apple ID with iCloud Drive on the iPhone and the Mac.",
        ]),
    ]
    var body: some View {
        GuideSheet(title: "Set up the iPhone Shortcut", icon: "iphone", tint: .wbOrange, steps: Self.steps,
                   extra: { i in i == 0 ? AnyView(HStack {
                       Button("Add to Shortcuts  A") { Bundled.addShortcut() }
                       Button("Save a copy") { Bundled.saveToDownloads(Bundled.shortcut) } }) : AnyView(EmptyView()) },
                   keys: { c in if c == "a" { Bundled.addShortcut(); return true }; return false }, done: done)
    }
}

/// The iPhone Shortcut that feeds the Calories card, with how to set it up.
struct ShortcutSetupBox: View {
    @State private var guide = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "iphone").foregroundColor(.wbOrange)
                Text("iPhone Shortcut: Watt Bank Health Sync").font(.system(size: 13, weight: .semibold))
            }
            Text("Your exercise from Apple Health lands on this card. Set it up once, with pictures for every step.")
                .font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show me how  H") { guide = true }.buttonStyle(.borderedProminent).tint(.wbOrange)
                Button("Add to Shortcuts  A") { Bundled.addShortcut() }
                Button("Save a copy") { Bundled.saveToDownloads(Bundled.shortcut) }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .sheet(isPresented: $guide) { ShortcutGuideSheet { guide = false } }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcutGuide)) { _ in guide = true }
    }
}

extension Notification.Name { static let showShortcutGuide = Notification.Name("WBShowShortcutGuide") }

/// Live prices so the suggested tip stays close to US$5, rounded to a clean amount of each coin.
@MainActor final class TipPrices: ObservableObject {
    static let shared = TipPrices()
    static let targetUSD = 5.0
    @Published private(set) var usd: [String: Double] = [:]          // "nano" / "banano" → US$ per coin
    private var timer: Timer?
    init() {
        for id in ["nano", "banano"] { if let v = UserDefaults.standard.object(forKey: "tipPrice." + id) as? Double { usd[id] = v } }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func refresh() {
        guard let url = URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=nano,banano&vs_currencies=usd") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Double]] else { return }
            Task { @MainActor in
                for (id, v) in obj { if let p = v["usd"], p > 0 { self?.usd[id] = p; UserDefaults.standard.set(p, forKey: "tipPrice." + id) } }
            }
        }.resume()
    }
    /// About $5 of a coin, rounded: whole coins below 10, two significant figures above (15, 9,400, 12,000…).
    static func roundedAmount(price: Double) -> Decimal {
        let raw = targetUSD / price
        if raw >= 10 {
            let mag = pow(10, floor(log10(raw)) - 1)
            return Decimal((raw / mag).rounded() * mag)
        }
        if raw >= 1 { return Decimal(raw.rounded()) }
        let mag = pow(10, floor(log10(raw)) - 1)                       // a coin worth more than $5: 2 significant figures
        return Decimal(string: String(format: "%.*f", Int(-log10(mag)), (raw / mag).rounded() * mag)) ?? 1
    }
}

/// Donation addresses at the bottom of the window. The Tip buttons and QR codes carry a suggested amount worth about
/// US$5 at today's price (fetched from CoinGecko every 30 minutes), always a rounded number of coins.
struct DonationFooter: View {
    struct Coin { let name: String, ticker: String, id: String, addr: String, decimals: Int, fallback: Decimal, tint: Color }
    static let nano = Coin(name: "NANO", ticker: "XNO", id: "nano", addr: "nano_1n9rntp5r1z8iu7eqkkdr1y885z75mgweppompe5jm14yscot366f6za9hcr",
                           decimals: 30, fallback: 15, tint: Color(red: 0.13, green: 0.55, blue: 0.95))          // 1 XNO = 10^30 raw
    static let ban = Coin(name: "BAN", ticker: "BAN", id: "banano", addr: "ban_1n9rntp5r1z8iu7eqkkdr1y885z75mgweppompe5jm14yscot366f6za9hcr",
                          decimals: 29, fallback: 10000, tint: Color(red: 0.85, green: 0.62, blue: 0.08))       // 1 BAN = 10^29 raw
    @ObservedObject private var prices = TipPrices.shared
    @State private var copied: String? = nil
    func amount(_ c: Coin) -> Decimal { prices.usd[c.id].map { TipPrices.roundedAmount(price: $0) } ?? c.fallback }
    func label(_ c: Coin) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 4
        return (f.string(from: amount(c) as NSDecimalNumber) ?? "\(amount(c))") + " " + c.ticker
    }
    func uri(_ c: Coin) -> String {
        var raw = amount(c) * pow(Decimal(10), c.decimals)
        var whole = Decimal(); NSDecimalRound(&whole, &raw, 0, .down)
        return "\(c.name.lowercased()):\(c.addr)?amount=\(NSDecimalNumber(decimal: whole).stringValue)"
    }
    func usd(_ c: Coin) -> String {
        guard let p = prices.usd[c.id] else { return "about $5" }
        return String(format: "≈ $%.2f", NSDecimalNumber(decimal: amount(c)).doubleValue * p)
    }
    var body: some View {
        HStack(spacing: 14) {
            Label("Enjoying Watt Bank? Tips welcome (about $5)", systemImage: "heart.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.wbRed)
            Spacer(minLength: 4)
            coin(Self.nano)
            coin(Self.ban)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
    func coin(_ c: Coin) -> some View {
        HStack(spacing: 6) {
            Text(c.name).font(.system(size: 10, weight: .heavy)).foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(c.tint))
            Text(c.addr.prefix(10) + "…" + c.addr.suffix(5)).font(.system(size: 11, design: .monospaced)).help(c.addr)
            Button(copied == c.name ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.addr, forType: .string)
                copied = c.name
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == c.name { copied = nil } }
            }.controlSize(.small).help("Copy the \(c.name) address")
            Button("Tip \(label(c))") { if let u = URL(string: uri(c)) { NSWorkspace.shared.open(u) } }
                .controlSize(.small).help("Opens your \(c.name) wallet with \(label(c)) (\(usd(c))) filled in; you can change it")
            QRButton(text: uri(c), label: "\(c.name) · suggested tip \(label(c)) \(usd(c))")
        }
    }
}

struct QRButton: View {
    let text: String, label: String
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: { Image(systemName: "qrcode") }
            .controlSize(.small).help("Show \(label) QR code")
            .popover(isPresented: $show) {
                VStack(spacing: 8) {
                    if let img = qr(text) { Image(nsImage: img).interpolation(.none).resizable().frame(width: 180, height: 180) }
                    Text(label).font(.system(size: 12, weight: .semibold))
                }.padding(14)
            }
    }
    func qr(_ s: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(s.utf8), forKey: "inputMessage"); f.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size); img.addRepresentation(rep); return img
    }
}

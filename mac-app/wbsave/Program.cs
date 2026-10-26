// wbsave: Watt Bank's save-file helper. Reads and moves PokéDollars in any Pokémon save PKHeX.Core understands.
//   wbsave info <save>             -> JSON with game, trainer, money
//   wbsave take <save> <amount>    -> removes money from the save (backup first), JSON with the new money
//   wbsave give <save> <amount>    -> adds money to the save (capped at the game's max), JSON with the new money
//   wbsave takemom|givemom <save> <amount> -> same with Mom's savings (Gold/Silver/Crystal, HeartGold/SoulSilver)
using System.Text.Json;
using PKHeX.Core;

static int Fail(string msg) { Console.WriteLine(JsonSerializer.Serialize(new { ok = false, error = msg })); return 1; }

if (args.Length < 2) return Fail("usage: wbsave info|take|give <save> [amount]");
var cmd = args[0]; var path = args[1];
if (!File.Exists(path)) return Fail("file not found");

SaveFile? sav;
try { sav = SaveUtil.GetSaveFile(path); } catch (Exception e) { return Fail("could not read save: " + e.Message); }
if (sav is null) return Fail("not a Pokémon save file PKHeX recognizes");

// Mom's savings: Gold/Silver/Crystal (3 bytes BCD-free big endian right after the player's money)
// and HeartGold/SoulSilver (u32 in the Pokégear block: PKHeX's rolodex offset 0xC0EC - 0x14, from pret/pokeheartgold).
static int? MomOffset(SaveFile s)
{
    if (s is SAV2 s2)
    {
        var f = typeof(SAV2).GetField("Offsets", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance);
        var o = f?.GetValue(s2);
        var m = o?.GetType().GetProperty("Money")?.GetValue(o) ?? o?.GetType().GetField("Money")?.GetValue(o);
        return m is int i ? i + 3 : null;
    }
    if (s is SAV4HGSS) return 0xC0EC - 0x14;
    return null;
}
static uint? GetMom(SaveFile s)
{
    var o = MomOffset(s); if (o is null) return null;
    if (s is SAV2) { var d = s.Data; return (uint)(d[o.Value] << 16 | d[o.Value + 1] << 8 | d[o.Value + 2]); }
    return System.Buffers.Binary.BinaryPrimitives.ReadUInt32LittleEndian(((SAV4HGSS)s).General[o.Value..]);
}
static void SetMom(SaveFile s, uint v)
{
    var o = MomOffset(s)!.Value;
    v = Math.Min(v, 999999);
    if (s is SAV2) { var d = s.Data; d[o] = (byte)(v >> 16); d[o + 1] = (byte)(v >> 8); d[o + 2] = (byte)v; return; }
    System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(((SAV4HGSS)s).General[o..], v);
}

object Info(SaveFile s) => new {
    ok = true,
    game = s.Version.ToString(),
    generation = (int)s.Generation,
    trainer = s.OT,
    tid = s.DisplayTID,
    tidDigits = s.Generation >= 7 ? 6 : 5,
    money = s.Money,
    momMoney = GetMom(s),
    playTime = $"{s.PlayedHours}:{s.PlayedMinutes:00}:{s.PlayedSeconds:00}",
    maxMoney = s.MaxMoney,
    checksums = s.ChecksumsValid,
};

if (cmd == "info") { Console.WriteLine(JsonSerializer.Serialize(Info(sav))); return 0; }

if (args.Length < 3 || !uint.TryParse(args[2], out var amount) || amount == 0) return Fail("amount must be a positive whole number");
// t2m / m2t: move money between the trainer's wallet and Mom inside the same save (one write)
if (cmd is "t2m" or "m2t")
{
    if (GetMom(sav) is null) return Fail("this game has no Mom's savings");
    uint wal = sav.Money, momv = GetMom(sav)!.Value;
    uint have = cmd == "t2m" ? wal : momv;
    uint room = cmd == "t2m" ? 999999u - momv : (uint)sav.MaxMoney - wal;
    uint mv = Math.Min(amount, Math.Min(have, room));
    if (mv == 0) return Fail(have == 0 ? "nothing to move" : "the other side is full");
    bool valid0 = sav.ChecksumsValid;
    var dir0 = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support", "Watt Bank", "Save Backups");
    Directory.CreateDirectory(dir0);
    var bak0 = Path.Combine(dir0, $"{DateTime.Now:yyyyMMdd-HHmmss} {Path.GetFileName(path)}");
    File.Copy(path, bak0, overwrite: true);
    if (cmd == "t2m") { sav.Money = wal - mv; SetMom(sav, momv + mv); } else { sav.Money = wal + mv; SetMom(sav, momv - mv); }
    var tmp0 = path + ".wbtmp";
    File.WriteAllBytes(tmp0, sav.Write().ToArray());
    var chk = SaveUtil.GetSaveFile(tmp0);
    if (chk is null || chk.Money != sav.Money || GetMom(chk) != GetMom(sav) || (valid0 && !chk.ChecksumsValid)) { File.Delete(tmp0); return Fail("verification failed; save left untouched"); }
    File.Move(tmp0, path, overwrite: true);
    Console.WriteLine(JsonSerializer.Serialize(new { ok = true, game = chk.Version.ToString(), moved = mv, money = chk.Money, momMoney = GetMom(chk), backup = bak0 }));
    return 0;
}
bool mom = cmd is "takemom" or "givemom";
if (mom && GetMom(sav) is null) return Fail("this game has no Mom's savings");
if (mom) cmd = cmd == "takemom" ? "take" : "give";
uint before = mom ? GetMom(sav)!.Value : sav.Money;
uint maxv = mom ? 999999u : (uint)sav.MaxMoney;
bool wasValid = sav.ChecksumsValid;
uint after;
if (cmd == "take") {
    if (amount > before) return Fail($"the save only has {before}");
    after = before - amount;
} else if (cmd == "give") {
    after = (uint)Math.Min((long)before + amount, (long)maxv);
} else return Fail("unknown command " + cmd);

// backup the untouched file first
var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
    "Library", "Application Support", "Watt Bank", "Save Backups");
Directory.CreateDirectory(dir);
var bak = Path.Combine(dir, $"{DateTime.Now:yyyyMMdd-HHmmss} {Path.GetFileName(path)}");
File.Copy(path, bak, overwrite: true);

if (mom) SetMom(sav, after); else sav.Money = after;
var data = sav.Write();
var tmp = path + ".wbtmp";
File.WriteAllBytes(tmp, data.ToArray());
// verify before replacing the real file
var check = SaveUtil.GetSaveFile(tmp);
if (check is null || (mom ? GetMom(check) : check.Money) != after || (wasValid && !check.ChecksumsValid)) { File.Delete(tmp); return Fail("verification failed; save left untouched"); }
File.Move(tmp, path, overwrite: true);
Console.WriteLine(JsonSerializer.Serialize(new { ok = true, game = check.Version.ToString(), before, after, moved = Math.Abs((long)before - after), backup = bak }));
return 0;

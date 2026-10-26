// ESP32 raw IR head v4 (Watt Bank IR link) — GBC / Pocket Pikachu 2 GS
// Wiring: IR LED on GPIO 18 (via 100 ohm), IR receiver on GPIO 19 (pull-up to 3.3V, LOW = light)
// Serial 115200:
//   b = blink LED 10x
//   c = capture: wait up to 30 s for IR, then record 10 s, print pulse timings (us)
//   d = DEPOSIT test: act as a second Pikachu (like Watt Bank). Pikachu: Watts > Send.
//       Prints the watts received and a step log.
// Protocol ported from Watt Bank v1.5 ir.s / main.c (Gen 2 Mystery Gift / Pikachu 2 GS framing).

#define IR_LED  18
#define IR_RX   19
#define BLUE    2            // on-board blue LED: signal indicator
#define STRONG  150          // hello pulse must read at least this long (us) to try linking

// ---------- timing (GBC timer units) ----------
#define T        30.52f          // one fast-timer tick, us (32768 Hz)
#define US(t)    ((uint32_t)((t) * T + 0.5f))
#define SLOT     183             // one bit slot (12 ticks @ 65536 Hz)
#define BIT_ON   61              // LED on at start of each bit slot
#define BIT1_MIN 275             // light-start to light-start >= 275 us -> bit 1
#define WAIT_TO  7812            // wait_light / wait_dark timeout (256 ticks)

const uint8_t MSG_PFX = 0x5A, ST_OK = 0x6C, REGION = 0x96, PIKA = 0xF3;
const int PAYLOAD_LEN = 67;

// ---------- capture (debug) ----------
const int MAXE = 2000;
volatile uint32_t t[MAXE];
volatile uint8_t lvl[MAXE];
volatile int n = 0;
volatile bool armed = false;
// idle light meter: counts pulses and the widest one; loop() reports "#IR <pulses> <widest us>" every 100 ms
volatile bool monitor = true;
volatile uint32_t irCount = 0, irMaxW = 0, irStart = 0;
void IRAM_ATTR edge() {
  if (monitor && !armed) {
    uint32_t now = micros();
    if (digitalRead(IR_RX) == LOW) { irStart = now; irCount++; }
    else if (irStart) { uint32_t w = now - irStart; if (w > irMaxW) irMaxW = w; irStart = 0; }
    return;
  }
  if (!armed || n >= MAXE) return;
  t[n] = micros(); lvl[n] = digitalRead(IR_RX); n++;
}

// ---------- low level ----------
static inline bool light() { return digitalRead(IR_RX) == LOW; }
static bool ledState = false;
static inline void led(bool on) {
  digitalWrite(IR_LED, on ? HIGH : LOW);
  if (on != ledState) { ledState = on; if (armed && n < MAXE) { noInterrupts(); t[n] = micros(); lvl[n] = on ? 3 : 2; n++; interrupts(); } }
}
static void waitUntil(uint32_t tt) { while ((int32_t)(micros() - tt) < 0) {} }
static void hold(bool on, uint32_t us) { led(on); uint32_t s = micros(); waitUntil(s + us); }

bool waitLight(uint32_t to = WAIT_TO) { uint32_t s = micros(); while (!light()) if (micros() - s > to) return false; return true; }
bool waitDark (uint32_t to = WAIT_TO) { uint32_t s = micros(); while ( light()) if (micros() - s > to) return false; return true; }
// after we transmit, our own LED may still read as light for a moment: wait for a clean dark
// max 300 us: just long enough for the receiver's own stretch, short enough not to swallow a partner pulse
void settle(uint32_t mx = 300) { led(false); uint32_t s = micros(); while (micros() - s < mx) { if (!light()) return; } }

// ---------- step log ----------
char logbuf[1500]; int logn = 0;
void L(const char* fmt, ...) {
  va_list a; va_start(a, fmt);
  logn += vsnprintf(logbuf + logn, sizeof(logbuf) - logn, fmt, a);
  va_end(a);
  if (logn > (int)sizeof(logbuf) - 2) logn = sizeof(logbuf) - 2;
}
uint16_t dbgInt[64]; int dbgN = 0;
uint32_t lastW1 = 0, lastW2 = 0; int weakCount = 0;
bool verbose = false;   // 'v' toggles the full pulse timeline after each transfer

// ---------- hello ----------
void helloPattern() {
  hold(false, US(60)); hold(true, US(4)); hold(false, US(20)); hold(true, US(4)); hold(false, US(4));
}
bool recvHello(uint32_t firstTo = WAIT_TO) {
  if (!waitLight(firstTo)) return false;
  if (!waitDark()) return false;
  if (!waitLight()) return false;
  if (!waitDark()) return false;
  // like the GBC: last pulse, then listen right away (partner's lead pulse can follow within ~120 us)
  hold(false, US(60)); hold(true, US(4)); hold(false, US(20)); hold(true, US(4));
  settle(150);
  return true;
}
// deposit wait: like recvHello but measures both hello pulses; returns 0 none/broken, 1 weak, 2 linked
int recvHelloStrong() {
  uint32_t a = micros(); if (!waitDark()) return 0; uint32_t w1 = micros() - a;
  if (!waitLight()) return 0; a = micros(); if (!waitDark()) return 0; uint32_t w2 = micros() - a;
  if (w1 < STRONG || w2 < STRONG) { lastW1 = w1; lastW2 = w2; return 1; }
  hold(false, US(60)); hold(true, US(4)); hold(false, US(20)); hold(true, US(4));
  settle(150);
  lastW1 = w1; lastW2 = w2;
  return 2;
}
bool sendHello() {
  helloPattern(); settle();
  if (!waitLight()) return false;
  if (!waitDark()) return false;
  if (!waitLight()) return false;
  if (!waitDark()) return false;
  hold(false, US(60));
  return true;
}

// ---------- messages ----------
uint16_t cks;
void sendMsg(const uint8_t* p, int cnt) {
  hold(false, US(4)); hold(true, US(4)); hold(false, US(20));
  uint32_t tt = micros();
  for (int i = 0; i < cnt; i++) {
    uint8_t b = p[i]; cks += b;
    for (int k = 7; k >= 0; k--) {
      waitUntil(tt); led(true); waitUntil(tt + BIT_ON); led(false);
      tt += ((b >> k) & 1) ? 2 * SLOT : SLOT;
    }
  }
  waitUntil(tt); hold(true, US(4)); hold(false, US(16));
  settle();
}
// Receives cnt bytes. Works with weak signals (Pikachu) and with strong ones (GBC) where the receiver
// stays lit ~150 us after each pulse, so back-to-back 0 bits (pulses 183 us apart) merge into one long
// flash. The lead pulse (122 us) tells us how wide one 61 us bit pulse looks; each light run is then
// split into k pulses spaced one slot apart.
bool recvMsg(uint8_t* p, int cnt) {
  if (!waitLight()) { L(" lead-light-timeout"); return false; }
  uint32_t ls = micros();
  if (!waitDark())  { L(" lead-dark-timeout");  return false; }
  int single = (int)(micros() - ls) - 61;          // visible width of one bit pulse
  if (!waitLight()) { L(" first-bit-timeout");  return false; }
  int need = cnt * 8, got = 0, idx = 0;
  uint8_t cur = 0;
  bool trailerDone = false;
  uint32_t rs = micros();                            // start of the current light run
  while (got < need) {
    if (!waitDark(150000)) { L(" run-dark-timeout@%d", got); return false; }
    int D = (int)(micros() - rs);
    int k = 1 + (int)lroundf((float)(D - single) / SLOT);
    if (k < 1) k = 1;
    for (int i = 0; i < k - 1 && got < need; i++) {  // every pulse followed inside the run is a 0
      cur = (cur << 1); got++;
      if ((got & 7) == 0) { p[idx++] = cur; cks += cur; cur = 0; }
    }
    if (got >= need) { trailerDone = true; break; }   // rest of this run was the trailer
    if (!waitLight(2000)) { L(" bit-light-timeout@%d", got); return false; }
    uint32_t nx = micros();
    uint32_t dt = nx - (rs + (uint32_t)(k - 1) * SLOT);
    if (dbgN < 64) dbgInt[dbgN++] = dt;
    cur = (cur << 1) | (dt >= BIT1_MIN ? 1 : 0); got++;
    if ((got & 7) == 0) { p[idx++] = cur; cks += cur; cur = 0; }
    rs = nx;
  }
  if (!trailerDone && !waitDark()) { L(" trailer-timeout"); return false; }
  hold(false, US(15));
  return true;
}

// ---------- blocks ----------
bool sendBlock(const uint8_t* d, int len) {
  cks = 0; hold(false, US(60));
  uint8_t hdr[2] = {MSG_PFX, (uint8_t)len};
  sendMsg(hdr, 2);
  sendMsg(d, len);
  uint16_t c = cks; uint8_t cb[2] = {(uint8_t)(c & 0xFF), (uint8_t)(c >> 8)};
  sendMsg(cb, 2);
  uint8_t st = 0;
  uint16_t save = cks;
  if (!recvMsg(&st, 1)) { L(" no-ack"); return false; }
  cks = save;
  if (st != ST_OK) { L(" ack=%02X", st); return false; }
  return true;
}
// returns received length, or -1 on error
int recvBlock(uint8_t* d, int maxlen) {
  cks = 0;
  uint8_t hdr[2];
  if (!recvMsg(hdr, 2)) return -1;
  uint8_t st = ST_OK;
  if (hdr[0] != MSG_PFX || hdr[1] > maxlen) { L(" bad-hdr %02X %02X", hdr[0], hdr[1]); st |= 0x80; }
  int len = (st == ST_OK) ? hdr[1] : 0;
  if (!recvMsg(d, len)) return -1;   // empty data message still has lead + trailer
  uint16_t c = cks;
  uint8_t cb[2];
  if (!recvMsg(cb, 2)) return -1;
  if ((uint16_t)(cb[0] | (cb[1] << 8)) != c) { L(" bad-cks"); st |= 0x01; }
  hold(false, US(60));
  uint8_t s = st; sendMsg(&s, 1);
  return st == ST_OK ? len : -1;
}
bool sendBytes(const uint8_t* d, int len) { return sendBlock(d, len) && sendBlock(d, 0); }
bool recvBytes(uint8_t* d, int len) { uint8_t dummy[1]; return recvBlock(d, len) >= 0 && recvBlock(dummy, 0) >= 0; }

// ---------- deposit: Pikachu (Watts > Send) is role A, we are role B ----------
void deposit() {
  logn = 0; dbgN = 0; logbuf[0] = 0;
  n = 0; armed = false;
  Serial.println("DEPOSIT: Pikachu Watts > Send now (waiting up to 60 s; blue light = strong signal, linking)"); Serial.flush();
  uint8_t one = 0, buf[PAYLOAD_LEN];
  int step = 0; bool ok = false; bool cancelled = false, wrong = false, bad = false; int watts = -1;
  weakCount = 0; digitalWrite(BLUE, LOW);
  uint32_t start = millis();
  while (millis() - start < 60000) {
    if (Serial.available() && Serial.read() == 'x') { cancelled = true; break; }
    if (light()) {
      n = 0; armed = true; t[0] = micros(); lvl[0] = 1; n = 1;
      int r = recvHelloStrong();
      if (r == 2) { ok = true; break; }
      if (r == 1) weakCount++;
    }
  }
  if (!ok) { if (cancelled) { L("cancelled"); goto out; } L("step0 no strong hello (weak hellos skipped: %d, last widths %u/%u us)", weakCount, lastW1, lastW2); goto out; }
  digitalWrite(BLUE, HIGH); Serial.println("#LINK");
  step = 1; Serial.printf("#STEP %d\n", step); L("hello ok (widths %u/%u us, weak skipped %d);", lastW1, lastW2, weakCount);
  if (!recvBytes(&one, 1)) { L(" step1 recv region fail"); goto out; }
  L(" A:%02X;", one);
  if (one != REGION) { L(" not 0x96"); wrong = true; goto out; }
  step = 2; Serial.printf("#STEP %d\n", step);
  if (!sendHello()) { L(" step2 hello fail"); goto out; }
  one = PIKA;
  if (!sendBytes(&one, 1)) { L(" step2 send F3 fail"); goto out; }
  step = 3; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step3 hello fail"); goto out; }
  memset(buf, 0xFF, sizeof buf);
  if (!recvBytes(buf, PAYLOAD_LEN)) { L(" step3 payload fail"); goto out; }
  L(" PAYLOAD %02X %02X = %X%02X W;", buf[0], buf[1], buf[0], buf[1]);
  if (buf[0] > 9 || (buf[1] >> 4) > 9 || (buf[1] & 15) > 9) { bad = true; goto out; }
  watts = buf[0] * 100 + (buf[1] >> 4) * 10 + (buf[1] & 15);
  Serial.printf("#GOT %d\n", watts);
  step = 4; Serial.printf("#STEP %d\n", step);
  if (!sendHello()) { L(" step4 hello fail"); goto out; }
  one = REGION;
  if (!sendBytes(&one, 1)) { L(" step4 send 96 fail"); goto out; }
  step = 5; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step5 hello fail"); goto out; }
  if (!recvBytes(&one, 1)) { L(" step5 region fail"); goto out; }
  step = 6; Serial.printf("#STEP %d\n", step);
  if (!sendHello()) { L(" step6 hello fail"); goto out; }
  memset(buf, 0, PAYLOAD_LEN);
  if (!sendBytes(buf, PAYLOAD_LEN)) { L(" step6 payload fail"); goto out; }
  step = 7; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step7 hello fail"); goto out; }
  { uint8_t d[1]; if (recvBlock(d, 0) < 0) { L(" step7 empty fail"); goto out; } }
  step = 8; Serial.printf("#STEP %d\n", step); L(" DONE");
out:
  led(false); armed = false;
  if (step == 8) { for (int i = 0; i < 10; i++) { digitalWrite(BLUE, i & 1); delay(100); } }
  digitalWrite(BLUE, LOW);
  Serial.printf("DEPOSIT result: reached step %d/8\n%s\n", step, logbuf);
  if (step == 8) Serial.printf("#DEPOSIT OK %d\n", watts);
  else if (cancelled) Serial.println("#DEPOSIT CANCEL");
  else if (step == 0) Serial.println("#DEPOSIT TIMEOUT");
  else if (wrong) Serial.println("#DEPOSIT NOTPIKA");
  else if (bad) Serial.println("#DEPOSIT BADDATA");
  else if (watts < 0) Serial.println("#DEPOSIT FAIL EARLY");
  else Serial.printf("#DEPOSIT FAIL LATE %d\n", watts);
  Serial.print("first bit intervals (us):");
  for (int i = 0; i < dbgN; i++) Serial.printf(" %u", dbgInt[i]);
  Serial.println();
  if (!verbose) return;
  Serial.printf("TIMELINE %d events (us from first light; RX=Pikachu/receiver, TX=our LED)\n", n);
  for (int i = 0; i < n; i++) {
    const char* w = lvl[i] == 0 ? "RX light" : lvl[i] == 1 ? "RX dark " : lvl[i] == 3 ? "TX on   " : "TX off  ";
    if (i == 0) w = "RX light";
    Serial.printf("%7lu %s\n", (unsigned long)(t[i] - t[0]), w);
    if ((i & 63) == 63) delay(5);
  }
}

// ---------- withdraw: we are role A (sender), Pikachu (Watts > Receive) is role B ----------
void withdraw(int amount) {
  logn = 0; dbgN = 0; logbuf[0] = 0; n = 0; armed = false;
  if (amount < 1 || amount > 999) { Serial.println("WITHDRAW: amount must be 1-999"); Serial.println("#WITHDRAW BADAMOUNT"); return; }
  Serial.printf("WITHDRAW %d W: Pikachu Watts > Receive now (calling for up to 60 s)\n", amount); Serial.flush();
  uint8_t one, buf[PAYLOAD_LEN];
  int step = 0; bool ok = false; bool cancelled = false, wrong = false, sent = false;
  digitalWrite(BLUE, LOW);
  uint32_t start = millis();
  while (millis() - start < 60000) {
    if (Serial.available() && Serial.read() == 'x') { cancelled = true; break; }
    n = 0; armed = true;
    if (sendHello()) { ok = true; break; }
    led(false); delayMicroseconds(random(200, 3000));
  }
  if (!ok) { if (cancelled) { L("cancelled"); goto out; } L("step0 Pikachu never answered"); goto out; }
  digitalWrite(BLUE, HIGH); Serial.println("#LINK");
  step = 1; Serial.printf("#STEP %d\n", step); L("hello ok;");
  one = REGION;
  if (!sendBytes(&one, 1)) { L(" step1 send 96 fail"); goto out; }
  step = 2; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step2 hello fail"); goto out; }
  if (!recvBytes(&one, 1)) { L(" step2 recv code fail"); goto out; }
  L(" B:%02X;", one);
  if (one != PIKA) { L(" not a Pikachu"); wrong = true; goto out; }
  step = 3; Serial.printf("#STEP %d\n", step);
  if (!sendHello()) { L(" step3 hello fail"); goto out; }
  memset(buf, 0, PAYLOAD_LEN);
  buf[0] = amount / 100; buf[1] = (((amount / 10) % 10) << 4) | (amount % 10);
  if (!sendBlock(buf, PAYLOAD_LEN)) { L(" step3 payload fail"); goto out; }
  step = 4; Serial.printf("#STEP %d\n", step); L(" PAYLOAD SENT %02X %02X;", buf[0], buf[1]); sent = true;   // from here the watts have left
  if (!sendBlock(buf, 0)) { L(" step4 empty fail"); goto out; }
  step = 5; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step5 hello fail"); goto out; }
  if (!recvBytes(&one, 1)) { L(" step5 region fail"); goto out; }
  step = 6; Serial.printf("#STEP %d\n", step);
  if (!sendHello()) { L(" step6 hello fail"); goto out; }
  one = PIKA;
  if (!sendBytes(&one, 1)) { L(" step6 send F3 fail"); goto out; }
  step = 7; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step7 hello fail"); goto out; }
  if (!recvBytes(buf, PAYLOAD_LEN)) { L(" step7 payload fail"); goto out; }
  if (!sendHello()) { L(" step8 hello fail"); goto out; }
  if (!sendBlock(buf, 0)) { L(" step8 empty fail"); goto out; }
  step = 8; Serial.printf("#STEP %d\n", step); L(" DONE");
out:
  led(false); armed = false;
  if (step == 8) { for (int i = 0; i < 10; i++) { digitalWrite(BLUE, i & 1); delay(100); } }
  digitalWrite(BLUE, LOW);
  Serial.printf("WITHDRAW result: reached step %d/8\n%s\n", step, logbuf);
  if (step == 8) Serial.printf("#WITHDRAW OK %d\n", amount);
  else if (cancelled) Serial.println("#WITHDRAW CANCEL");
  else if (step == 0) Serial.println("#WITHDRAW TIMEOUT");
  else if (wrong) Serial.println("#WITHDRAW NOTPIKA");
  else if (!sent) Serial.println("#WITHDRAW FAIL EARLY");
  else Serial.printf("#WITHDRAW FAIL LATE %d\n", amount);
  Serial.print("first bit intervals (us):");
  for (int i = 0; i < dbgN; i++) Serial.printf(" %u", dbgInt[i]);
  Serial.println();
}

// ---------- Mystery Gift to Pokémon Gold/Silver/Crystal: we act as a Pikachu 2 GS (role A) ----------
// Crystal: MYSTERY GIFT from the main menu, press A. type 0 = item, 1 = decoration; code = 0x00-0x24.
// Order: A 96 / B region / A 20-byte card / B 96 / A region (copied) / B its card / A empty.
void gift(int type, int code, int fallback) {
  logn = 0; dbgN = 0; logbuf[0] = 0; n = 0; armed = false;
  if (type < 0 || type > 1 || code < 0 || code > 0x24 || fallback < 0 || fallback > 0x24) { Serial.println("#GIFT BADARGS"); return; }
  Serial.printf("GIFT type %d code 0x%02X: Crystal Mystery Gift, press A (calling for up to 60 s)\n", type, code); Serial.flush();
  uint8_t one, region = 0, card[20], buf[PAYLOAD_LEN];
  int step = 0; bool ok = false, cancelled = false, wrong = false, sent = false; int waiting = -1;
  digitalWrite(BLUE, LOW);
  uint32_t start = millis();
  while (millis() - start < 60000) {
    if (Serial.available() && Serial.read() == 'x') { cancelled = true; break; }
    n = 0; armed = true;
    if (sendHello()) { ok = true; break; }
    led(false); delayMicroseconds(random(200, 3000));
  }
  if (!ok) { L(cancelled ? "cancelled" : "step0 game never answered"); goto out; }
  digitalWrite(BLUE, HIGH); Serial.println("#LINK");
  step = 1; Serial.printf("#STEP %d\n", step); L("hello ok;");
  one = REGION;
  if (!sendBytes(&one, 1)) { L(" step1 send 96 fail"); goto out; }
  step = 2; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step2 hello fail"); goto out; }
  if (!recvBytes(&region, 1)) { L(" step2 recv region fail"); goto out; }
  L(" region:%02X;", region);
  if (region == PIKA) { L(" partner is a Pikachu"); wrong = true; goto out; }
  step = 3; Serial.printf("#STEP %d\n", step);
  if (!sendHello()) { L(" step3 hello fail"); goto out; }
  {
    const uint8_t name[11] = {0x8F, 0x88, 0x8A, 0x80, 0x82, 0x87, 0x94, 0x50, 0x50, 0x50, 0x50};  // "PIKACHU"
    card[0] = 0x03;                       // version: Pokémon Pikachu 2 GS (game skips daily limits, one pass)
    card[1] = 0x00; card[2] = 0x00;       // trainer ID
    memcpy(card + 3, name, 11);
    card[14] = 0x00;                      // pokédex count
    card[15] = type;                      // 0 item, 1 decoration
    card[16] = type == 0 ? code : fallback;  // item; for a decoration: what arrives if it is already owned
    card[17] = type == 1 ? code : 0x00;   // decoration
    card[18] = 0x00;                      // our backup item: none
    card[19] = 0x00;                      // gifts today
  }
  if (!sendBlock(card, 20)) { L(" step3 card fail"); goto out; }
  step = 4; Serial.printf("#STEP %d\n", step); sent = true;
  if (!sendBlock(card, 0)) { L(" step4 empty fail"); goto out; }
  step = 5; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step5 hello fail"); goto out; }
  if (!recvBytes(&one, 1)) { L(" step5 prefix fail"); goto out; }
  step = 6; Serial.printf("#STEP %d\n", step);
  if (!sendHello()) { L(" step6 hello fail"); goto out; }
  if (!sendBytes(&region, 1)) { L(" step6 region fail"); goto out; }
  step = 7; Serial.printf("#STEP %d\n", step);
  if (!recvHello()) { L(" step7 hello fail"); goto out; }
  memset(buf, 0, sizeof buf);
  if (!recvBytes(buf, PAYLOAD_LEN)) { L(" step7 card fail"); goto out; }
  waiting = buf[18];                       // game's own gift still waiting at a Pokémon Center = gift refused
  L(" game card v%02X waiting %02X;", buf[0], buf[18]);
  if (!sendHello()) { L(" step8 hello fail"); goto out; }
  if (!sendBlock(buf, 0)) { L(" step8 empty fail"); goto out; }
  step = 8; Serial.printf("#STEP %d\n", step); L(" DONE");
out:
  led(false); armed = false;
  if (step == 8) { for (int i = 0; i < 10; i++) { digitalWrite(BLUE, i & 1); delay(100); } }
  digitalWrite(BLUE, LOW);
  Serial.printf("GIFT result: reached step %d/8\n%s\n", step, logbuf);
  if (step == 8) {                       // + the game's trainer ID and name (raw game charset, hex)
    Serial.printf("#GIFT OK %d %02X%02X ", waiting, buf[1], buf[2]);
    for (int i = 3; i < 14; i++) Serial.printf("%02X", buf[i]);
    Serial.println();
  }
  else if (cancelled) Serial.println("#GIFT CANCEL");
  else if (step == 0) Serial.println("#GIFT TIMEOUT");
  else if (wrong) Serial.println("#GIFT NOTGAME");
  else if (!sent) Serial.println("#GIFT FAIL EARLY");
  else Serial.println("#GIFT FAIL LATE");
}

// ---------- other commands ----------
// blue on-board light: quick flashes so you can see the board (boot = installed, 'f' = found by Watt Bank's installer)
void blueBlink(int times, int ms) {
  for (int i = 0; i < times; i++) { digitalWrite(BLUE, HIGH); delay(ms); digitalWrite(BLUE, LOW); delay(ms); }
}
void blinkTest() {
  for (int i = 0; i < 10; i++) { led(true); delay(200); led(false); delay(200); }
  Serial.println("Blink done");
}
void capture() {
  n = 0; armed = true;
  Serial.println("Armed: waiting up to 60 s; blue light = strong signal, linking for IR, then recording 10 s");
  uint32_t w = millis();
  while (n == 0 && millis() - w < 30000) delay(1);
  uint32_t start = millis();
  while (millis() - start < 10000 && n < MAXE) delay(1);
  armed = false;
  Serial.printf("%d edges\n", n);
  for (int i = 1; i < n; i++)
    Serial.printf("%s %lu\n", lvl[i - 1] == LOW ? "ON " : "off", (unsigned long)(t[i] - t[i - 1]));
}

void setup() {
  Serial.begin(115200);
  pinMode(IR_LED, OUTPUT); led(false);
  pinMode(IR_RX, INPUT);
  pinMode(BLUE, OUTPUT); digitalWrite(BLUE, LOW);
  attachInterrupt(digitalPinToInterrupt(IR_RX), edge, CHANGE);
  blueBlink(3, 120);                    // 3 quick blue flashes on every start: firmware running
  Serial.println("Ready v4.8: b=blink, f=find (blue blink), c=capture, d=deposit, w<watts>=withdraw, g<type>,<code>,<fallback>=Mystery Gift, x=cancel, v=verbose, ?=id");
  Serial.println("#READY WATTBANK-IR 4.8");
}
void loop() {
  static uint32_t lastReport = 0;
  if (millis() - lastReport >= 100) {
    lastReport = millis();
    noInterrupts(); uint32_t c = irCount, w = irMaxW; irCount = 0; irMaxW = 0; interrupts();
    if (c) Serial.printf("#IR %u %u\n", c, w);
  }
  if (Serial.available()) {
    char c = Serial.read();
    monitor = false;                       // transfers need the receiver to themselves
    if (c == 'b') blinkTest();
    else if (c == 'c') capture();
    else if (c == 'd') deposit();
    else if (c == '?') {                   // answer once, even if a burst of '?' piled up
      static uint32_t lastId = 0;
      while (Serial.peek() == '?') Serial.read();
      if (millis() - lastId > 200) { Serial.println("#READY WATTBANK-IR 4.8"); lastId = millis(); }
    }
    else if (c == 'f') { Serial.println("#FOUND"); blueBlink(6, 100); }   // Watt Bank's installer: "this board"
    else if (c == 'v') { verbose = !verbose; Serial.printf("verbose %d\n", verbose); }
    else if (c == 'g') { Serial.setTimeout(2000); int ty = Serial.parseInt(); int co = Serial.parseInt(); int fb = Serial.parseInt(); gift(ty, co, fb); }
    else if (c == 'w') { Serial.setTimeout(2000); withdraw(Serial.parseInt()); }
    noInterrupts(); irCount = 0; irMaxW = 0; irStart = 0; interrupts();
    monitor = true;
  }
}

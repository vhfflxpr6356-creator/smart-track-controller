#include <Arduino.h>
#include <BluetoothSerial.h>
#include <Preferences.h>

// Verified in the original firmware and by switch diagnostics.
constexpr uint8_t MOTOR_PINS[] = {16, 17, 18, 19};
constexpr uint8_t BOARD_LIMIT = 27;  // app LEFT
constexpr uint8_t FAR_LIMIT = 26;    // app RIGHT
// Original four-output sequence, NOT a STEP/DIR driver protocol.
constexpr uint8_t PHASES[4][4] = {
  {0, 1, 1, 0}, {0, 1, 0, 1}, {1, 0, 0, 1}, {1, 0, 1, 0}
};
// Speed presets: low / medium / high. Smaller interval means faster motion.
constexpr uint32_t SPEED_INTERVAL_US[] = {10000, 6000, 4000};
constexpr uint32_t CALIBRATION_STEP_US = 6000;
constexpr uint32_t TRAVEL_TIMEOUT_MS = 20000;
constexpr uint32_t MANUAL_TIMEOUT_MS = 600;
constexpr uint32_t LINK_TIMEOUT_MS = 1500;
constexpr uint32_t AUTO_DWELL_MS = 500;
constexpr uint32_t MAX_TRAVEL_STEPS = 3000;
constexpr uint32_t JOG_STEPS = 12;
// Change 600 here for the default distance from the HOME switch.
// A saved MIDDLE=n setting takes priority; MIDDLE=DEFAULT clears that override.
constexpr uint32_t DEFAULT_MIDDLE_STEPS = 600; // trial distance, not a measured center
constexpr uint32_t MIN_MIDDLE_STEPS = 12;
constexpr uint32_t MAX_MIDDLE_STEPS = 2400;
static_assert(DEFAULT_MIDDLE_STEPS >= MIN_MIDDLE_STEPS &&
              DEFAULT_MIDDLE_STEPS <= MAX_MIDDLE_STEPS,
              "DEFAULT_MIDDLE_STEPS must be between 12 and 2400");
constexpr uint32_t HOME_RELEASE_STEPS = 30;

BluetoothSerial bt;
Preferences settings;
enum Mode { STOPPED, MANUAL, AUTOMATIC, CALIBRATION, FAULT };
Mode mode = STOPPED;
enum AutoStage { SEEK_HOME, OUT_TO_MIDDLE, RETURN_HOME };
AutoStage autoStage = SEEK_HOME;
bool homeAtBoard = true;
uint32_t middleSteps = DEFAULT_MIDDLE_STEPS;
uint8_t speedLevel = 1; // 0=low, 1=medium, 2=high
bool directionKnown = false;
bool positiveIsLeft = false;
bool connected = false;
int logicalDirection = 0; // -1 left, +1 right
int phaseDirection = 1;
int phase = 0;
uint32_t legStart = 0, steps = 0, lastManual = 0, lastPeer = 0;
uint32_t lastStep = 0, dwellStart = 0, lastStatus = 0;
bool dwelling = false;
char btFrame[3];
uint8_t frameSize = 0;
String serialLine;
const char *reason = "boot";

bool leftPressed() { return digitalRead(BOARD_LIMIT) == LOW; }
bool rightPressed() { return digitalRead(FAR_LIMIT) == LOW; }
void motorOff() {
  for (uint8_t pin : MOTOR_PINS) digitalWrite(pin, LOW);
}
void stopMotor(const char *why, bool fault = false) {
  motorOff();
  mode = fault ? FAULT : STOPPED;
  logicalDirection = 0;
  dwelling = false;
  reason = why;
}
const char *modeName() {
  switch (mode) {
    case MANUAL: return "MANUAL";
    case AUTOMATIC: return "AUTO";
    case CALIBRATION: return "CALIBRATION";
    case FAULT: return "FAULT";
    default: return "STOP";
  }
}
void report() {
  char line[180];
  snprintf(line, sizeof(line),
           "STATE:%s LEFT:%d RIGHT:%d READY:%d REASON:%s\n",
           modeName(), leftPressed(), rightPressed(), directionKnown, reason);
  Serial.print(line);
  Serial.printf("SPEED:%u\n", speedLevel);
  Serial.printf("AUTO_CONFIG: HOME=%s MIDDLE_STEPS=%lu\n",
                homeAtBoard ? "BOARD" : "FAR", static_cast<unsigned long>(middleSteps));
  if (bt.hasClient()) {
    bt.print("FW:OBSTACLE_V2\n");
    bt.print(line);
    bt.printf("SPEED:%u\n", speedLevel);
  }
}
int homeDirection() { return homeAtBoard ? -1 : 1; }
bool homePressed() { return homeAtBoard ? leftPressed() : rightPressed(); }

uint32_t stepInterval() {
  return mode == CALIBRATION ? CALIBRATION_STEP_US : SPEED_INTERVAL_US[speedLevel];
}
uint32_t travelTimeout() {
  const uint32_t speedAllowance = MAX_TRAVEL_STEPS * stepInterval() / 1000 + 3000;
  return speedAllowance > TRAVEL_TIMEOUT_MS ? speedAllowance : TRAVEL_TIMEOUT_MS;
}

bool targetPressed() {
  return logicalDirection < 0 ? leftPressed() : rightPressed();
}
void startLeg(int direction) {
  logicalDirection = direction;
  phaseDirection = ((direction < 0) == positiveIsLeft) ? 1 : -1;
  steps = 0;
  legStart = millis();
  lastStep = micros();
  dwelling = false;
  reason = "moving";
}
void processCommand(const char *cmd) {
  lastPeer = millis();
  if (!strcmp(cmd, "B30") || !strcmp(cmd, "B31") || !strcmp(cmd, "B32")) {
    if (mode != STOPPED) { report(); return; }
    const uint8_t requested = cmd[2] - '0';
    if (requested != speedLevel) {
      speedLevel = requested;
      settings.putUChar("speed", speedLevel);
    }
    report();
    return;
  }
  if (!strcmp(cmd, "B25")) return; // link heartbeat; never initiates movement
  if (!strcmp(cmd, "B22") || !strcmp(cmd, "B11")) {
    stopMotor("operator_stop", leftPressed() && rightPressed());
    report();
    return;
  }
  // Old ON command has no defined destination in this new control scheme.
  if (!strcmp(cmd, "B12")) { stopMotor("legacy_on_disabled"); return; }
  if (!directionKnown || mode == FAULT || mode == CALIBRATION) return;
  if (!strcmp(cmd, "B10")) {
    if (mode != AUTOMATIC) {
      mode = AUTOMATIC;
      autoStage = SEEK_HOME;
      startLeg(homeDirection());
    }
    return;
  }
  if (!strcmp(cmd, "B20") || !strcmp(cmd, "B21")) {
    const int direction = !strcmp(cmd, "B20") ? -1 : 1;
    lastManual = millis();
    // Repeated hold commands do not reset the leg safety limits.
    if (mode != MANUAL || logicalDirection != direction) {
      mode = MANUAL;
      startLeg(direction);
    }
  }
}
void readBluetooth() {
  // Fixed-length frames tolerate packet splitting, concatenation and newlines.
  for (int budget = 0; budget < 48 && bt.available(); ++budget) {
    char c = static_cast<char>(bt.read());
    if (c == 'B') { btFrame[0] = c; frameSize = 1; continue; }
    if (frameSize == 0) continue;
    if (c < '0' || c > '9') { frameSize = 0; continue; }
    btFrame[frameSize++] = c;
    if (frameSize == 3) {
      char command[4] = {btFrame[0], btFrame[1], btFrame[2], 0};
      frameSize = 0;
      processCommand(command);
    }
  }
}
void serialCommand(const String &line) {
  if (line == "STOP") { stopMotor("serial_stop"); report(); return; }
  if (line == "STATUS") { report(); return; }
  if (line == "RESETMAP") {
    stopMotor("map_cleared");
    directionKnown = false;
    settings.putBool("known", false);
    report();
    return;
  }
  if (mode != STOPPED) {
    Serial.println("Stop first: STOP");
    return;
  }
  if (line == "HOMEBOARD" || line == "HOMEFAR") {
    homeAtBoard = line == "HOMEBOARD";
    settings.putBool("homeBoard", homeAtBoard);
    Serial.println(homeAtBoard ? "HOME:BOARD" : "HOME:FAR");
    return;
  }
  if (line == "MIDDLE=DEFAULT") {
    settings.remove("middle");
    middleSteps = DEFAULT_MIDDLE_STEPS;
    Serial.printf("MIDDLE_STEPS:%lu\n", static_cast<unsigned long>(middleSteps));
    return;
  }
  if (line.startsWith("MIDDLE=")) {
    const String value = line.substring(7);
    bool digits = value.length() > 0 && value.length() <= 4;
    for (size_t i = 0; i < value.length(); ++i) {
      if (value[i] < '0' || value[i] > '9') digits = false;
    }
    const uint32_t requested = digits ? value.toInt() : 0;
    if (requested < MIN_MIDDLE_STEPS || requested > MAX_MIDDLE_STEPS) {
      Serial.println("MIDDLE rejected: integer 12..2400 required.");
      return;
    }
    middleSteps = requested;
    settings.putUInt("middle", middleSteps);
    Serial.printf("MIDDLE_STEPS:%lu\n", static_cast<unsigned long>(middleSteps));
    return;
  }
  if (line == "MAP+LEFT" || line == "MAP+RIGHT") {
    positiveIsLeft = line == "MAP+LEFT";
    settings.putBool("plusLeft", positiveIsLeft);
    settings.putBool("known", true);
    directionKnown = true;
    reason = "direction_saved";
    report();
  } else if (line == "JOG+" || line == "JOG-") {
    if (leftPressed() || rightPressed()) {
      Serial.println("JOG blocked: both limit switches must be released.");
      return;
    }
    mode = CALIBRATION;
    phaseDirection = line == "JOG+" ? 1 : -1;
    steps = 0;
    legStart = millis();
    lastStep = micros();
    reason = "short_jog";
    report();
  }
}
void readSerial() {
  for (int budget = 0; budget < 48 && Serial.available(); ++budget) {
    char c = static_cast<char>(Serial.read());
    if (c == '\r' || c == '\n') {
      if (serialLine.length()) { serialCommand(serialLine); serialLine = ""; }
    } else if (serialLine.length() < 48) {
      serialLine += c;
    } else {
      serialLine = "";
    }
  }
}
void serviceMotor() {
  const uint32_t now = millis();
  if (leftPressed() && rightPressed()) {
    stopMotor("both_limits", true);
    return;
  }
  if (mode == STOPPED || mode == FAULT) { motorOff(); return; }
  if (mode != CALIBRATION &&
      (!bt.hasClient() || now - lastPeer > LINK_TIMEOUT_MS)) {
    stopMotor("link_lost"); return;
  }
  if (mode == MANUAL && now - lastManual > MANUAL_TIMEOUT_MS) {
    stopMotor("hold_expired"); return;
  }
  if (mode == CALIBRATION) {
    if (leftPressed() || rightPressed() || steps >= JOG_STEPS) {
      stopMotor("jog_finished"); return;
    }
  } else if (mode == MANUAL && targetPressed()) {
    stopMotor("end_limit"); return;
  }
  if (mode == AUTOMATIC && !dwelling) {
    if (autoStage == OUT_TO_MIDDLE) {
      if (steps >= HOME_RELEASE_STEPS && homePressed()) {
        stopMotor("home_not_released", true); return;
      }
      if (targetPressed() || steps >= middleSteps) {
        // The far limit is still a stop condition if the configured distance is too long.
        motorOff();
        dwelling = true;
        dwellStart = now;
        reason = targetPressed() ? "far_limit_wait" : "middle_wait";
      }
    } else if (homePressed()) {
      motorOff();
      dwelling = true;
      dwellStart = now;
      reason = "home_wait";
    }
  }
  if (dwelling) {
    motorOff();
    if (now - dwellStart < AUTO_DWELL_MS) return;
    if (autoStage == OUT_TO_MIDDLE) {
      autoStage = RETURN_HOME;
      startLeg(homeDirection());
    } else {
      autoStage = OUT_TO_MIDDLE;
      startLeg(-homeDirection());
    }
    return;
  }
  if (now - legStart >= travelTimeout() || steps >= MAX_TRAVEL_STEPS) {
    Serial.printf("LIMIT: elapsed_ms=%lu steps=%lu time_limit_ms=%lu step_limit=%lu\n",
                  static_cast<unsigned long>(now - legStart),
                  static_cast<unsigned long>(steps),
                  static_cast<unsigned long>(travelTimeout()),
                  static_cast<unsigned long>(MAX_TRAVEL_STEPS));
    stopMotor("travel_timeout", true); return;
  }
  if (static_cast<uint32_t>(micros() - lastStep) < stepInterval()) return;
  lastStep = micros();
  phase = (phase + phaseDirection + 4) % 4;
  for (size_t i = 0; i < 4; ++i) digitalWrite(MOTOR_PINS[i], PHASES[phase][i]);
  ++steps;
}
void setup() {
  for (uint8_t pin : MOTOR_PINS) {
    digitalWrite(pin, LOW); pinMode(pin, OUTPUT); digitalWrite(pin, LOW);
  }
  pinMode(BOARD_LIMIT, INPUT_PULLUP);
  pinMode(FAR_LIMIT, INPUT_PULLUP);
  // GPIO23 is deliberately untouched: its external circuit is unidentified.
  Serial.begin(115200);
  settings.begin("obstacle-v2", false);
  speedLevel = settings.getUChar("speed", 1);
  if (speedLevel > 2) speedLevel = 1;
  directionKnown = settings.getBool("known", false);
  positiveIsLeft = settings.getBool("plusLeft", false);
  homeAtBoard = settings.getBool("homeBoard", true);
  middleSteps = settings.getUInt("middle", DEFAULT_MIDDLE_STEPS);
  if (middleSteps < MIN_MIDDLE_STEPS || middleSteps > MAX_MIDDLE_STEPS) {
    middleSteps = DEFAULT_MIDDLE_STEPS;
  }
  serialLine.reserve(48);
  bt.begin("ESP32_Obstacle_2");
  Serial.println("Boot idle. Serial: STATUS, JOG+, JOG-, MAP+LEFT, MAP+RIGHT, STOP, RESETMAP, HOMEBOARD, HOMEFAR, MIDDLE=n");
  report();
}
void loop() {
  const bool client = bt.hasClient();
  if (client != connected) {
    stopMotor(client ? "connected_idle" : "disconnected");
    connected = client;
    frameSize = 0;
    lastPeer = millis();
    report();
  }
  readSerial();
  readBluetooth();
  serviceMotor();
  if (millis() - lastStatus >= 500) { lastStatus = millis(); report(); }
  delay(1);
}

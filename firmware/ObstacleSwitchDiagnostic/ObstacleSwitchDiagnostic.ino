#include <Arduino.h>

// GPIO16..19 and their LOW stop state are confirmed from original firmware.
constexpr uint8_t MOTOR_PINS[] = {16, 17, 18, 19};
// GPIO27 is confirmed; GPIO26/14 are candidates from connector markings.
// No physical LEFT/RIGHT assignment is assumed.
constexpr uint8_t SWITCH_PINS[] = {27, 26, 14};
constexpr size_t SWITCH_COUNT = sizeof(SWITCH_PINS) / sizeof(SWITCH_PINS[0]);
constexpr uint32_t DEBOUNCE_MS = 30;
int rawLevels[SWITCH_COUNT];
int stableLevels[SWITCH_COUNT];
uint32_t changedAt[SWITCH_COUNT];
uint32_t lastReport = 0;

void holdMotorStopped() {
  for (uint8_t pin : MOTOR_PINS) digitalWrite(pin, LOW);
}

void printInputs() {
  Serial.printf("%lu ms | GPIO27=%s | GPIO26=%s | GPIO14=%s\n",
                static_cast<unsigned long>(millis()),
                stableLevels[0] == HIGH ? "HIGH" : "LOW",
                stableLevels[1] == HIGH ? "HIGH" : "LOW",
                stableLevels[2] == HIGH ? "HIGH" : "LOW");
}

void setup() {
  // Set stop outputs before serial startup or delays; never issue steps.
  for (uint8_t pin : MOTOR_PINS) {
    digitalWrite(pin, LOW);
    pinMode(pin, OUTPUT);
    digitalWrite(pin, LOW);
  }
  // GPIO23 hardware role is unknown and is deliberately untouched.
  for (size_t i = 0; i < SWITCH_COUNT; ++i) {
    // Assumes dry contacts to GND. Pull-ups do not verify wiring.
    pinMode(SWITCH_PINS[i], INPUT_PULLUP);
    rawLevels[i] = digitalRead(SWITCH_PINS[i]);
    stableLevels[i] = rawLevels[i];
    changedAt[i] = millis();
  }
  Serial.begin(115200);
  Serial.println("SWITCH DIAGNOSTIC: motor GPIO16/17/18/19 held LOW");
  Serial.println("No Bluetooth or movement commands. GPIO23 untouched.");
  Serial.println("Record idle, LEFT pressed, RIGHT pressed, then released.");
  Serial.println("HIGH/LOW are raw levels; pressed polarity is unconfirmed.");
  printInputs();
}

void loop() {
  holdMotorStopped();
  const uint32_t now = millis();
  bool changed = false;
  for (size_t i = 0; i < SWITCH_COUNT; ++i) {
    const int level = digitalRead(SWITCH_PINS[i]);
    if (level != rawLevels[i]) {
      rawLevels[i] = level;
      changedAt[i] = now;
    }
    if (level != stableLevels[i] && now - changedAt[i] >= DEBOUNCE_MS) {
      stableLevels[i] = level;
      changed = true;
    }
  }
  if (changed || now - lastReport >= 1000) {
    printInputs();
    lastReport = now;
  }
  delay(1);
}

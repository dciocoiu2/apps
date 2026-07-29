#include <Arduino.h>
#include <WiFi.h>
#include <esp_wifi.h>
#include <esp_now.h>
#include <NimBLEDevice.h>
#include <ArduinoJson.h>

/* -------------------------------------------------------------------------- */
/* CHIP DETECTION (Arduino-ESP32 Core)                                        */
/* -------------------------------------------------------------------------- */

enum ChipType {
  CHIP_UNKNOWN = 0,
  CHIP_ESP32,
  CHIP_ESP32S3,
  CHIP_ESP32C6,
  CHIP_ESP32C5,
  CHIP_ESP32H2,
  CHIP_ESP32P4
};

ChipType detectChip() {
  String model = ESP.getChipModel();

  if (model.indexOf("ESP32-S3") >= 0) return CHIP_ESP32S3;
  if (model.indexOf("ESP32-C6") >= 0) return CHIP_ESP32C6;
  if (model.indexOf("ESP32-C5") >= 0) return CHIP_ESP32C5;
  if (model.indexOf("ESP32-H2") >= 0) return CHIP_ESP32H2;
  if (model.indexOf("ESP32-P4") >= 0) return CHIP_ESP32P4;
  if (model.indexOf("ESP32") >= 0) return CHIP_ESP32;

  return CHIP_UNKNOWN;
}

String chipName(ChipType c) {
  switch (c) {
    case CHIP_ESP32: return "ESP32";
    case CHIP_ESP32S3: return "ESP32-S3";
    case CHIP_ESP32C6: return "ESP32-C6";
    case CHIP_ESP32C5: return "ESP32-C5";
    case CHIP_ESP32H2: return "ESP32-H2";
    case CHIP_ESP32P4: return "ESP32-P4";
    default: return "UNKNOWN";
  }
}

/* -------------------------------------------------------------------------- */
/* CAPABILITIES                                                               */
/* -------------------------------------------------------------------------- */

struct Caps {
  bool wifi;
  bool ble;
  bool ieee;
  bool espnow;
};

Caps getCaps(ChipType c) {
  Caps caps = {false,false,false,false};

  switch (c) {
    case CHIP_ESP32:
    case CHIP_ESP32S3:
      caps.wifi = true;
      caps.ble = true;
      caps.espnow = true;
      break;

    case CHIP_ESP32C6:
      caps.wifi = true;
      caps.ble = true;
      caps.ieee = true;
      break;

    case CHIP_ESP32C5:
      caps.wifi = true;
      caps.ble = true;
      break;

    case CHIP_ESP32H2:
      caps.ble = true;
      caps.ieee = true;
      break;

    case CHIP_ESP32P4:
      caps.wifi = true;
      caps.ble = true;
      break;

    default:
      break;
  }

  return caps;
}

/* -------------------------------------------------------------------------- */
/* ROLE + TRANSPORT                                                           */
/* -------------------------------------------------------------------------- */

enum Role {
  ROLE_UNKNOWN = 0,
  ROLE_WIFI_ONLY,
  ROLE_BLE_ONLY,
  ROLE_WIFI_BLE,
  ROLE_MESH_IEEE
};

enum Transport {
  TX_WIFI = 0,
  TX_ESPNOW,
  TX_SPI,
  TX_WIRED
};

Role autoRole(const Caps &caps) {
  if (caps.wifi && caps.ble && caps.ieee) return ROLE_WIFI_BLE;
  if (caps.wifi && caps.ble) return ROLE_WIFI_BLE;
  if (caps.wifi && !caps.ble) return ROLE_WIFI_ONLY;
  if (!caps.wifi && caps.ble && caps.ieee) return ROLE_MESH_IEEE;
  if (!caps.wifi && caps.ble) return ROLE_BLE_ONLY;
  return ROLE_UNKNOWN;
}

Transport autoTransport(const Caps &caps) {
  if (caps.espnow) return TX_ESPNOW;
  if (caps.wifi) return TX_WIFI;
  if (caps.ble) return TX_WIFI;
  return TX_WIFI;
}

String roleName(Role r) {
  switch (r) {
    case ROLE_WIFI_ONLY: return "WIFI_ONLY";
    case ROLE_BLE_ONLY: return "BLE_ONLY";
    case ROLE_WIFI_BLE: return "WIFI_BLE";
    case ROLE_MESH_IEEE: return "MESH_IEEE802154";
    default: return "UNKNOWN";
  }
}

String transportName(Transport t) {
  switch (t) {
    case TX_WIFI: return "wifi";
    case TX_ESPNOW: return "espnow";
    case TX_SPI: return "spi";
    case TX_WIRED: return "wired";
    default: return "wifi";
  }
}

/* -------------------------------------------------------------------------- */
/* GLOBAL STATE                                                               */
/* -------------------------------------------------------------------------- */

ChipType chip;
Caps caps;
Role role;
Transport txMode;

String nodeId;

String hubIP = "192.168.4.1";
int hubPort = 3333;

WiFiClient hub;

/* -------------------------------------------------------------------------- */
/* BLE CONFIG (same UUIDs as coordinator)                                     */
/* -------------------------------------------------------------------------- */

#define CONFIG_SERVICE_UUID "0000c0de-0000-1000-8000-00805f9b34fb"
#define CONFIG_CHAR_UUID    "0000c0cf-0000-1000-8000-00805f9b34fb"

class ConfigCallback : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic *c) override {
    std::string v = c->getValue();
    DynamicJsonDocument doc(256);
    deserializeJson(doc, v);

    if (doc["cmd"] == "init_config") {
      hubIP = doc["hub_ip"].as<String>();
      hubPort = doc["hub_port"].as<int>();
      role = (doc["role"] == "WIFI_BLE") ? ROLE_WIFI_BLE :
             (doc["role"] == "WIFI_ONLY") ? ROLE_WIFI_ONLY :
             (doc["role"] == "BLE_ONLY") ? ROLE_BLE_ONLY :
             (doc["role"] == "MESH_IEEE802154") ? ROLE_MESH_IEEE :
             ROLE_UNKNOWN;

      String t = doc["transport"].as<String>();
      if (t == "wifi") txMode = TX_WIFI;
      else if (t == "espnow") txMode = TX_ESPNOW;
      else if (t == "spi") txMode = TX_SPI;
      else if (t == "wired") txMode = TX_WIRED;
    }
  }
};

void initBLE() {
  NimBLEDevice::init("ClusterNode");
  NimBLEServer *srv = NimBLEDevice::createServer();
  NimBLEService *svc = srv->createService(CONFIG_SERVICE_UUID);
  NimBLECharacteristic *ch = svc->createCharacteristic(
    CONFIG_CHAR_UUID,
    NIMBLE_PROPERTY::WRITE
  );
  ch->setCallbacks(new ConfigCallback());
  svc->start();
  srv->getAdvertising()->start();
}

/* -------------------------------------------------------------------------- */
/* WIFI + TCP JSON                                                             */
/* -------------------------------------------------------------------------- */

void connectHub() {
  if (!hub.connected()) {
    hub.connect(hubIP.c_str(), hubPort);
  }
}

void sendJSON(const JsonDocument &doc) {
  connectHub();
  if (!hub.connected()) return;

  String out;
  serializeJson(doc, out);
  hub.println(out);
}

/* -------------------------------------------------------------------------- */
/* IDENTITY                                                                    */
/* -------------------------------------------------------------------------- */

void sendIdentity() {
  DynamicJsonDocument doc(256);
  doc["src"] = "node";
  doc["id"] = nodeId;
  doc["chip"] = chipName(chip);
  doc["role"] = roleName(role);
  doc["transport"] = transportName(txMode);
  doc["type"] = "identity";
  sendJSON(doc);
}

/* -------------------------------------------------------------------------- */
/* WIFI SCAN                                                                   */
/* -------------------------------------------------------------------------- */

unsigned long lastWifiScan = 0;
int wifiScanInterval = 10000;

void doWifiScan() {
  if (!caps.wifi) return;
  if (role == ROLE_BLE_ONLY) return;

  int n = WiFi.scanNetworks();
  for (int i = 0; i < n; i++) {
    DynamicJsonDocument doc(512);
    doc["src"] = "node";
    doc["id"] = nodeId;
    doc["chip"] = chipName(chip);
    doc["role"] = roleName(role);
    doc["transport"] = transportName(txMode);
    doc["type"] = "scan_wifi";
    doc["ssid"] = WiFi.SSID(i);
    doc["bssid"] = WiFi.BSSIDstr(i);
    doc["ch"] = WiFi.channel(i);
    doc["rssi"] = WiFi.RSSI(i);
    sendJSON(doc);
  }
}

/* -------------------------------------------------------------------------- */
/* BLE SCAN                                                                    */
/* -------------------------------------------------------------------------- */

unsigned long lastBleScan = 0;
int bleScanInterval = 15000;

class BLEScanCB : public NimBLEAdvertisedDeviceCallbacks {
  void onResult(NimBLEAdvertisedDevice *dev) override {
    DynamicJsonDocument doc(256);
    doc["src"] = "node";
    doc["id"] = nodeId;
    doc["chip"] = chipName(chip);
    doc["role"] = roleName(role);
    doc["transport"] = transportName(txMode);
    doc["type"] = "scan_ble";
    doc["mac"] = dev->getAddress().toString().c_str();
    doc["rssi"] = dev->getRSSI();
    sendJSON(doc);
  }
};

void doBleScan() {
  if (!caps.ble) return;
  if (role == ROLE_WIFI_ONLY) return;

  NimBLEScan *scan = NimBLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(new BLEScanCB());
  scan->setActiveScan(false);
  scan->start(5);
}

/* -------------------------------------------------------------------------- */
/* COMMAND RX                                                                  */
/* -------------------------------------------------------------------------- */

void handleCommands() {
  connectHub();
  while (hub.connected() && hub.available()) {
    String line = hub.readStringUntil('\n');
    DynamicJsonDocument doc(256);
    deserializeJson(doc, line);

    if (doc["cmd"] == "set_role") {
      String r = doc["role"];
      if (r == "WIFI_ONLY") role = ROLE_WIFI_ONLY;
      else if (r == "BLE_ONLY") role = ROLE_BLE_ONLY;
      else if (r == "WIFI_BLE") role = ROLE_WIFI_BLE;
      else if (r == "MESH_IEEE802154") role = ROLE_MESH_IEEE;
    }

    if (doc["cmd"] == "set_transport") {
      String t = doc["transport"];
      if (t == "wifi") txMode = TX_WIFI;
      else if (t == "espnow") txMode = TX_ESPNOW;
      else if (t == "spi") txMode = TX_SPI;
      else if (t == "wired") txMode = TX_WIRED;
    }

    if (doc["cmd"] == "set_wifi_interval") {
      wifiScanInterval = doc["ms"];
    }
    if (doc["cmd"] == "set_ble_interval") {
      bleScanInterval = doc["ms"];
    }
  }
}

/* -------------------------------------------------------------------------- */
/* SETUP                                                                       */
/* -------------------------------------------------------------------------- */

void setup() {
  Serial.begin(115200);

  chip = detectChip();
  caps = getCaps(chip);
  role = autoRole(caps);
  txMode = autoTransport(caps);

  uint8_t mac[6];
  esp_read_mac(mac, ESP_MAC_WIFI_STA);
  char buf[18];
  sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X",
          mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
  nodeId = buf;

  if (caps.ble) initBLE();

  if (caps.wifi) {
    WiFi.mode(WIFI_STA);
    WiFi.begin("YOUR_SSID", "YOUR_PASS");
    while (WiFi.status() != WL_CONNECTED) delay(100);
    hub.connect(hubIP.c_str(), hubPort);
    sendIdentity();
  }
}

/* -------------------------------------------------------------------------- */
/* LOOP                                                                        */
/* -------------------------------------------------------------------------- */

void loop() {
  unsigned long now = millis();

  handleCommands();

  if (now - lastWifiScan > wifiScanInterval) {
    lastWifiScan = now;
    doWifiScan();
  }

  if (now - lastBleScan > bleScanInterval) {
    lastBleScan = now;
    doBleScan();
  }

  delay(20);
}
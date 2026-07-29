/*
  UNIVERSAL CLUSTER NODE
  - ESP32 / ESP32-S3 / ESP32-C6 / ESP32-H2 / ESP32-P4
  - Auto-detect chip + capabilities
  - Auto role assignment
  - Auto transport selection (WiFi JSON / ESP-NOW / SPI / wired)
  - Auto channel hopping (WiFi + IEEE802.15.4)
  - WiFi + BLE scan, IEEE placeholder
  - Unified hybrid protocol:
      WiFi: JSON lines
      ESP-NOW/SPI/wired: binary frames
  - Command receiver:
      set_role, set_mode, set_wifi_interval, set_ieee_interval, set_transport
*/

#include <Arduino.h>
#include <WiFi.h>
#include <esp_chip_info.h>
#include <esp_system.h>
#include <esp_wifi.h>
#include <esp_mac.h>

#if __has_include(<esp_ieee802154.h>)
#include <esp_ieee802154.h>
#endif

#if __has_include(<esp_now.h>)
#include <esp_now.h>
#endif

#if __has_include(<NimBLEDevice.h>)
#include <NimBLEDevice.h>
#endif

// ---------- HUB CONFIG ----------
const char* HUB_SSID     = "CLUSTER_CTRL";
const char* HUB_PASSWORD = "cluster123";
const uint16_t HUB_PORT  = 3333;

// ---------- ROLES / TRANSPORT ----------
enum NodeRole {
  ROLE_UNKNOWN = 0,
  ROLE_WIFI_ONLY,
  ROLE_BLE_ONLY,
  ROLE_WIFI_BLE,
  ROLE_MESH_IEEE802154
};

enum Transport {
  TX_WIFI_JSON = 0,
  TX_ESPNOW    = 1,
  TX_SPI       = 2,
  TX_WIRED     = 3
};

struct NodeCaps {
  String chip;
  bool wifi;
  bool ble;
  bool ieee;
  bool espnow;
  bool spi;
  bool wired;
};

NodeCaps caps;
NodeRole nodeRole = ROLE_UNKNOWN;
Transport primaryTx = TX_WIFI_JSON;

// ---------- CHANNEL HOPPING ----------
const int wifiChannels[] = {1, 6, 11};
const int wifiChannelCount = sizeof(wifiChannels) / sizeof(wifiChannels[0]);
int wifiChannelIndex = 0;

const int ieeeChannels[] = {11, 15, 20, 25};
const int ieeeChannelCount = sizeof(ieeeChannels) / sizeof(ieeeChannels[0]);
int ieeeChannelIndex = 0;

unsigned long lastWifiHop = 0;
unsigned long lastIeeeHop = 0;
unsigned long wifiHopInterval = 15000;
unsigned long ieeeHopInterval = 20000;

// ---------- SCAN INTERVALS ----------
unsigned long wifiScanInterval = 10000;
unsigned long bleScanInterval  = 15000;
unsigned long ieeeScanInterval = 20000;

// ---------- HUB LINK ----------
WiFiClient hubClient;

// ---------- NODE ID ----------
uint8_t nodeId[6];
String nodeIdStr;

// ---------- ESP-NOW ----------
bool espNowReady = false;
uint8_t hubEspNowMac[6];

// ---------- WIRED (UART) ----------
HardwareSerial& wiredSerial = Serial1;

// ---------- SPI (slave placeholder) ----------
bool spiEnabled = false;

// ---------- CRC ----------
uint16_t crc16(const uint8_t *data, size_t len) {
  uint16_t crc = 0xFFFF;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int j = 0; j < 8; j++) {
      if (crc & 1) crc = (crc >> 1) ^ 0xA001;
      else crc >>= 1;
    }
  }
  return crc;
}

// ---------- FRAME BUILDER ----------
size_t buildFrame(uint8_t *buf, uint8_t type, const uint8_t nodeId[6],
                  const uint8_t *payload, uint16_t plen) {
  size_t idx = 0;
  buf[idx++] = 0xA5;
  buf[idx++] = 0x01;
  buf[idx++] = 0x00;
  buf[idx++] = type;
  memcpy(&buf[idx], nodeId, 6); idx += 6;
  buf[idx++] = (plen >> 8) & 0xFF;
  buf[idx++] = plen & 0xFF;
  memcpy(&buf[idx], payload, plen); idx += plen;
  uint16_t crc = crc16(buf, idx);
  buf[idx++] = (crc >> 8) & 0xFF;
  buf[idx++] = crc & 0xFF;
  return idx;
}

// ---------- CAPS / ROLE / TRANSPORT ----------
void detectCaps() {
  esp_chip_info_t info;
  esp_chip_info(&info);

  caps.chip = "ESP32-UNKNOWN";
  caps.wifi = caps.ble = caps.ieee = caps.espnow = caps.spi = caps.wired = false;

  switch (info.model) {
    case CHIP_ESP32:
      caps.chip = "ESP32";
      caps.wifi = true;
      caps.ble = true;
      caps.espnow = true;
      break;
    case CHIP_ESP32S3:
      caps.chip = "ESP32-S3";
      caps.wifi = true;
      caps.ble = true;
      caps.espnow = true;
      break;
    case CHIP_ESP32C6:
      caps.chip = "ESP32-C6";
      caps.wifi = true;
      caps.ble = true;
      caps.ieee = true;
      break;
    case CHIP_ESP32H2:
      caps.chip = "ESP32-H2";
      caps.ble = true;
      caps.ieee = true;
      break;
    case CHIP_ESP32P4:
      caps.chip = "ESP32-P4";
      caps.wifi = true;
      caps.ble = true;
      caps.ieee = true;
      break;
  }

  caps.spi   = true;
  caps.wired = true;
}

void assignRole() {
  if (caps.ieee) nodeRole = ROLE_MESH_IEEE802154;
  else if (caps.wifi && caps.ble) nodeRole = ROLE_WIFI_BLE;
  else if (caps.wifi) nodeRole = ROLE_WIFI_ONLY;
  else if (caps.ble) nodeRole = ROLE_BLE_ONLY;
  else nodeRole = ROLE_UNKNOWN;
}

String roleToString(NodeRole r) {
  switch (r) {
    case ROLE_WIFI_ONLY:       return "WIFI_ONLY";
    case ROLE_BLE_ONLY:        return "BLE_ONLY";
    case ROLE_WIFI_BLE:        return "WIFI_BLE";
    case ROLE_MESH_IEEE802154: return "MESH_IEEE802154";
    default:                   return "UNKNOWN";
  }
}

String transportToString(Transport t) {
  switch (t) {
    case TX_WIFI_JSON: return "wifi";
    case TX_ESPNOW:    return "espnow";
    case TX_SPI:       return "spi";
    case TX_WIRED:     return "wired";
    default:           return "wifi";
  }
}

void selectTransport() {
  if (caps.espnow)      primaryTx = TX_ESPNOW;
  else if (caps.wifi)   primaryTx = TX_WIFI_JSON;
  else if (caps.spi)    primaryTx = TX_SPI;
  else if (caps.wired)  primaryTx = TX_WIRED;
  else                  primaryTx = TX_WIFI_JSON;
}

// ---------- NODE ID ----------
void initNodeId() {
  esp_read_mac(nodeId, ESP_MAC_WIFI_STA);
  char buf[18];
  sprintf(buf, "%02X:%02X:%02X:%02X:%02X:%02X",
          nodeId[0], nodeId[1], nodeId[2],
          nodeId[3], nodeId[4], nodeId[5]);
  nodeIdStr = String(buf);
}

// ---------- HUB LINK ----------
void connectToHubWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(HUB_SSID, HUB_PASSWORD);
  while (WiFi.status() != WL_CONNECTED) {
    delay(250);
  }
  hubClient.stop();
  hubClient.connect(IPAddress(192,168,4,1), HUB_PORT);
}

void sendJson(const String &json) {
  if (!hubClient.connected()) {
    hubClient.connect(IPAddress(192,168,4,1), HUB_PORT);
  }
  if (hubClient.connected()) hubClient.println(json);
}

// ---------- ESP-NOW ----------
void onEspNowSent(const uint8_t *mac, esp_now_send_status_t status) {}

void initEspNow() {
#if __has_include(<esp_now.h>)
  if (!caps.espnow) return;
  WiFi.mode(WIFI_STA);
  if (esp_now_init() != ESP_OK) return;
  esp_now_register_send_cb(onEspNowSent);
  memcpy(hubEspNowMac, nodeId, 6); // default: hub MAC later overridden
  espNowReady = true;
#endif
}

void sendFrameEspNow(uint8_t type, const uint8_t *payload, uint16_t plen) {
#if __has_include(<esp_now.h>)
  if (!espNowReady) return;
  uint8_t buf[256];
  size_t len = buildFrame(buf, type, nodeId, payload, plen);
  esp_now_send(hubEspNowMac, buf, len);
#endif
}

// ---------- SPI / WIRED ----------
void sendFrameSpi(uint8_t type, const uint8_t *payload, uint16_t plen) {
  // placeholder: SPI slave implementation depends on hardware
}

void sendFrameWired(uint8_t type, const uint8_t *payload, uint16_t plen) {
  uint8_t buf[256];
  size_t len = buildFrame(buf, type, nodeId, payload, plen);
  wiredSerial.write(buf, len);
}

// ---------- HYBRID SEND ----------
void sendTelemetry(uint8_t type, const String &jsonPayload) {
  if (primaryTx == TX_WIFI_JSON && caps.wifi) {
    sendJson(jsonPayload);
  } else {
    uint8_t payload[200];
    size_t plen = jsonPayload.length();
    if (plen > sizeof(payload)) plen = sizeof(payload);
    memcpy(payload, jsonPayload.c_str(), plen);
    switch (primaryTx) {
      case TX_ESPNOW: sendFrameEspNow(type, payload, plen); break;
      case TX_SPI:    sendFrameSpi(type, payload, plen);    break;
      case TX_WIRED:  sendFrameWired(type, payload, plen);  break;
      default:        sendJson(jsonPayload);                break;
    }
  }
}

// ---------- CHANNEL HOP ----------
void hopWifiChannelIfNeeded() {
  if (!caps.wifi) return;
  if (millis() - lastWifiHop > wifiHopInterval) {
    lastWifiHop = millis();
    wifiChannelIndex = (wifiChannelIndex + 1) % wifiChannelCount;
    int ch = wifiChannels[wifiChannelIndex];
    esp_wifi_set_channel(ch, WIFI_SECOND_CHAN_NONE);
  }
}

void hopIeeeChannelIfNeeded() {
  if (!caps.ieee) return;
  if (millis() - lastIeeeHop > ieeeHopInterval) {
    lastIeeeHop = millis();
    ieeeChannelIndex = (ieeeChannelIndex + 1) % ieeeChannelCount;
    int ch = ieeeChannels[ieeeChannelIndex];
#if __has_include(<esp_ieee802154.h>)
    esp_ieee802154_set_channel(ch);
#endif
  }
}

// ---------- WIFI SCAN ----------
void wifiScanAndReport() {
  if (!caps.wifi) return;
  if (nodeRole == ROLE_BLE_ONLY || nodeRole == ROLE_MESH_IEEE802154) return;

  WiFi.disconnect();
  delay(100);
  int n = WiFi.scanNetworks();

  for (int i = 0; i < n; i++) {
    String ssid   = WiFi.SSID(i);
    String bssid  = WiFi.BSSIDstr(i);
    int rssi      = WiFi.RSSI(i);
    int channel   = WiFi.channel(i);

    String json = "{";
    json += "\"src\":\"node\",";
    json += "\"id\":\"" + nodeIdStr + "\",";
    json += "\"chip\":\"" + caps.chip + "\",";
    json += "\"role\":\"" + roleToString(nodeRole) + "\",";
    json += "\"transport\":\"" + transportToString(primaryTx) + "\",";
    json += "\"type\":\"scan_wifi\",";
    json += "\"ssid\":\"" + ssid + "\",";
    json += "\"bssid\":\"" + bssid + "\",";
    json += "\"ch\":" + String(channel) + ",";
    json += "\"rssi\":" + String(rssi);
    json += "}";

    sendTelemetry(0x02, json);
  }
}

// ---------- BLE SCAN ----------
#if __has_include(<NimBLEDevice.h>)
class BLEAdvertisedDeviceCallback : public NimBLEAdvertisedDeviceCallbacks {
  void onResult(NimBLEAdvertisedDevice* dev) override {
    String mac = dev->getAddress().toString().c_str();
    int rssi   = dev->getRSSI();

    String json = "{";
    json += "\"src\":\"node\",";
    json += "\"id\":\"" + nodeIdStr + "\",";
    json += "\"chip\":\"" + caps.chip + "\",";
    json += "\"role\":\"" + roleToString(nodeRole) + "\",";
    json += "\"transport\":\"" + transportToString(primaryTx) + "\",";
    json += "\"type\":\"scan_ble\",";
    json += "\"mac\":\"" + mac + "\",";
    json += "\"rssi\":" + String(rssi);
    json += "}";

    sendTelemetry(0x03, json);
  }
};
#endif

void bleScanAndReport() {
  if (!caps.ble) return;
  if (nodeRole == ROLE_WIFI_ONLY || nodeRole == ROLE_MESH_IEEE802154) return;

#if __has_include(<NimBLEDevice.h>)
  NimBLEDevice::init("ClusterNode");
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setAdvertisedDeviceCallbacks(new BLEAdvertisedDeviceCallback());
  scan->setActiveScan(false);
  scan->setInterval(100);
  scan->setWindow(50);
  scan->setDuplicateFilter(true);
  scan->start(5, nullptr, false);
  delay(6000);
  scan->stop();
  scan->clearResults();
#endif
}

// ---------- IEEE SCAN ----------
void ieeeScanAndReport() {
  if (!caps.ieee) return;
  if (nodeRole != ROLE_MESH_IEEE802154) return;

  int ch = ieeeChannels[ieeeChannelIndex];

  String json = "{";
  json += "\"src\":\"node\",";
  json += "\"id\":\"" + nodeIdStr + "\",";
  json += "\"chip\":\"" + caps.chip + "\",";
  json += "\"role\":\"" + roleToString(nodeRole) + "\",";
  json += "\"transport\":\"" + transportToString(primaryTx) + "\",";
  json += "\"type\":\"scan_ieee\",";
  json += "\"ch\":" + String(ch) + ",";
  json += "\"note\":\"802.15.4 scan not implemented\"";
  json += "}";

  sendTelemetry(0x04, json);
}

// ---------- HEARTBEAT ----------
void sendHeartbeat() {
  String json = "{";
  json += "\"src\":\"node\",";
  json += "\"id\":\"" + nodeIdStr + "\",";
  json += "\"chip\":\"" + caps.chip + "\",";
  json += "\"role\":\"" + roleToString(nodeRole) + "\",";
  json += "\"transport\":\"" + transportToString(primaryTx) + "\",";
  json += "\"type\":\"heartbeat\"";
  json += "}";

  sendTelemetry(0x01, json);
}

// ---------- COMMAND RECEIVER (WiFi JSON only for simplicity) ----------
void handleHubCommands() {
  if (!hubClient.connected()) return;
  while (hubClient.available()) {
    String line = hubClient.readStringUntil('\n');
    line.trim();
    if (!line.length()) continue;

    if (line.indexOf("\"cmd\":\"set_role\"") >= 0) {
      int idx = line.indexOf("\"role\":\"");
      int start = idx + 8;
      int end = line.indexOf("\"", start);
      String r = line.substring(start, end);
      if (r == "WIFI_ONLY") nodeRole = ROLE_WIFI_ONLY;
      else if (r == "BLE_ONLY") nodeRole = ROLE_BLE_ONLY;
      else if (r == "WIFI_BLE") nodeRole = ROLE_WIFI_BLE;
      else if (r == "MESH_IEEE802154") nodeRole = ROLE_MESH_IEEE802154;
    }

    if (line.indexOf("\"cmd\":\"set_transport\"") >= 0) {
      int idx = line.indexOf("\"transport\":\"");
      int start = idx + 13;
      int end = line.indexOf("\"", start);
      String t = line.substring(start, end);
      if (t == "wifi") primaryTx = TX_WIFI_JSON;
      else if (t == "espnow") primaryTx = TX_ESPNOW;
      else if (t == "spi") primaryTx = TX_SPI;
      else if (t == "wired") primaryTx = TX_WIRED;
    }

    if (line.indexOf("\"cmd\":\"set_wifi_interval\"") >= 0) {
      int idx = line.indexOf("\"ms\":");
      int val = line.substring(idx + 5).toInt();
      if (val > 1000) wifiScanInterval = val;
    }

    if (line.indexOf("\"cmd\":\"set_ieee_interval\"") >= 0) {
      int idx = line.indexOf("\"ms\":");
      int val = line.substring(idx + 5).toInt();
      if (val > 1000) ieeeScanInterval = val;
    }

    if (line.indexOf("\"cmd\":\"set_hub_mac\"") >= 0) {
      int idx = line.indexOf("\"mac\":\"");
      int start = idx + 7;
      int end = line.indexOf("\"", start);
      String macStr = line.substring(start, end);
      int last = 0;
      for (int i = 0; i < 6; i++) {
        int colon = macStr.indexOf(':', last);
        String part = (colon == -1 ? macStr.substring(last) : macStr.substring(last, colon));
        hubEspNowMac[i] = strtol(part.c_str(), nullptr, 16);
        last = colon + 1;
      }
    }
  }
}

// ---------- TIMERS ----------
unsigned long lastWifiScan = 0;
unsigned long lastBleScan  = 0;
unsigned long lastIeeeScan = 0;
unsigned long lastHeartbeat = 0;

// ---------- SETUP / LOOP ----------
void setup() {
  Serial.begin(115200);
  delay(500);

  detectCaps();
  assignRole();
  selectTransport();
  initNodeId();

  wiredSerial.begin(115200, SERIAL_8N1, 16, 17); // example pins

  connectToHubWifi();
  initEspNow();

  Serial.println("Cluster Node Boot");
  Serial.println("ID: " + nodeIdStr);
  Serial.println("Chip: " + caps.chip);
  Serial.println("Role: " + roleToString(nodeRole));
  Serial.println("Transport: " + transportToString(primaryTx));
}

void loop() {
  hopWifiChannelIfNeeded();
  hopIeeeChannelIfNeeded();
  handleHubCommands();

  unsigned long now = millis();

  if (now - lastWifiScan > wifiScanInterval) {
    lastWifiScan = now;
    wifiScanAndReport();
  }

  if (now - lastBleScan > bleScanInterval) {
    lastBleScan = now;
    bleScanAndReport();
  }

  if (now - lastIeeeScan > ieeeScanInterval) {
    lastIeeeScan = now;
    ieeeScanAndReport();
  }

  if (now - lastHeartbeat > 5000) {
    lastHeartbeat = now;
    sendHeartbeat();
  }

  delay(20);
}
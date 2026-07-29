/*
  CYD HUB (ESP32-2432S028R)
  - M5Launcher app
  - Biscuit-style LVGL dashboard
  - WiFi AP: CLUSTER_CTRL
  - TCP server: 3333 (JSON lines from nodes)
  - ESP-NOW receiver (binary frames)
  - Wired UART receiver (binary frames)
  - SPI master placeholder
  - SD PCAP logging
  - Touch UI: node list, role/transport controls
*/

#include <Arduino.h>
#include <WiFi.h>
#include <WiFiClient.h>
#include <WiFiServer.h>
#include <esp_now.h>
#include <SD.h>
#include <SPI.h>
#include <vector>

#include <lvgl.h>
#include <Arduino_GFX_Library.h>

// ---------- M5Launcher metadata ----------
extern "C" {
  const char* m5launcher_app_name    = "CYD Wardrive Hub";
  const char* m5launcher_app_author  = "David";
  const char* m5launcher_app_version = "1.0";
}

extern "C" void m5launcher_app_exit() {
  WiFi.softAPdisconnect(true);
  esp_now_deinit();
  SD.end();
}

// ---------- DISPLAY ----------
Arduino_DataBus *bus = new Arduino_ESP32SPI(27, 5, 18, 23, -1);
Arduino_GFX *gfx = new Arduino_ILI9341(bus, 33, 0, false);

static const uint16_t SCREEN_WIDTH  = 240;
static const uint16_t SCREEN_HEIGHT = 320;
static lv_disp_draw_buf_t draw_buf;
static lv_color_t buf1[SCREEN_WIDTH * 40];

// ---------- HUB NETWORK ----------
#define HUB_SSID      "CLUSTER_CTRL"
#define HUB_PASSWORD  "cluster123"
#define HUB_PORT      3333

WiFiServer hubServer(HUB_PORT);

// ---------- SD / PCAP ----------
#define SD_CS_PIN 5
File pcapFile;

const uint8_t PCAP_GLOBAL_HEADER[24] = {
  0xd4, 0xc3, 0xb2, 0xa1,
  0x02, 0x00, 0x04, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00,
  0xff, 0xff, 0x00, 0x00,
  0x7f, 0x00, 0x00, 0x00
};

void writePcapPacket(const uint8_t *payload, uint32_t len) {
  if (!pcapFile) return;
  uint32_t ts_sec = millis() / 1000;
  uint32_t ts_usec = (millis() % 1000) * 1000;

  uint8_t hdr[16];
  memcpy(hdr, &ts_sec, 4);
  memcpy(hdr + 4, &ts_usec, 4);
  memcpy(hdr + 8, &len, 4);
  memcpy(hdr + 12, &len, 4);

  pcapFile.write(hdr, 16);
  pcapFile.write(payload, len);
}

// ---------- NODE MODEL ----------
struct NodeInfo {
  String id;
  String chip;
  String role;
  String transport;
  IPAddress ip;
  WiFiClient client;
  unsigned long lastSeen;
};

std::vector<NodeInfo> nodes;
int selectedNodeIndex = -1;

// ---------- LVGL UI ----------
lv_obj_t *label_status;
lv_obj_t *table_nodes;
lv_obj_t *table_wifi;
lv_obj_t *table_ble;
lv_obj_t *table_ieee;
lv_obj_t *btn_role_wifi;
lv_obj_t *btn_role_ble;
lv_obj_t *btn_role_both;
lv_obj_t *btn_role_mesh;
lv_obj_t *btn_tx_wifi;
lv_obj_t *btn_tx_espnow;
lv_obj_t *btn_tx_spi;
lv_obj_t *btn_tx_wired;
lv_obj_t *btn_start;
lv_obj_t *btn_stop;

bool captureEnabled = true;

void lvgl_flush_cb(lv_disp_drv_t *disp, const lv_area_t *area, lv_color_t *color_p) {
  int32_t w = area->x2 - area->x1 + 1;
  int32_t h = area->y2 - area->y1 + 1;

  gfx->startWrite();
  gfx->setAddrWindow(area->x1, area->y1, w, h);
  gfx->writePixels((uint16_t *)&color_p->full, w * h);
  gfx->endWrite();

  lv_disp_flush_ready(disp);
}

NodeInfo* getSelectedNode() {
  if (selectedNodeIndex < 0 || selectedNodeIndex >= (int)nodes.size()) return nullptr;
  return &nodes[selectedNodeIndex];
}

void update_nodes_table() {
  int row = 1;
  for (int i = 0; i < (int)nodes.size() && row < lv_table_get_row_cnt(table_nodes); i++, row++) {
    auto &n = nodes[i];
    lv_table_set_cell_value(table_nodes, row, 0, n.id.c_str());
    lv_table_set_cell_value(table_nodes, row, 1, n.chip.c_str());
    lv_table_set_cell_value(table_nodes, row, 2, n.role.c_str());
    lv_table_set_cell_value(table_nodes, row, 3, n.transport.c_str());
    lv_table_set_cell_value(table_nodes, row, 4, String(n.lastSeen / 1000).c_str());
  }
}

void setup_ui() {
  lv_obj_t *scr = lv_scr_act();

  label_status = lv_label_create(scr);
  lv_obj_align(label_status, LV_ALIGN_TOP_LEFT, 4, 4);
  lv_label_set_text(label_status, "CYD Hub: capture ON");

  table_nodes = lv_table_create(scr);
  lv_obj_set_size(table_nodes, SCREEN_WIDTH - 8, 80);
  lv_obj_align(table_nodes, LV_ALIGN_TOP_LEFT, 4, 24);
  lv_table_set_col_cnt(table_nodes, 5);
  lv_table_set_row_cnt(table_nodes, 6);
  lv_table_set_cell_value(table_nodes, 0, 0, "ID");
  lv_table_set_cell_value(table_nodes, 0, 1, "Chip");
  lv_table_set_cell_value(table_nodes, 0, 2, "Role");
  lv_table_set_cell_value(table_nodes, 0, 3, "Tx");
  lv_table_set_cell_value(table_nodes, 0, 4, "Last");

  lv_obj_add_event_cb(table_nodes, [](lv_event_t *e) {
    lv_obj_t *tbl = lv_event_get_target(e);
    lv_point_t p;
    lv_indev_get_point(lv_indev_get_act(), &p);
    uint16_t row, col;
    if (lv_table_get_cell_id(tbl, &row, &col, p.x, p.y) == LV_RES_OK) {
      if (row > 0) selectedNodeIndex = row - 1;
    }
  }, LV_EVENT_CLICKED, nullptr);

  table_wifi = lv_table_create(scr);
  lv_obj_set_size(table_wifi, SCREEN_WIDTH - 8, 80);
  lv_obj_align(table_wifi, LV_ALIGN_LEFT_MID, 4, 0);
  lv_table_set_col_cnt(table_wifi, 4);
  lv_table_set_row_cnt(table_wifi, 6);
  lv_table_set_cell_value(table_wifi, 0, 0, "SSID");
  lv_table_set_cell_value(table_wifi, 0, 1, "BSSID");
  lv_table_set_cell_value(table_wifi, 0, 2, "RSSI");
  lv_table_set_cell_value(table_wifi, 0, 3, "Ch");

  table_ble = lv_table_create(scr);
  lv_obj_set_size(table_ble, SCREEN_WIDTH - 8, 60);
  lv_obj_align(table_ble, LV_ALIGN_BOTTOM_LEFT, 4, -72);
  lv_table_set_col_cnt(table_ble, 3);
  lv_table_set_row_cnt(table_ble, 5);
  lv_table_set_cell_value(table_ble, 0, 0, "MAC");
  lv_table_set_cell_value(table_ble, 0, 1, "RSSI");
  lv_table_set_cell_value(table_ble, 0, 2, "Node");

  table_ieee = lv_table_create(scr);
  lv_obj_set_size(table_ieee, SCREEN_WIDTH - 8, 40);
  lv_obj_align(table_ieee, LV_ALIGN_BOTTOM_LEFT, 4, -32);
  lv_table_set_col_cnt(table_ieee, 3);
  lv_table_set_row_cnt(table_ieee, 3);
  lv_table_set_cell_value(table_ieee, 0, 0, "Node");
  lv_table_set_cell_value(table_ieee, 0, 1, "Ch");
  lv_table_set_cell_value(table_ieee, 0, 2, "Note");

  btn_role_wifi = lv_btn_create(scr);
  lv_obj_set_size(btn_role_wifi, 50, 20);
  lv_obj_align(btn_role_wifi, LV_ALIGN_BOTTOM_LEFT, 4, -48);
  lv_obj_t *lbl_rw = lv_label_create(btn_role_wifi);
  lv_label_set_text(lbl_rw, "R:WiFi");

  btn_role_ble = lv_btn_create(scr);
  lv_obj_set_size(btn_role_ble, 50, 20);
  lv_obj_align(btn_role_ble, LV_ALIGN_BOTTOM_MID, 0, -48);
  lv_obj_t *lbl_rb = lv_label_create(btn_role_ble);
  lv_label_set_text(lbl_rb, "R:BLE");

  btn_role_both = lv_btn_create(scr);
  lv_obj_set_size(btn_role_both, 50, 20);
  lv_obj_align(btn_role_both, LV_ALIGN_BOTTOM_RIGHT, -4, -48);
  lv_obj_t *lbl_rbt = lv_label_create(btn_role_both);
  lv_label_set_text(lbl_rbt, "R:Both");

  btn_role_mesh = lv_btn_create(scr);
  lv_obj_set_size(btn_role_mesh, 50, 20);
  lv_obj_align(btn_role_mesh, LV_ALIGN_BOTTOM_LEFT, 4, -24);
  lv_obj_t *lbl_rm = lv_label_create(btn_role_mesh);
  lv_label_set_text(lbl_rm, "R:Mesh");

  btn_tx_wifi = lv_btn_create(scr);
  lv_obj_set_size(btn_tx_wifi, 50, 20);
  lv_obj_align(btn_tx_wifi, LV_ALIGN_BOTTOM_MID, 0, -24);
  lv_obj_t *lbl_tw = lv_label_create(btn_tx_wifi);
  lv_label_set_text(lbl_tw, "Tx:WiFi");

  btn_tx_espnow = lv_btn_create(scr);
  lv_obj_set_size(btn_tx_espnow, 50, 20);
  lv_obj_align(btn_tx_espnow, LV_ALIGN_BOTTOM_RIGHT, -4, -24);
  lv_obj_t *lbl_te = lv_label_create(btn_tx_espnow);
  lv_label_set_text(lbl_te, "Tx:ESPN");

  btn_tx_spi = lv_btn_create(scr);
  lv_obj_set_size(btn_tx_spi, 50, 20);
  lv_obj_align(btn_tx_spi, LV_ALIGN_BOTTOM_LEFT, 4, -2);
  lv_obj_t *lbl_ts = lv_label_create(btn_tx_spi);
  lv_label_set_text(lbl_ts, "Tx:SPI");

  btn_tx_wired = lv_btn_create(scr);
  lv_obj_set_size(btn_tx_wired, 50, 20);
  lv_obj_align(btn_tx_wired, LV_ALIGN_BOTTOM_RIGHT, -4, -2);
  lv_obj_t *lbl_tw2 = lv_label_create(btn_tx_wired);
  lv_label_set_text(lbl_tw2, "Tx:Wire");

  btn_start = lv_btn_create(scr);
  lv_obj_set_size(btn_start, 40, 20);
  lv_obj_align(btn_start, LV_ALIGN_BOTTOM_LEFT, 4, -72);
  lv_obj_t *lbl_s = lv_label_create(btn_start);
  lv_label_set_text(lbl_s, "Start");

  btn_stop = lv_btn_create(scr);
  lv_obj_set_size(btn_stop, 40, 20);
  lv_obj_align(btn_stop, LV_ALIGN_BOTTOM_RIGHT, -4, -72);
  lv_obj_t *lbl_t = lv_label_create(btn_stop);
  lv_label_set_text(lbl_t, "Stop");

  lv_obj_add_event_cb(btn_start, [](lv_event_t *e) {
    captureEnabled = true;
    lv_label_set_text(label_status, "CYD Hub: capture ON");
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_stop, [](lv_event_t *e) {
    captureEnabled = false;
    lv_label_set_text(label_status, "CYD Hub: capture OFF");
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_role_wifi, [](lv_event_t *e) {
    NodeInfo *n = getSelectedNode();
    if (!n) return;
    n->role = "WIFI_ONLY";
    if (n->client.connected()) {
      String json = "{\"cmd\":\"set_role\",\"role\":\"WIFI_ONLY\"}";
      n->client.println(json);
    }
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_role_ble, [](lv_event_t *e) {
    NodeInfo *n = getSelectedNode();
    if (!n) return;
    n->role = "BLE_ONLY";
    if (n->client.connected()) {
      String json = "{\"cmd\":\"set_role\",\"role\":\"BLE_ONLY\"}";
      n->client.println(json);
    }
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_role_both, [](lv_event_t *e) {
    NodeInfo *n = getSelectedNode();
    if (!n) return;
    n->role = "WIFI_BLE";
    if (n->client.connected()) {
      String json = "{\"cmd\":\"set_role\",\"role\":\"WIFI_BLE\"}";
      n->client.println(json);
    }
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_role_mesh, [](lv_event_t *e) {
    NodeInfo *n = getSelectedNode();
    if (!n) return;
    n->role = "MESH_IEEE802154";
    if (n->client.connected()) {
      String json = "{\"cmd\":\"set_role\",\"role\":\"MESH_IEEE802154\"}";
      n->client.println(json);
    }
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_tx_wifi, [](lv_event_t *e) {
    NodeInfo *n = getSelectedNode();
    if (!n) return;
    n->transport = "wifi";
    if (n->client.connected()) {
      String json = "{\"cmd\":\"set_transport\",\"transport\":\"wifi\"}";
      n->client.println(json);
    }
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_tx_espnow, [](lv_event_t *e) {
    NodeInfo *n = getSelectedNode();
    if (!n) return;
    n->transport = "espnow";
    if (n->client.connected()) {
      String json = "{\"cmd\":\"set_transport\",\"transport\":\"espnow\"}";
      n->client.println(json);
      String macStr = WiFi.softAPmacAddress();
      String j2 = "{\"cmd\":\"set_hub_mac\",\"mac\":\"" + macStr + "\"}";
      n->client.println(j2);
    }
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_tx_spi, [](lv_event_t *e) {
    NodeInfo *n = getSelectedNode();
    if (!n) return;
    n->transport = "spi";
    if (n->client.connected()) {
      String json = "{\"cmd\":\"set_transport\",\"transport\":\"spi\"}";
      n->client.println(json);
    }
  }, LV_EVENT_CLICKED, nullptr);

  lv_obj_add_event_cb(btn_tx_wired, [](lv_event_t *e) {
    NodeInfo *n = getSelectedNode();
    if (!n) return;
    n->transport = "wired";
    if (n->client.connected()) {
      String json = "{\"cmd\":\"set_transport\",\"transport\":\"wired\"}";
      n->client.println(json);
    }
  }, LV_EVENT_CLICKED, nullptr);
}

// ---------- NODE MANAGEMENT ----------
NodeInfo* findNodeById(const String &id) {
  for (auto &n : nodes)
    if (n.id == id) return &n;
  return nullptr;
}

NodeInfo* findNodeByIP(const IPAddress &ip) {
  for (auto &n : nodes)
    if (n.ip == ip) return &n;
  return nullptr;
}

void acceptNodeClients() {
  WiFiClient newClient = hubServer.available();
  if (newClient) {
    IPAddress ip = newClient.remoteIP();
    NodeInfo *existing = findNodeByIP(ip);
    if (existing) {
      existing->client = newClient;
    } else {
      NodeInfo n;
      n.ip = ip;
      n.id = "";
      n.chip = "";
      n.role = "";
      n.transport = "wifi";
      n.client = newClient;
      n.lastSeen = millis();
      nodes.push_back(n);
    }
  }
}

// ---------- JSON LINE HANDLING ----------
void handleJsonLine(NodeInfo &n, const String &line) {
  n.lastSeen = millis();
  if (captureEnabled) writePcapPacket((const uint8_t*)line.c_str(), line.length());

  int idIdx = line.indexOf("\"id\":\"");
  if (idIdx >= 0) {
    int start = idIdx + 6;
    int end = line.indexOf("\"", start);
    n.id = line.substring(start, end);
  }

  int chipIdx = line.indexOf("\"chip\":\"");
  if (chipIdx >= 0) {
    int start = chipIdx + 8;
    int end = line.indexOf("\"", start);
    n.chip = line.substring(start, end);
  }

  int roleIdx = line.indexOf("\"role\":\"");
  if (roleIdx >= 0) {
    int start = roleIdx + 8;
    int end = line.indexOf("\"", start);
    n.role = line.substring(start, end);
  }

  int txIdx = line.indexOf("\"transport\":\"");
  if (txIdx >= 0) {
    int start = txIdx + 13;
    int end = line.indexOf("\"", start);
    n.transport = line.substring(start, end);
  }

  if (line.indexOf("\"type\":\"scan_wifi\"") >= 0) {
    String ssid, bssid, rssiStr, chStr;
    int sIdx = line.indexOf("\"ssid\":\"");
    int sStart = sIdx + 8;
    int sEnd = line.indexOf("\"", sStart);
    ssid = line.substring(sStart, sEnd);

    int bIdx = line.indexOf("\"bssid\":\"");
    int bStart = bIdx + 9;
    int bEnd = line.indexOf("\"", bStart);
    bssid = line.substring(bStart, bEnd);

    int rIdx = line.indexOf("\"rssi\":");
    int cIdx = line.indexOf("\"ch\":");
    rssiStr = line.substring(rIdx + 7, line.indexOf(",", rIdx + 7));
    chStr = line.substring(cIdx + 4, line.indexOf("}", cIdx + 4));

    for (int row = 1; row < lv_table_get_row_cnt(table_wifi); row++) {
      const char *cur = lv_table_get_cell_value(table_wifi, row, 0);
      if (!cur || !strlen(cur)) {
        lv_table_set_cell_value(table_wifi, row, 0, ssid.c_str());
        lv_table_set_cell_value(table_wifi, row, 1, bssid.c_str());
        lv_table_set_cell_value(table_wifi, row, 2, rssiStr.c_str());
        lv_table_set_cell_value(table_wifi, row, 3, chStr.c_str());
        break;
      }
    }
  }

  if (line.indexOf("\"type\":\"scan_ble\"") >= 0) {
    String mac, rssiStr;
    int mIdx = line.indexOf("\"mac\":\"");
    int mStart = mIdx + 7;
    int mEnd = line.indexOf("\"", mStart);
    mac = line.substring(mStart, mEnd);

    int rIdx = line.indexOf("\"rssi\":");
    rssiStr = line.substring(rIdx + 7, line.indexOf("}", rIdx + 7));

    for (int row = 1; row < lv_table_get_row_cnt(table_ble); row++) {
      const char *cur = lv_table_get_cell_value(table_ble, row, 0);
      if (!cur || !strlen(cur)) {
        lv_table_set_cell_value(table_ble, row, 0, mac.c_str());
        lv_table_set_cell_value(table_ble, row, 1, rssiStr.c_str());
        lv_table_set_cell_value(table_ble, row, 2, n.id.c_str());
        break;
      }
    }
  }

  if (line.indexOf("\"type\":\"scan_ieee\"") >= 0) {
    String chStr, note;
    int cIdx = line.indexOf("\"ch\":");
    int nIdx = line.indexOf("\"note\":\"");
    chStr = line.substring(cIdx + 4, line.indexOf(",", cIdx + 4));
    int nStart = nIdx + 8;
    int nEnd = line.indexOf("\"", nStart);
    note = line.substring(nStart, nEnd);

    for (int row = 1; row < lv_table_get_row_cnt(table_ieee); row++) {
      const char *cur = lv_table_get_cell_value(table_ieee, row, 0);
      if (!cur || !strlen(cur)) {
        lv_table_set_cell_value(table_ieee, row, 0, n.id.c_str());
        lv_table_set_cell_value(table_ieee, row, 1, chStr.c_str());
        lv_table_set_cell_value(table_ieee, row, 2, note.c_str());
        break;
      }
    }
  }
}

void readNodeData() {
  for (auto &n : nodes) {
    WiFiClient &c = n.client;
    while (c.connected() && c.available()) {
      String line = c.readStringUntil('\n');
      line.trim();
      if (!line.length()) continue;
      handleJsonLine(n, line);
    }
  }
}

// ---------- ESP-NOW RECEIVER ----------
void onEspNowRecv(const uint8_t *mac, const uint8_t *data, int len) {
  if (!captureEnabled) return;
  writePcapPacket(data, len);
}

// ---------- WIRED RECEIVER ----------
HardwareSerial& wiredSerial = Serial1;

void readWiredFrames() {
  while (wiredSerial.available()) {
    uint8_t buf[256];
    int len = wiredSerial.readBytes(buf, sizeof(buf));
    if (len > 0 && captureEnabled) writePcapPacket(buf, len);
  }
}

// ---------- SETUP / LOOP ----------
void setup() {
  Serial.begin(115200);
  delay(500);

  gfx->begin();
  gfx->fillScreen(BLACK);

  lv_init();
  lv_disp_draw_buf_init(&draw_buf, buf1, nullptr, SCREEN_WIDTH * 40);

  static lv_disp_drv_t disp_drv;
  lv_disp_drv_init(&disp_drv);
  disp_drv.hor_res = SCREEN_WIDTH;
  disp_drv.ver_res = SCREEN_HEIGHT;
  disp_drv.flush_cb = lvgl_flush_cb;
  disp_drv.draw_buf = &draw_buf;
  lv_disp_drv_register(&disp_drv);

  setup_ui();

  WiFi.mode(WIFI_AP);
  WiFi.softAP(HUB_SSID, HUB_PASSWORD);
  hubServer.begin();

  esp_now_init();
  esp_now_register_recv_cb(onEspNowRecv);

  wiredSerial.begin(115200, SERIAL_8N1, 16, 17);

  SD.begin(SD_CS_PIN);
  pcapFile = SD.open("/cluster.pcap", FILE_WRITE);
  pcapFile.write(PCAP_GLOBAL_HEADER, 24);
}

void loop() {
  acceptNodeClients();
  readNodeData();
  readWiredFrames();

  update_nodes_table();
  lv_timer_handler();
  delay(5);
}
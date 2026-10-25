#include <assert.h>
#include <stdio.h>
#include <math.h>
#include "../pad_map.h"
#include "../steam_input.h"
int main(void) {
    int map[DM_PAD_BUTTONS]; pad_map_default(map, 0);
    assert(pad_map_buttons(1u << 0, map) == DM_BTN_A); // east -> Switch A
    pad_map_default(map, 1);
    assert(pad_map_buttons(1u << 1, map) == DM_BTN_A); // south -> label A
    map[16] = 63; assert(pad_map_buttons(1u << 16, map) == DM_BTN_SHAKE);
    map[1] = -1; assert(pad_map_buttons(1u << 1, map) == 0);
    map[1] = 100; assert(pad_map_buttons(1u << 1, map) == 0);
    unsigned char packet[64] = {0x42, 1}; steam_state s = {0};
    // South A, L4, right trackpad click. Signed axes and half-pulled triggers.
    packet[2] = 1; packet[4] = 0x42;
    packet[7] = 0x40; packet[9] = 0x40;
    packet[10] = 0xff; packet[11] = 0x7f;
    packet[12] = 0; packet[13] = 0x80;
    for (int i = 0; i < 3; i++) {
        packet[0] = (unsigned char[]){0x42, 0x45, 0x47}[i];
        assert(steam_decode(packet, 46, &s) == 1);
        assert(s.buttons == ((1u << 1) | (1u << 16) | (1u << 21) | DM_BTN_ZL | DM_BTN_ZR));
        assert(s.lx == 32767 && s.ly == -32767 && s.rx == 0 && s.ry == 0);
        for (int n = 0; n < 46; n++) assert(steam_decode(packet, n, &s) == 0);
    }
    packet[0] = 0x79; packet[1] = 1; assert(steam_decode(packet, 2, &s) == -1);
    packet[0] = 0x46; assert(steam_decode(packet, 2, &s) == -1);
    packet[1] = 2; assert(steam_decode(packet, 2, &s) == 2);
    packet[0] = 0x43; assert(steam_decode(packet, 64, &s) == 0);
    assert(steam_device(0x28de, 0x1302, -1)); assert(steam_device(0x28de, 0x1303, -1));
    assert(steam_device(0x28de, 0x1304, 2)); assert(steam_device(0x28de, 0x1305, 5));
    assert(!steam_device(0x28de, 0x1304, 1)); assert(!steam_device(0x28de, 0x1142, 2));
    assert(!steam_device(0x1234, 0x1302, 2));
    for (int version = 0; version < 3; version++) {
        unsigned char imu[46] = {0}; imu[0] = (unsigned char[]){0x42,0x45,0x47}[version];
        imu[5] = 0x02; imu[4] = 0x20; // both trackpads touched
        int pad = version == 2 ? 20 : 18;
        imu[pad+1] = 0x40; imu[pad+3] = 0xc0; imu[pad+5] = 0x40;
        imu[pad+7] = 0x80; imu[pad+9] = 0x7f;
        int tick = version == 2 ? 32 : 30; imu[tick] = 0xfe; imu[tick+1] = 0xff;
        imu[39] = 0x40; imu[41] = 0x40; // +1G Z, +1000 degrees/second X
        assert(steam_decode(imu, sizeof imu, &s) == 1);
        assert(s.pad[0].down && s.pad[1].down && s.pad[0].x == 16384 && s.pad[0].y == -16384);
        assert(s.pad[1].x == -32767 && fabsf(s.pad[0].pressure - 0.5f) < 1e-5f);
        assert(s.acc[2] == -1 && fabsf(s.gyro[0] - 1000.0f/360) < 1e-5f);
        assert(s.tick == 65534 && s.tick_us == (version == 2 ? 32 : 1));
    }
    unsigned char output[10], feature[64];
    steam_rumble_report(output, 0x1234, 0xabcd);
    assert(output[0] == 0x80 && output[4] == 0x34 && output[5] == 0x12 && output[7] == 0xcd && output[8] == 0xab);
    assert(output[1] == 0 && output[2] == 0 && output[3] == 0 && output[6] == 0 && output[9] == 0);
    steam_imu_report(feature, 1); assert(feature[0] == 1 && feature[1] == 0x87 && feature[3] == 48 && feature[4] == 0x18);
    steam_imu_report(feature, 0); assert(feature[4] == 0);
    puts("pad mapping and Steam Controller reports: OK");
}

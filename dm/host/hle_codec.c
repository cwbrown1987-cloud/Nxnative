// nn::codec::HardwareOpusDecoder: the real device decodes in hardware via the hwopus service (the game's audio and cutscene tracks are all Opus; this is not an online feature).
// Host: the constructor instead constructs the SDK's software OpusDecoder in the same memory (the sdk bundles libopus, native ARM).
// Basis: both are implementations of nn::codec::IOpusDecoder, with the 10 vtable slots identical one by one in order and signature (destructor×2, GetWorkBufferSize, IsInitialized,
// Initialize, Finalize, GetSampleRate, GetChannelCount, Reset, DecodeInterleaved); the game allocates 0x40 bytes and the software object is 0x30 bytes.
#include "hle.h"

HLE_FORCE("_ZN2nn5codec19HardwareOpusDecoderC1Ei", "hwopus 服务；换成 SDK 软件 OpusDecoder（同一 IOpusDecoder 虚接口）",
          void, h_codec_HwOpusCtor, void *self, int option) {
    (void)option;
    static void (*soft_ctor)(void *);
    if (!soft_ctor && !(soft_ctor = guest_sym("_ZN2nn5codec11OpusDecoderC1Ev"))) die("缺 OpusDecoder 构造");
    soft_ctor(self);
}

// C 风格接口（王国之泪 1.0.0 用这套，不用上面的类）：HardwareOpusDecoderType 的 7 个函数逐个转发到 SDK 同名软件版（OpusDecoderType）。
// 依据（sdk 15.3.1 反汇编）：软件版结构体只用到 +0x00..+0x20（工作区 / 大小 / 采样率 +0x18 / 声道 +0x1c / 复位标志 +0x20），
// 硬件版写到 +0x28（+0x00 是服务对象）⇒ 游戏按硬件版分配的内存放得下软件版。两边返回值同为 OpusResult（0 = 成功），解码签名逐参数相同。
// 工作区大小报软件版的值：游戏照它分配，再原样交给 Initialize。
// C-style API (TotK 1.0.0 uses this one, not the class above): the 7 HardwareOpusDecoderType functions are each forwarded to the SDK's software counterpart (OpusDecoderType).
// Basis (sdk 15.3.1 disassembly): the software struct only uses +0x00..+0x20 (work buffer / size / sample rate +0x18 / channels +0x1c / reset flag +0x20),
// while the hardware one writes up to +0x28 (+0x00 is the service object) ⇒ the memory the game allocates for the hardware type fits the software type. Both return OpusResult (0 = success), and the decode signatures match argument for argument.
// The work buffer size reported is the software one: the game allocates by it and passes the buffer unchanged to Initialize.
static void *opus_sym(const char *n) { void *p = guest_sym(n); if (!p) die("缺 SDK 软件 Opus 符号 %s", n); return p; }

HLE_FORCE("_ZN2nn5codec36GetHardwareOpusDecoderWorkBufferSizeEiii", "hwopus 服务；报 SDK 软件解码器的工作区大小",
          size_t, h_codec_HwOpusWorkSize, int sample_rate, int channels, int option) {
    (void)option;
    static size_t (*f)(int, int);
    if (!f) f = opus_sym("_ZN2nn5codec28GetOpusDecoderWorkBufferSizeEii");
    return f(sample_rate, channels);
}
HLE_FORCE("_ZN2nn5codec29InitializeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeEiiPvmi", "hwopus 服务；在同一块内存上初始化 SDK 软件解码器",
          int, h_codec_HwOpusInit, void *dec, int sample_rate, int channels, void *work, size_t work_size, int option) {
    (void)option;
    static int (*f)(void *, int, int, void *, size_t);
    if (!f) f = opus_sym("_ZN2nn5codec21InitializeOpusDecoderEPNS0_15OpusDecoderTypeEiiPvm");
    return f(dec, sample_rate, channels, work, work_size);
}
HLE_FORCE("_ZN2nn5codec27FinalizeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeE", "hwopus 服务；转 SDK 软件解码器",
          void, h_codec_HwOpusFini, void *dec) {
    static void (*f)(void *);
    if (!f) f = opus_sym("_ZN2nn5codec19FinalizeOpusDecoderEPNS0_15OpusDecoderTypeE");
    f(dec);
}
HLE_FORCE("_ZN2nn5codec24ResetHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeE", "hwopus 服务；转 SDK 软件解码器",
          void, h_codec_HwOpusReset, void *dec) {
    static void (*f)(void *);
    if (!f) f = opus_sym("_ZN2nn5codec16ResetOpusDecoderEPNS0_15OpusDecoderTypeE");
    f(dec);
}
HLE_FORCE("_ZN2nn5codec32GetHardwareOpusDecoderSampleRateEPKNS0_23HardwareOpusDecoderTypeE", "hwopus 服务；转 SDK 软件解码器",
          int, h_codec_HwOpusRate, const void *dec) {
    static int (*f)(const void *);
    if (!f) f = opus_sym("_ZN2nn5codec24GetOpusDecoderSampleRateEPKNS0_15OpusDecoderTypeE");
    return f(dec);
}
HLE_FORCE("_ZN2nn5codec34GetHardwareOpusDecoderChannelCountEPKNS0_23HardwareOpusDecoderTypeE", "hwopus 服务；转 SDK 软件解码器",
          int, h_codec_HwOpusChannels, const void *dec) {
    static int (*f)(const void *);
    if (!f) f = opus_sym("_ZN2nn5codec26GetOpusDecoderChannelCountEPKNS0_15OpusDecoderTypeE");
    return f(dec);
}
HLE_FORCE("_ZN2nn5codec33DecodeOpusInterleavedWithHardwareEPNS0_23HardwareOpusDecoderTypeEPmPiPsmPKvm", "hwopus 服务；转 SDK 软件解码器（libopus，ARM 原生）",
          int, h_codec_HwOpusDecode, void *dec, size_t *consumed, int *samples, int16_t *out, size_t out_size, const void *in, size_t in_size) {
    static int (*f)(void *, size_t *, int *, int16_t *, size_t, const void *, size_t);
    if (!f) f = opus_sym("_ZN2nn5codec21DecodeOpusInterleavedEPNS0_15OpusDecoderTypeEPmPiPsmPKvm");
    return f(dec, consumed, samples, out, out_size, in, in_size);
}

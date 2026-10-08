#ifndef MULTITOUCH_BRIDGE_H
#define MULTITOUCH_BRIDGE_H
#include <stdbool.h>

// 私有 MultitouchSupport.framework 现役 API 的 C 声明。
// 布局与函数指针原型按 everypinch / MiddleClick 公开头文件整理（2026-10-05
// 在 macOS 26.6 / 25G83 真机验证：5 符号齐全，MTTouch 96 字节，帧率 ~120Hz）。
//
// 本头文件只声明类型——不 extern 任何函数符号（SwiftPM 无法链接私有框架），
// 调用方运行时 dlopen 框架 + dlsym 取地址后按下列函数指针原型 bitcast 使用。

typedef struct { float x; float y; } MTPoint;
typedef struct { MTPoint position; MTPoint velocity; } MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int stage;                     // MTPathStage：触点生命周期（接近/在触/离开）
    int fingerID;
    int handID;
    MTVector normalizedVector;     // 归一化位置/速度 0..1（左右原点与系统手势坐标一致）
    float total;
    float pressure;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;       // 设备物理坐标
    int unknown14;
    int unknown15;
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef void (*MTFrameCallbackFunction)(MTDeviceRef device, MTTouch touches[],
                                        int numTouches, double timestamp, int frame);

// dlsym 取地址后使用的原型（符号名同名）：
//   CFMutableArrayRef MTDeviceCreateList(void)
typedef bool (*MTRegisterContactFrameCallbackFn)(MTDeviceRef device, MTFrameCallbackFunction callback);
typedef void (*MTDeviceStartFn)(MTDeviceRef device, int runMode);
typedef void (*MTDeviceStopFn)(MTDeviceRef device);
typedef void (*MTDeviceReleaseFn)(MTDeviceRef device);

#endif

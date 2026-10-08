#ifndef MTBRIDGE_H
#define MTBRIDGE_H
#include <stdbool.h>

// MultitouchSupport 现役 API 的 C 声明(按 everypinch / MiddleClick 公开头文件整理)
// 仅声明类型与函数指针原型, 不 extern 链接符号 —— 运行时用 dlsym 取地址

typedef struct { float x; float y; } MTPoint;
typedef struct { MTPoint position; MTPoint velocity; } MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int stage;
    int fingerID;
    int handID;
    MTVector normalizedVector;   // 归一化位置/速度 0..1
    float total;
    float pressure;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absoluteVector;     // 设备物理坐标
    int unknown14;
    int unknown15;
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef void (*MTFrameCallbackFunction)(MTDeviceRef device, MTTouch touches[],
                                        int numTouches, double timestamp, int frame);

typedef bool (*MTRegisterContactFrameCallbackFn)(MTDeviceRef device, MTFrameCallbackFunction callback);
typedef void (*MTDeviceStartFn)(MTDeviceRef device, int runMode);
typedef void (*MTDeviceStopFn)(MTDeviceRef device);
typedef void (*MTDeviceReleaseFn)(MTDeviceRef device);

#endif

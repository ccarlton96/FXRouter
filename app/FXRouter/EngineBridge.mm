// FXRouter app shell — ObjC++ bridge implementation.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

#import "EngineBridge.h"

#include <memory>

#include "AudioEngine.h"
#include "DeviceIO.h"

@implementation FXOutputDevice {
    uint32_t _deviceID;
    NSString *_name;
    NSString *_uid;
}

- (instancetype)initWithID:(uint32_t)deviceID name:(NSString *)name uid:(NSString *)uid {
    if ((self = [super init])) {
        _deviceID = deviceID;
        _name = [name copy];
        _uid = [uid copy];
    }
    return self;
}

- (uint32_t)deviceID { return _deviceID; }
- (NSString *)name { return _name; }
- (NSString *)uid { return _uid; }

@end

@implementation FXEngineBridge {
    std::unique_ptr<fxrouter::AudioEngine> _engine;
}

- (instancetype)init {
    if ((self = [super init])) {
        _engine = std::make_unique<fxrouter::AudioEngine>();
        // Bridge is created on the main thread; JUCE hosting init needs that.
        _engine->pluginChain().initialiseHosting();
    }
    return self;
}

- (void)dealloc {
    _engine->stop();
}

- (BOOL)startWithOutputDeviceID:(uint32_t)deviceID bufferFrames:(uint32_t)bufferFrames {
    return _engine->start(deviceID, bufferFrames) ? YES : NO;
}

- (void)stop {
    _engine->stop();
}

- (BOOL)running { return _engine->isRunning(); }
- (double)sampleRate { return _engine->sampleRate(); }
- (uint64_t)dropoutCount { return _engine->dropoutCount(); }
- (int32_t)driftPPM { return _engine->driftPPM(); }
- (uint32_t)bufferFillFrames { return _engine->bufferFillFrames(); }
- (uint32_t)bufferTargetFrames { return _engine->bufferTargetFrames(); }
- (uint32_t)currentOutputDeviceID { return _engine->outputDevice(); }

- (NSArray<NSDictionary<NSString *, id> *> *)chainSlots {
    NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
    for (const auto &slot : _engine->pluginChain().chain()) {
        [result addObject:@{
            @"name" : [NSString stringWithUTF8String:slot.name.c_str()],
            @"format" : [NSString stringWithUTF8String:slot.format.c_str()],
            @"bypassed" : @(slot.bypassed),
        }];
    }
    return result;
}

- (BOOL)addPluginWithIdentifier:(NSString *)identifier atIndex:(NSUInteger)index {
    return _engine->pluginChain().addPlugin(identifier.UTF8String, index) ? YES : NO;
}

- (BOOL)removePluginAtIndex:(NSUInteger)index {
    return _engine->pluginChain().removePlugin(index) ? YES : NO;
}

- (void)clearChain {
    _engine->pluginChain().clearChain();
}

- (float)inputLevel { return _engine->inputLevel(); }
- (float)outputLevel { return _engine->outputLevel(); }
- (uint64_t)resyncCount { return _engine->resyncCount(); }

- (BOOL)movePluginFromIndex:(NSUInteger)from toIndex:(NSUInteger)to {
    return _engine->pluginChain().movePlugin(from, to) ? YES : NO;
}

- (void)setPluginAtIndex:(NSUInteger)index bypassed:(BOOL)bypassed {
    _engine->pluginChain().setSlotBypassed(index, bypassed);
}

- (void)setMasterBypass:(BOOL)bypassed {
    _engine->pluginChain().setMasterBypass(bypassed);
}

- (BOOL)masterBypass { return _engine->pluginChain().masterBypass(); }

- (BOOL)openEditorAtIndex:(NSUInteger)index {
    return _engine->pluginChain().openEditor(index) ? YES : NO;
}

- (NSString *)pluginError {
    return [NSString stringWithUTF8String:_engine->pluginChain().lastError().c_str()];
}

- (BOOL)loadCatalogFromFile:(NSString *)xmlPath {
    return _engine->pluginChain().loadCatalogFromFile(xmlPath.UTF8String) ? YES : NO;
}

- (NSArray<NSDictionary<NSString *, id> *> *)catalogPlugins {
    NSMutableArray<NSDictionary<NSString *, id> *> *result = [NSMutableArray array];
    for (const auto &p : _engine->pluginChain().catalog()) {
        [result addObject:@{
            @"name" : [NSString stringWithUTF8String:p.name.c_str()],
            @"format" : [NSString stringWithUTF8String:p.format.c_str()],
            @"manufacturer" : [NSString stringWithUTF8String:p.manufacturer.c_str()],
            @"identifier" : [NSString stringWithUTF8String:p.identifier.c_str()],
            @"isInstrument" : @(p.isInstrument),
            @"numIns" : @(p.numInputChannels),
            @"numOuts" : @(p.numOutputChannels),
        }];
    }
    return result;
}

+ (int)runScanWorkerWithResult:(NSString *)resultPath
                       deadman:(NSString *)deadmanPath
                     blacklist:(NSString *)blacklistPath {
    return fxrouter::runPluginScanWorker(resultPath.UTF8String, deadmanPath.UTF8String,
                                         blacklistPath.UTF8String);
}

- (NSString *)lastError {
    return [NSString stringWithUTF8String:_engine->lastError().c_str()];
}

+ (NSArray<FXOutputDevice *> *)outputDevices {
    NSMutableArray<FXOutputDevice *> *result = [NSMutableArray array];
    for (const auto &d : fxrouter::listRealOutputDevices()) {
        [result addObject:[[FXOutputDevice alloc]
                              initWithID:d.id
                                    name:[NSString stringWithUTF8String:d.name.c_str()]
                                     uid:[NSString stringWithUTF8String:d.uid.c_str()]]];
    }
    return result;
}

- (BOOL)saveChainToFile:(NSString *)xmlPath {
    return _engine->pluginChain().saveChainToFile(xmlPath.UTF8String) ? YES : NO;
}

- (NSUInteger)restoreChainFromFile:(NSString *)xmlPath {
    return _engine->pluginChain().restoreChainFromFile(xmlPath.UTF8String);
}

+ (uint32_t)deviceIDForUID:(NSString *)uid {
    return fxrouter::findDeviceByUID(uid.UTF8String);
}

+ (BOOL)routeSystemOutputToDeviceID:(uint32_t)deviceID {
    return fxrouter::setSystemDefaultOutputDevice(deviceID) ? YES : NO;
}

+ (uint32_t)virtualDeviceID {
    return fxrouter::findDeviceByUID(fxrouter::kVirtualDeviceUID);
}

+ (double)nominalRateForDevice:(uint32_t)deviceID {
    return fxrouter::getNominalSampleRate(deviceID);
}

+ (uint32_t)suggestedOutputDeviceID {
    return fxrouter::suggestedRealOutputDevice();
}

+ (BOOL)virtualDeviceInstalled {
    return fxrouter::findDeviceByUID(fxrouter::kVirtualDeviceUID) != kAudioObjectUnknown;
}

+ (BOOL)systemOutputIsVirtualDevice {
    AudioDeviceID def = fxrouter::systemDefaultOutputDevice();
    return def != kAudioObjectUnknown &&
           fxrouter::deviceUID(def) == fxrouter::kVirtualDeviceUID;
}

@end

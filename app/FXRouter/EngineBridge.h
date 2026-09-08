// FXRouter app shell — ObjC facade over the C++ engine (pure ObjC header;
// the C++ lives in EngineBridge.mm). Swift sees this via the bridging header.
// Copyright (C) 2026 FXRouter contributors. GPLv3; see LICENSE at repo root.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One entry per selectable real output device.
@interface FXOutputDevice : NSObject
@property (nonatomic, readonly) uint32_t deviceID;
@property (nonatomic, readonly, copy) NSString *name;
/// Stable across reboots/replugs — persist this, not deviceID.
@property (nonatomic, readonly, copy) NSString *uid;
@end

@interface FXEngineBridge : NSObject

/// Starts the passthrough into the given real output device.
/// bufferFrames: requested device IO buffer size (E5 latency/stability knob).
/// Returns NO and sets `lastError` on failure. Never call from the audio
/// thread; this is a configuration call (marshalled off-thread per 04).
- (BOOL)startWithOutputDeviceID:(uint32_t)deviceID bufferFrames:(uint32_t)bufferFrames;
- (void)stop;

@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) uint64_t dropoutCount;
/// Live drift correction, parts per million (Phase 3 servo).
@property (nonatomic, readonly) int32_t driftPPM;
/// Transport buffer fill, frames (current and servo target).
@property (nonatomic, readonly) uint32_t bufferFillFrames;
@property (nonatomic, readonly) uint32_t bufferTargetFrames;
/// Signal presence (RMS 0..1) at input (system→us) and output (us→speakers).
@property (nonatomic, readonly) float inputLevel;
@property (nonatomic, readonly) float outputLevel;
/// Backlog hard-resyncs performed (each is one deliberate audible skip).
@property (nonatomic, readonly) uint64_t resyncCount;

/// --- Effect chain (Phase 6). All calls main thread only. -----------------
/// Array of {name, format, bypassed} in processing order.
- (NSArray<NSDictionary<NSString *, id> *> *)chainSlots;
- (BOOL)addPluginWithIdentifier:(NSString *)identifier atIndex:(NSUInteger)index;
- (BOOL)removePluginAtIndex:(NSUInteger)index;
- (void)clearChain;
- (BOOL)movePluginFromIndex:(NSUInteger)from toIndex:(NSUInteger)to;
- (void)setPluginAtIndex:(NSUInteger)index bypassed:(BOOL)bypassed;
- (void)setMasterBypass:(BOOL)bypassed;
@property (nonatomic, readonly) BOOL masterBypass;
- (BOOL)openEditorAtIndex:(NSUInteger)index;
@property (nonatomic, readonly, copy) NSString *pluginError;

/// --- Persistence (Phase 7). Main thread only. -----------------------------
- (BOOL)saveChainToFile:(NSString *)xmlPath;
- (NSUInteger)restoreChainFromFile:(NSString *)xmlPath;

/// Resolves a persisted device UID to a live AudioDeviceID (0 if absent).
+ (uint32_t)deviceIDForUID:(NSString *)uid;
/// Changes the system default output device (onboarding / quit restore, F1).
+ (BOOL)routeSystemOutputToDeviceID:(uint32_t)deviceID;
/// The FXRouter virtual device's current AudioDeviceID (0 if not installed).
+ (uint32_t)virtualDeviceID;
/// A device's current nominal sample rate (0 on failure).
+ (double)nominalRateForDevice:(uint32_t)deviceID;
@property (nonatomic, readonly, copy) NSString *lastError;
@property (nonatomic, readonly) uint32_t currentOutputDeviceID;

/// Phase 5 catalog. Load the persisted scan result; list entries for the UI.
- (BOOL)loadCatalogFromFile:(NSString *)xmlPath;
/// Array of {name, format, manufacturer, identifier, isInstrument}.
- (NSArray<NSDictionary<NSString *, id> *> *)catalogPlugins;

/// Runs the out-of-process scan (worker mode; call INSTEAD of starting the
/// UI, then exit with the returned code).
+ (int)runScanWorkerWithResult:(NSString *)resultPath
                       deadman:(NSString *)deadmanPath
                     blacklist:(NSString *)blacklistPath;

/// Real output devices, virtual device already excluded (forbidden-loop rule).
+ (NSArray<FXOutputDevice *> *)outputDevices;

/// System default output if it isn't our virtual device, else built-in/first.
+ (uint32_t)suggestedOutputDeviceID;

/// Is the FXRouter driver present? (failure mode F3)
+ (BOOL)virtualDeviceInstalled;

/// Is the system default output currently FXRouter?
+ (BOOL)systemOutputIsVirtualDevice;

@end

NS_ASSUME_NONNULL_END

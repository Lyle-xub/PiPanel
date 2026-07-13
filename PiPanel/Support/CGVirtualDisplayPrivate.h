#ifndef CGVirtualDisplayPrivate_h
#define CGVirtualDisplayPrivate_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Reverse-engineered / community-documented private CoreGraphics virtual display API,
// as used by shipping non-App-Store tools (BetterDisplay, DeskPad, etc). Not in any
// public SDK header — declared here so we can link against the symbols that already
// exist inside the CoreGraphics framework binary at runtime. Verified working against
// this machine's CoreGraphics build in Spikes/VirtualDisplaySpike.

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, assign) uint32_t maxPixelsWide;
@property (nonatomic, assign) uint32_t maxPixelsHigh;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) uint32_t serialNum;
@property (nonatomic, assign) uint32_t productID;
@property (nonatomic, assign) uint32_t vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSInteger)width height:(NSInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, strong) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic, assign) NSInteger hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

NS_ASSUME_NONNULL_END

#endif /* CGVirtualDisplayPrivate_h */

//
// Copyright (c) 2026 Stephen F. Booth <me@sbooth.org>
// Part of https://github.com/sbooth/SFBAudioEngine
// MIT license
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 只读随机读数据源：用于从非 file:// 来源读取字节（例如 WebDAV/SMB）。
/// 注意：实现允许阻塞等待网络，但不应在音频实时线程调用。
NS_SWIFT_NAME(RandomAccessDataSource)
@protocol SFBRandomAccessDataSource <NSObject>

/// 返回总长度（字节）。
- (int64_t)lengthReturningError:(NSError **)error;

/// 随机读：从 offset 开始读取 length 字节。
- (nullable NSData *)readDataAtOffset:(int64_t)offset length:(int32_t)length error:(NSError **)error;

@optional
/// 版本标记（例如 ETag），用于缓存/变更检测。
- (nullable NSString *)versionTag;

/// 稳定标识（例如 resource-id/file-id），用于移动/改名重连。
- (nullable NSString *)stableIdentityType;
- (nullable NSString *)stableIdentityValue;

@end

NS_ASSUME_NONNULL_END

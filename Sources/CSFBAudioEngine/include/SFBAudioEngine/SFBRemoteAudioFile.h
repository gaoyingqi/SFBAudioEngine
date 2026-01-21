//
// Copyright (c) 2026 Stephen F. Booth <me@sbooth.org>
// Part of https://github.com/sbooth/SFBAudioEngine
// MIT license
//

#import <Foundation/Foundation.h>

#import <SFBAudioEngine/SFBAudioMetadata.h>
#import <SFBAudioEngine/SFBAudioProperties.h>
#import <SFBAudioEngine/SFBRandomAccessDataSource.h>

NS_ASSUME_NONNULL_BEGIN

/// 从 RandomAccessDataSource 读取音频 properties / metadata。
/// 目标：支持远端 deep 分析（不依赖 file://）。
NS_SWIFT_NAME(RemoteAudioFile)
@interface SFBRemoteAudioFile : NSObject

@property (nonatomic, readonly) SFBAudioProperties *properties;
@property (nonatomic, readonly) SFBAudioMetadata *metadata;

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;

/// 读取 properties 与 metadata。
/// - parameter dataSource: 随机读数据源
/// - parameter fileExtension: 文件扩展名（不含 '.'，例如 "mp3"/"flac"/"m4a"），用于选择 TagLib 解析器
+ (nullable instancetype)audioFileWithRandomAccessDataSource:(id<SFBRandomAccessDataSource>)dataSource
                                           fileExtension:(NSString *)fileExtension
                                                    error:(NSError **)error
    NS_SWIFT_NAME(init(readingPropertiesAndMetadataFromRandomAccessDataSource:fileExtension:));

@end

NS_ASSUME_NONNULL_END

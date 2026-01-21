//
// Copyright (c) 2026 Stephen F. Booth <me@sbooth.org>
// Part of https://github.com/sbooth/SFBAudioEngine
// MIT license
//

#import <os/log.h>

#import <taglib/aifffile.h>
#import <taglib/dsdifffile.h>
#import <taglib/dsffile.h>
#import <taglib/flacfile.h>
#import <taglib/mp4file.h>
#import <taglib/mpegfile.h>
#import <taglib/oggflacfile.h>
#import <taglib/opusfile.h>
#import <taglib/speexfile.h>
#import <taglib/tiostream.h>
#import <taglib/vorbisfile.h>
#import <taglib/wavfile.h>

#import "SFBRemoteAudioFile.h"

#import "AddAudioPropertiesToDictionary.h"
#import "SFBAttachedPicture.h"
#import "SFBAudioFile+Internal.h"
#import "SFBAudioMetadata+TagLibAPETag.h"
#import "SFBAudioMetadata+TagLibID3v1Tag.h"
#import "SFBAudioMetadata+TagLibID3v2Tag.h"
#import "SFBAudioMetadata+TagLibMP4Tag.h"
#import "SFBAudioMetadata+TagLibTag.h"
#import "SFBAudioMetadata+TagLibXiphComment.h"

namespace {

// 将 ObjC 的随机读数据源桥接为 TagLib::IOStream（只读）
class SFBRandomAccessIOStream final : public TagLib::IOStream {
public:
	SFBRandomAccessIOStream(id<SFBRandomAccessDataSource> dataSource)
	: _dataSource(dataSource)
	{
		// name() 需要返回一个生命周期足够长的指针
		_name = "remote";
		NSError *error = nil;
		_len = [_dataSource lengthReturningError:&error];
		if(error != nil) {
			_len = -1;
		}
	}

	TagLib::FileName name() const override
	{
		return _name.c_str();
	}

	TagLib::ByteVector readBlock(size_t length) override
	{
		if(length == 0)
			return TagLib::ByteVector();

		if(_len >= 0 && _pos >= _len)
			return TagLib::ByteVector();

		NSError *error = nil;
		NSData *data = [_dataSource readDataAtOffset:_pos length:(int32_t)length error:&error];
		if(error != nil || data == nil) {
			// 读取失败：返回空，TagLib 会将其视为 EOF/错误
			return TagLib::ByteVector();
		}
		_pos += (TagLib::offset_t)data.length;
		return TagLib::ByteVector(static_cast<const char *>(data.bytes), data.length);
	}

	void writeBlock(const TagLib::ByteVector & /*data*/) override
	{
		// 只读：不支持
	}

	void insert(const TagLib::ByteVector & /*data*/, TagLib::offset_t /*start*/, size_t /*replace*/) override
	{
		// 只读：不支持
	}

	void removeBlock(TagLib::offset_t /*start*/, size_t /*length*/) override
	{
		// 只读：不支持
	}

	bool readOnly() const override
	{
		return true;
	}

	bool isOpen() const override
	{
		// 只要 dataSource 可用，就认为 open
		return _dataSource != nil;
	}

	void seek(TagLib::offset_t offset, Position p = Beginning) override
	{
		switch(p) {
			case Beginning:
				_pos = offset;
				break;
			case Current:
				_pos = _pos + offset;
				break;
			case End:
				if(_len >= 0)
					_pos = _len + offset;
				else
					_pos = offset;
				break;
		}
		if(_pos < 0)
			_pos = 0;
	}

	TagLib::offset_t tell() const override
	{
		return _pos;
	}

	TagLib::offset_t length() override
	{
		if(_len >= 0)
			return _len;
		NSError *error = nil;
		_len = [_dataSource lengthReturningError:&error];
		if(error != nil)
			_len = -1;
		return _len;
	}

	void truncate(TagLib::offset_t /*length*/) override
	{
		// 只读：不支持
	}

private:
	id<SFBRandomAccessDataSource> _dataSource;
	std::string _name;
	TagLib::offset_t _pos = 0;
	TagLib::offset_t _len = -1;
};

static NSString *SFBLowercaseExtension(NSString *ext)
{
	NSString *e = [ext stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	e = [e stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]];
	return e.lowercaseString;
}

static BOOL SFBPopulatePropertiesAndMetadata(TagLib::File &file, NSString *formatName, SFBAudioProperties **propertiesOut, SFBAudioMetadata **metadataOut)
{
	NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:formatName forKey:SFBAudioPropertiesKeyFormatName];
	if(file.audioProperties())
		sfb::addAudioPropertiesToDictionary(file.audioProperties(), propertiesDictionary);

	SFBAudioMetadata *metadata = [[SFBAudioMetadata alloc] init];

	// 通用 Tag（标题/艺术家/专辑等）
	if(file.tag())
		[metadata addMetadataFromTagLibTag:file.tag()];

	*propertiesOut = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
	*metadataOut = metadata;
	return YES;
}

} // namespace

@interface SFBRemoteAudioFile ()
@property (nonatomic) SFBAudioProperties *properties;
@property (nonatomic) SFBAudioMetadata *metadata;
- (instancetype)initPrivateWithProperties:(SFBAudioProperties *)properties metadata:(SFBAudioMetadata *)metadata;
@end

@implementation SFBRemoteAudioFile

+ (nullable instancetype)audioFileWithRandomAccessDataSource:(id<SFBRandomAccessDataSource>)dataSource
                                           fileExtension:(NSString *)fileExtension
                                                    error:(NSError **)error
{
	NSParameterAssert(dataSource != nil);
	NSParameterAssert(fileExtension != nil);

	NSString *ext = SFBLowercaseExtension(fileExtension);

	@try {
		SFBRandomAccessIOStream stream(dataSource);
		if(!stream.isOpen()) {
			if(error)
				*error = [NSError errorWithDomain:SFBAudioFileErrorDomain code:SFBAudioFileErrorCodeInputOutput userInfo:nil];
			return nil;
		}

		SFBAudioProperties *properties = nil;
		SFBAudioMetadata *metadata = nil;

		BOOL ok = NO;

		// 常见格式：按扩展名选择具体 TagLib File，以便拿到更完整的 tag/封面。
		if([ext isEqualToString:@"mp3"]) {
			TagLib::MPEG::File file(&stream);
			if(file.isValid()) {
				NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:@"MP3" forKey:SFBAudioPropertiesKeyFormatName];
				if(file.audioProperties())
					sfb::addAudioPropertiesToDictionary(file.audioProperties(), propertiesDictionary);

				SFBAudioMetadata *m = [[SFBAudioMetadata alloc] init];
				if(file.hasAPETag())
					[m addMetadataFromTagLibAPETag:file.APETag()];
				if(file.hasID3v1Tag())
					[m addMetadataFromTagLibID3v1Tag:file.ID3v1Tag()];
				if(file.hasID3v2Tag())
					[m addMetadataFromTagLibID3v2Tag:file.ID3v2Tag()];

				properties = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
				metadata = m;
				ok = YES;
			}
		}
		else if([ext isEqualToString:@"flac"]) {
			TagLib::FLAC::File file(&stream);
			if(file.isValid()) {
				NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:@"FLAC" forKey:SFBAudioPropertiesKeyFormatName];
				if(file.audioProperties()) {
					auto p = file.audioProperties();
					sfb::addAudioPropertiesToDictionary(p, propertiesDictionary);
					if(p->bitsPerSample())
						propertiesDictionary[SFBAudioPropertiesKeyBitDepth] = @(p->bitsPerSample());
					if(p->sampleFrames())
						propertiesDictionary[SFBAudioPropertiesKeyFrameLength] = @(p->sampleFrames());
				}

				SFBAudioMetadata *m = [[SFBAudioMetadata alloc] init];
				if(file.hasID3v1Tag())
					[m addMetadataFromTagLibID3v1Tag:file.ID3v1Tag()];
				if(file.hasID3v2Tag())
					[m addMetadataFromTagLibID3v2Tag:file.ID3v2Tag()];
				if(file.hasXiphComment())
					[m addMetadataFromTagLibXiphComment:file.xiphComment()];

				for(auto iter : file.pictureList()) {
					NSData *imageData = [NSData dataWithBytes:iter->data().data() length:iter->data().size()];
					NSString *description = nil;
					if(!iter->description().isEmpty())
						description = [NSString stringWithUTF8String:iter->description().toCString(true)];
					[m attachPicture:[[SFBAttachedPicture alloc] initWithImageData:imageData
													 type:static_cast<SFBAttachedPictureType>(iter->type())
												 description:description]];
				}

				properties = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
				metadata = m;
				ok = YES;
			}
		}
		else if([ext isEqualToString:@"m4a"] || [ext isEqualToString:@"m4r"] || [ext isEqualToString:@"mp4"]) {
			TagLib::MP4::File file(&stream);
			if(file.isValid()) {
				NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:@"MP4" forKey:SFBAudioPropertiesKeyFormatName];
				if(file.audioProperties()) {
					auto p = file.audioProperties();
					sfb::addAudioPropertiesToDictionary(p, propertiesDictionary);
					if(p->bitsPerSample())
						propertiesDictionary[SFBAudioPropertiesKeyBitDepth] = @(p->bitsPerSample());
					switch(p->codec()) {
						case TagLib::MP4::Properties::Codec::AAC:
							propertiesDictionary[SFBAudioPropertiesKeyFormatName] = @"AAC";
							break;
						case TagLib::MP4::Properties::Codec::ALAC:
							propertiesDictionary[SFBAudioPropertiesKeyFormatName] = @"Apple Lossless";
							break;
						default:
							break;
					}
				}

				SFBAudioMetadata *m = [[SFBAudioMetadata alloc] init];
				if(file.tag())
					[m addMetadataFromTagLibMP4Tag:file.tag()];

				properties = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
				metadata = m;
				ok = YES;
			}
		}
		else if([ext isEqualToString:@"opus"]) {
			TagLib::Ogg::Opus::File file(&stream);
			if(file.isValid() && file.tag()) {
				NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:@"Ogg Opus" forKey:SFBAudioPropertiesKeyFormatName];
				if(file.audioProperties())
					sfb::addAudioPropertiesToDictionary(file.audioProperties(), propertiesDictionary);
				SFBAudioMetadata *m = [[SFBAudioMetadata alloc] init];
				[m addMetadataFromTagLibXiphComment:file.tag()];
				properties = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
				metadata = m;
				ok = YES;
			}
		}
		else if([ext isEqualToString:@"ogg"] || [ext isEqualToString:@"oga"]) {
			// Ogg 容器：按顺序尝试常见 codec（Vorbis/Speex/FLAC）
			if(!ok) {
				stream.seek(0);
				TagLib::Ogg::Speex::File file(&stream);
				if(file.isValid() && file.tag()) {
					NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:@"Ogg Speex" forKey:SFBAudioPropertiesKeyFormatName];
					if(file.audioProperties())
						sfb::addAudioPropertiesToDictionary(file.audioProperties(), propertiesDictionary);
					SFBAudioMetadata *m = [[SFBAudioMetadata alloc] init];
					[m addMetadataFromTagLibXiphComment:file.tag()];
					properties = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
					metadata = m;
					ok = YES;
				}
			}
			if(!ok) {
				stream.seek(0);
				TagLib::Ogg::FLAC::File file(&stream);
				if(file.isValid() && file.tag()) {
					NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:@"Ogg FLAC" forKey:SFBAudioPropertiesKeyFormatName];
					if(file.audioProperties())
						sfb::addAudioPropertiesToDictionary(file.audioProperties(), propertiesDictionary);
					SFBAudioMetadata *m = [[SFBAudioMetadata alloc] init];
					[m addMetadataFromTagLibXiphComment:file.tag()];
					properties = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
					metadata = m;
					ok = YES;
				}
			}
			if(!ok) {
				stream.seek(0);
				TagLib::Ogg::Vorbis::File file(&stream);
				if(file.isValid() && file.tag()) {
					NSMutableDictionary *propertiesDictionary = [NSMutableDictionary dictionaryWithObject:@"Ogg Vorbis" forKey:SFBAudioPropertiesKeyFormatName];
					if(file.audioProperties())
						sfb::addAudioPropertiesToDictionary(file.audioProperties(), propertiesDictionary);
					SFBAudioMetadata *m = [[SFBAudioMetadata alloc] init];
					[m addMetadataFromTagLibXiphComment:file.tag()];
					properties = [[SFBAudioProperties alloc] initWithDictionaryRepresentation:propertiesDictionary];
					metadata = m;
					ok = YES;
				}
			}
		}
		else if([ext isEqualToString:@"wav"]) {
			TagLib::RIFF::WAV::File file(&stream);
			if(file.isValid()) {
				ok = SFBPopulatePropertiesAndMetadata(file, @"WAVE", &properties, &metadata);
			}
		}
		else if([ext isEqualToString:@"aif"] || [ext isEqualToString:@"aiff"]) {
			TagLib::RIFF::AIFF::File file(&stream);
			if(file.isValid()) {
				ok = SFBPopulatePropertiesAndMetadata(file, @"AIFF", &properties, &metadata);
			}
		}
		else if([ext isEqualToString:@"dsf"]) {
			TagLib::DSF::File file(&stream);
			if(file.isValid()) {
				ok = SFBPopulatePropertiesAndMetadata(file, @"DSF", &properties, &metadata);
			}
		}
		else if([ext isEqualToString:@"dff"] || [ext isEqualToString:@"dsdiff"]) {
			TagLib::DSDIFF::File file(&stream);
			if(file.isValid()) {
				ok = SFBPopulatePropertiesAndMetadata(file, @"DSDIFF", &properties, &metadata);
			}
		}

		if(!ok || properties == nil || metadata == nil) {
			if(error)
				*error = [NSError errorWithDomain:SFBAudioFileErrorDomain code:SFBAudioFileErrorCodeInvalidFormat userInfo:nil];
			return nil;
		}

		SFBRemoteAudioFile *result = [[SFBRemoteAudioFile alloc] initPrivateWithProperties:properties metadata:metadata];
		return result;
	}
	@catch(NSException *ex) {
		os_log_error(gSFBAudioFileLog, "Remote audio file parse exception: %{public}@", ex);
		if(error)
			*error = [NSError errorWithDomain:SFBAudioFileErrorDomain code:SFBAudioFileErrorCodeInternalError userInfo:nil];
		return nil;
	}
}

- (instancetype)initPrivateWithProperties:(SFBAudioProperties *)properties metadata:(SFBAudioMetadata *)metadata
{
	if((self = [super init])) {
		_properties = properties;
		_metadata = metadata;
	}
	return self;
}

@end

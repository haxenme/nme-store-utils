//
//  RMAppReceipt.m
//  RMStore
//
//  Created by Hermes on 10/12/13.
//  Copyright (c) 2013 Robot Media. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "RMAppReceipt.h"
#import <openssl/objects.h>
#import <openssl/sha.h>
#import <openssl/x509.h>

#if TARGET_OS_IPHONE
#    import <UIKit/UIKit.h>
#elif TARGET_OS_OSX
#    import <IOKit/IOKitLib.h>
#    import <Security/SecKeychainItem.h>
#    import <Security/Security.h>
#endif

#if DEBUG
#    define RMAppReceiptLog(...) NSLog(@"RMAppReceipt: %@", [NSString stringWithFormat:__VA_ARGS__]);
#else
#    define RMAppReceiptLog(...)
#endif

// From https://developer.apple.com/library/ios/releasenotes/General/ValidateAppStoreReceipt/Chapters/ReceiptFields.html#//apple_ref/doc/uid/TP40010573-CH106-SW1
NSInteger const RMAppReceiptASN1TypeBundleIdentifier = 2;
NSInteger const RMAppReceiptASN1TypeAppVersion = 3;
NSInteger const RMAppReceiptASN1TypeOpaqueValue = 4;
NSInteger const RMAppReceiptASN1TypeHash = 5;
NSInteger const RMAppReceiptASN1TypeInAppPurchaseReceipt = 17;
NSInteger const RMAppReceiptASN1TypeOriginalAppVersion = 19;
NSInteger const RMAppReceiptASN1TypeExpirationDate = 21;

NSInteger const RMAppReceiptASN1TypeQuantity = 1701;
NSInteger const RMAppReceiptASN1TypeProductIdentifier = 1702;
NSInteger const RMAppReceiptASN1TypeTransactionIdentifier = 1703;
NSInteger const RMAppReceiptASN1TypePurchaseDate = 1704;
NSInteger const RMAppReceiptASN1TypeOriginalTransactionIdentifier = 1705;
NSInteger const RMAppReceiptASN1TypeOriginalPurchaseDate = 1706;
NSInteger const RMAppReceiptASN1TypeSubscriptionExpirationDate = 1708;
NSInteger const RMAppReceiptASN1TypeWebOrderLineItemID = 1711;
NSInteger const RMAppReceiptASN1TypeCancellationDate = 1712;
NSInteger const RMAppReceiptASN1TypeSubscriptionIntroductoryPricePeriod = 1719;

#pragma mark - ANS1

static int RMASN1ReadInteger(const uint8_t **pp, long omax)
{
    int tag, asn1Class;
    long length;
    int value = 0;
    ASN1_get_object(pp, &length, &tag, &asn1Class, omax);
    if (tag == V_ASN1_INTEGER)
    {
        for (int i = 0; i < length; i++)
        {
            value = value * 0x100 + (*pp)[i];
        }
    }
    *pp += length;
    return value;
}

static NSData* RMASN1ReadOctectString(const uint8_t **pp, long omax)
{
    int tag, asn1Class;
    long length;
    NSData *data = nil;
    ASN1_get_object(pp, &length, &tag, &asn1Class, omax);
    if (tag == V_ASN1_OCTET_STRING)
    {
        data = [NSData dataWithBytes:*pp length:length];
    }
    *pp += length;
    return data;
}

static NSString* RMASN1ReadString(const uint8_t **pp, long omax, int expectedTag, NSStringEncoding encoding)
{
    int tag, asn1Class;
    long length;
    NSString *value = nil;
    ASN1_get_object(pp, &length, &tag, &asn1Class, omax);
    if (tag == expectedTag)
    {
        value = [[NSString alloc] initWithBytes:*pp length:length encoding:encoding];
    }
    *pp += length;
    return value;
}

static NSString* RMASN1ReadUTF8String(const uint8_t **pp, long omax)
{
    return RMASN1ReadString(pp, omax, V_ASN1_UTF8STRING, NSUTF8StringEncoding);
}

static NSString* RMASN1ReadIA5SString(const uint8_t **pp, long omax)
{
    return RMASN1ReadString(pp, omax, V_ASN1_IA5STRING, NSASCIIStringEncoding);
}

#if TARGET_OS_OSX || TARGET_OS_MACCATALYST

static CFDataRef CopyMACAddressData()
{
    kern_return_t             kernResult;
    mach_port_t               master_port;
    CFMutableDictionaryRef    matchingDict;
    io_iterator_t             iterator;
    io_object_t               service;
    CFDataRef                 macAddress = nil;
    
    kernResult = IOMasterPort(MACH_PORT_NULL, &master_port);
    if (kernResult != KERN_SUCCESS) {
        RMAppReceiptLog(@"IOMasterPort returned %d", kernResult);
        return nil;
    }
    
    matchingDict = IOBSDNameMatching(master_port, 0, "en0");
    if (!matchingDict) {
        RMAppReceiptLog(@"IOBSDNameMatching returned empty dictionary");
        return nil;
    }
    
    kernResult = IOServiceGetMatchingServices(master_port, matchingDict, &iterator);
    if (kernResult != KERN_SUCCESS) {
        RMAppReceiptLog(@"IOServiceGetMatchingServices returned %d", kernResult);
        return nil;
    }
    
    while((service = IOIteratorNext(iterator)) != 0) {
        io_object_t parentService;
        
        kernResult = IORegistryEntryGetParentEntry(service, kIOServicePlane,
                                                   &parentService);
        if (kernResult == KERN_SUCCESS) {
            if (macAddress) CFRelease(macAddress);
            
            macAddress = (CFDataRef) IORegistryEntryCreateCFProperty(parentService,
                                                                     CFSTR("IOMACAddress"), kCFAllocatorDefault, 0);
            IOObjectRelease(parentService);
        } else {
            RMAppReceiptLog(@"IORegistryEntryGetParentEntry returned %d", kernResult);
        }
        
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    
    return macAddress;
}

#endif

#if TARGET_OS_OSX

static inline NSData *AppleRootCAFromKeychain( void )
{
    CFMutableDictionaryRef search;
    CFArrayRef result;
    SecKeychainRef keychain;
    SecCertificateRef item;
    NSData *certificateData = nil;

    if (SecKeychainOpen("/System/Library/Keychains/SystemRootCertificates.keychain",&keychain) != errSecSuccess)
    {
        return NULL;
    }

    /* Certificate search */
    search = CFDictionaryCreateMutable( NULL, 0, NULL, NULL );
    CFArrayRef keychains = CFArrayCreate(NULL, (const void **)&keychain, 1, NULL);
    CFDictionarySetValue( search, kSecClass, kSecClassCertificate );
    CFDictionarySetValue( search, kSecMatchLimit, kSecMatchLimitAll );
    CFDictionarySetValue( search, kSecReturnRef, kCFBooleanTrue );
    CFDictionarySetValue( search, kSecMatchSearchList, keychains );
    if ( SecItemCopyMatching( search, (CFTypeRef *)&result ) == errSecSuccess )
    {
        CFIndex n = CFArrayGetCount( result );
        for ( CFIndex i = 0; i < n; i++ )
        {
            item = (SecCertificateRef)CFArrayGetValueAtIndex( result, i );

            SecKeychainAttributeList list;
            SecKeychainAttribute attributes[1];

            attributes[0].tag = kSecLabelItemAttr;

            list.count = 1;
            list.attr = attributes;

            SecKeychainItemCopyContent((SecKeychainItemRef)item, nil, &list, nil, nil);
            NSData *nameData = [NSData dataWithBytesNoCopy:attributes[0].data length:attributes[0].length freeWhenDone:NO];
            NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
            SecKeychainItemFreeContent(&list, NULL);
            if([name isEqualToString:@"Apple Root CA"])
            {
                certificateData = CFBridgingRelease(SecCertificateCopyData(item));
                break;
            }
        }
    }

    if (!certificateData)
    {
        NSLog(@"%@", @"Apple Root CA fetching from Keychain failed.");
    }

    CFRelease(search);
    CFRelease(keychains);
    CFRelease(keychain);

    return certificateData;
}

#endif

static NSURL *_appleRootCertificateURL = nil;
static NSData *_appleRootCertificateData = nil;

@implementation RMAppReceipt

- (instancetype)initWithASN1Data:(NSData*)asn1Data
{
    if (self = [super init])
    {
        NSMutableArray *purchases = [NSMutableArray array];
         // Explicit casting to avoid errors when compiling as Objective-C++
        [RMAppReceipt enumerateASN1Attributes:(const uint8_t*)asn1Data.bytes length:asn1Data.length usingBlock:^(NSData *data, int type) {
            const uint8_t *s = (const uint8_t*)data.bytes;
            const NSUInteger length = data.length;
            switch (type)
            {
                case RMAppReceiptASN1TypeBundleIdentifier:
                    self->_bundleIdentifierData = data;
                    self->_bundleIdentifier = RMASN1ReadUTF8String(&s, length);
                    break;
                case RMAppReceiptASN1TypeAppVersion:
                    self->_appVersion = RMASN1ReadUTF8String(&s, length);
                    break;
                case RMAppReceiptASN1TypeOpaqueValue:
                    self->_opaqueValue = data;
                    break;
                case RMAppReceiptASN1TypeHash:
                    self->_receiptHash = data;
                    break;
                case RMAppReceiptASN1TypeInAppPurchaseReceipt:
                {
                    RMAppReceiptIAP *purchase = [[RMAppReceiptIAP alloc] initWithASN1Data:data];
                    [purchases addObject:purchase];
                    break;
                }
                case RMAppReceiptASN1TypeOriginalAppVersion:
                    self->_originalAppVersion = RMASN1ReadUTF8String(&s, length);
                    break;
                case RMAppReceiptASN1TypeExpirationDate:
                {
                    NSString *string = RMASN1ReadIA5SString(&s, length);
                    self->_expirationDate = [RMAppReceipt formatRFC3339String:string];
                    break;
                }
            }
        }];
        _inAppPurchases = purchases;
    }
    return self;
}

- (BOOL)containsInAppPurchaseOfProductIdentifier:(NSString*)productIdentifier
{
    for (RMAppReceiptIAP *purchase in _inAppPurchases)
    {
        if ([purchase.productIdentifier isEqualToString:productIdentifier]) return YES;
    }
    return NO;
}

-(BOOL)containsActiveAutoRenewableSubscriptionOfProductIdentifier:(NSString *)productIdentifier forDate:(NSDate *)date
{
    for (RMAppReceiptIAP *iap in self.inAppPurchases)
    {
        if ([iap.productIdentifier isEqualToString:productIdentifier] && [iap isActiveAutoRenewableSubscriptionForDate:date]) return YES;
    }
    
    return NO;
}

- (BOOL)verifyReceiptHash
{
    NSMutableData *data = [NSMutableData data];
#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
    [data appendData:(__bridge NSData * _Nonnull)(CopyMACAddressData())];
#elif TARGET_OS_IPHONE
    NSUUID *uuid = [UIDevice currentDevice].identifierForVendor;
    unsigned char uuidBytes[16];
    [uuid getUUIDBytes:uuidBytes];
    [data appendBytes:uuidBytes length:sizeof(uuidBytes)];
#endif
    
    [data appendData:self.opaqueValue];
    [data appendData:self.bundleIdentifierData];
    
    NSMutableData *expectedHash = [NSMutableData dataWithLength:SHA_DIGEST_LENGTH];
    SHA1((const uint8_t*)data.bytes, data.length, (uint8_t*)expectedHash.mutableBytes); // Explicit casting to avoid errors when compiling as Objective-C++
    
    return [expectedHash isEqualToData:self.receiptHash];
}

+ (RMAppReceipt*)bundleReceipt
{
    NSURL *URL = [NSBundle mainBundle].appStoreReceiptURL;
    NSString *path = URL.path;
    const BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:nil];
    if (!exists) return nil;
    
    NSData *data = [RMAppReceipt dataFromPCKS7Path:path];
    if (!data) return nil;
    
    RMAppReceipt *receipt = [[RMAppReceipt alloc] initWithASN1Data:data];
    return receipt;
}

+ (void)setAppleRootCertificateURL:(NSURL*)url
{
    _appleRootCertificateURL = url;
}


+ (void)setAppleRootCertificateData:(NSData*)data
{
    _appleRootCertificateData = data;
}


#pragma mark - Utils

+ (NSData*)dataFromPCKS7Path:(NSString*)path
{
    const char *cpath = path.stringByStandardizingPath.fileSystemRepresentation;
    FILE *fp = fopen(cpath, "rb");
    if (!fp) return nil;
    
    PKCS7 *p7 = d2i_PKCS7_fp(fp, NULL);
    fclose(fp);
    
    if (!p7) return nil;
    
    /* Get the Apple Root CA certificate. If the certificate is in the bundle,
     * it will be used on macOS and iOS. If you'd rather always have a fresh
     * copy, then specify a URL with `setAppleRootCertificateURL`. Apple's
     * official address for this is:
     *   https://www.apple.com/appleca/AppleIncRootCertificate.cer
     * On macOS, you can specify this if you like, but macOS will keep the root
     * certificate in the keychain up to date, so if there's no certificate in
     * the bundle and no URL specified, the certificate in the keychain will be
     * used. Because there's no access to the keychain on iOS, this fallback is
     * not available.
     */
    
    NSData *certificateData = _appleRootCertificateData;
    if (certificateData==nil)
    {
       NSURL *certificateURL = _appleRootCertificateURL ? : [[NSBundle mainBundle] URLForResource:@"AppleIncRootCertificate" withExtension:@"cer"];
       certificateData = [NSData dataWithContentsOfURL:certificateURL];
    }

#if TARGET_OS_OSX
    if (!certificateData)
    {
        certificateData = AppleRootCAFromKeychain();
    }
#endif
    
    NSAssert(certificateData != nil, @"The Apple Root CA couldn not be found. Either add it to the bundle or specify url `setAppleRootCertificateURL`.");
    
    NSData *data = nil;
    if (certificateData && [self verifyPKCS7:p7 withCertificateData:certificateData])
    {
        struct pkcs7_st *contents = p7->d.sign->contents;
        if (PKCS7_type_is_data(contents))
        {
            ASN1_OCTET_STRING *octets = contents->d.data;
            data = [NSData dataWithBytes:octets->data length:octets->length];
        }
    }
    PKCS7_free(p7);
    return data;
}

+ (BOOL)verifyPKCS7:(PKCS7*)container withCertificateData:(NSData*)certificateData
{
    // Based on: https://developer.apple.com/library/ios/releasenotes/General/ValidateAppStoreReceipt/Chapters/ValidateLocally.html#//apple_ref/doc/uid/TP40010573-CH1-SW17
    static int verified = 1;
    int result = 0;
    X509_STORE *store = X509_STORE_new();
    if (store)
    {
        const uint8_t *certificateBytes = (uint8_t *)(certificateData.bytes);
        X509 *certificate = d2i_X509(NULL, &certificateBytes, (long)certificateData.length);
        if (certificate)
        {
            X509_STORE_add_cert(store, certificate);
            
            BIO *payload = BIO_new(BIO_s_mem());
            result = PKCS7_verify(container, NULL, store, NULL, payload, 0);
            BIO_free(payload);
            
            X509_free(certificate);
        }
    }
    X509_STORE_free(store);
    
    return result == verified;
}

/*
 Based on https://github.com/rmaddy/VerifyStoreReceiptiOS
 */
+ (void)enumerateASN1Attributes:(const uint8_t*)p length:(long)tlength usingBlock:(void (^)(NSData *data, int type))block
{
    int type, tag;
    long length;
    
    const uint8_t *end = p + tlength;
    
    ASN1_get_object(&p, &length, &type, &tag, end - p);
    if (type != V_ASN1_SET) return;
    
    while (p < end)
    {
        ASN1_get_object(&p, &length, &type, &tag, end - p);
        if (type != V_ASN1_SEQUENCE) break;
        
        const uint8_t *sequenceEnd = p + length;
        
        const int attributeType = RMASN1ReadInteger(&p, sequenceEnd - p);
        RMASN1ReadInteger(&p, sequenceEnd - p); // Consume attribute version
        
        NSData *data = RMASN1ReadOctectString(&p, sequenceEnd - p);
        if (data)
        {
            block(data, attributeType);
        }
        
        while (p < sequenceEnd)
        { // Skip remaining fields
            ASN1_get_object(&p, &length, &type, &tag, sequenceEnd - p);
            p += length;
        }
    }
}

+ (NSDate*)formatRFC3339String:(NSString*)string
{
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZ";
    });
    NSDate *date = [formatter dateFromString:string];
    return date;
}

@end

@implementation RMAppReceiptIAP

- (instancetype)initWithASN1Data:(NSData*)asn1Data
{
    if (self = [super init])
    {
        // Explicit casting to avoid errors when compiling as Objective-C++
        [RMAppReceipt enumerateASN1Attributes:(const uint8_t*)asn1Data.bytes length:asn1Data.length usingBlock:^(NSData *data, int type) {
            const uint8_t *p = (const uint8_t*)data.bytes;
            const NSUInteger length = data.length;
            switch (type)
            {
                case RMAppReceiptASN1TypeQuantity:
                    self->_quantity = RMASN1ReadInteger(&p, length);
                    break;
                case RMAppReceiptASN1TypeProductIdentifier:
                    self->_productIdentifier = RMASN1ReadUTF8String(&p, length);
                    break;
                case RMAppReceiptASN1TypeTransactionIdentifier:
                    self->_transactionIdentifier = RMASN1ReadUTF8String(&p, length);
                    break;
                case RMAppReceiptASN1TypePurchaseDate:
                {
                    NSString *string = RMASN1ReadIA5SString(&p, length);
                    self->_purchaseDate = [RMAppReceipt formatRFC3339String:string];
                    break;
                }
                case RMAppReceiptASN1TypeOriginalTransactionIdentifier:
                    self->_originalTransactionIdentifier = RMASN1ReadUTF8String(&p, length);
                    break;
                case RMAppReceiptASN1TypeOriginalPurchaseDate:
                {
                    NSString *string = RMASN1ReadIA5SString(&p, length);
                    self->_originalPurchaseDate = [RMAppReceipt formatRFC3339String:string];
                    break;
                }
                case RMAppReceiptASN1TypeSubscriptionExpirationDate:
                {
                    NSString *string = RMASN1ReadIA5SString(&p, length);
                    self->_subscriptionExpirationDate = [RMAppReceipt formatRFC3339String:string];
                    break;
                }
                case RMAppReceiptASN1TypeWebOrderLineItemID:
                    self->_webOrderLineItemID = RMASN1ReadInteger(&p, length);
                    break;
                case RMAppReceiptASN1TypeCancellationDate:
                {
                    NSString *string = RMASN1ReadIA5SString(&p, length);
                    self->_cancellationDate = [RMAppReceipt formatRFC3339String:string];
                    break;
                }
                case RMAppReceiptASN1TypeSubscriptionIntroductoryPricePeriod: {
                    NSString *string = RMASN1ReadUTF8String(&p, length);
                    self->_subscriptionIntroductoryPricePeriod = [string isEqualToString:@"true"];
                    break;
                }

            }
        }];
    }
    return self;
}

- (BOOL)isActiveAutoRenewableSubscriptionForDate:(NSDate*)date
{
    NSAssert(self.subscriptionExpirationDate != nil, @"The product %@ is not an auto-renewable subscription.", self.productIdentifier);
    
    if (self.cancellationDate) return NO;
    
    return [self.purchaseDate compare:date] != NSOrderedDescending && [date compare:self.subscriptionExpirationDate] != NSOrderedDescending;
}

@end

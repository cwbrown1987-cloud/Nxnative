#import "DmSaveFolderSync.h"
#import <CommonCrypto/CommonDigest.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString * const DmSaveFolderSyncNotice = @"DmSaveFolderSyncNotice";
static NSString * const kBookmark = @"DmSaveFolderSync.bookmark";
static NSString * const kEnabled = @"DmSaveFolderSync.enabled";
static NSString * const kLocalFingerprint = @"DmSaveFolderSync.localFingerprint";
static NSString * const kExternalFingerprint = @"DmSaveFolderSync.externalFingerprint";
static NSString * const kLastSync = @"DmSaveFolderSync.lastSync";
static NSUInteger const kRecoverySnapshotLimit = 3;

@interface DmSaveFolderSync ()
@property(nonatomic,strong) NSURL *localSave;
@property(nonatomic,copy) NSString *titleID;
@property(nonatomic,strong) NSURL *selectedFolder;
@property(nonatomic,copy) NSString *selectedFolderName;
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic,strong) NSDate *lastSuccessfulSync;
@property(nonatomic) DmSaveFolderSyncState state;
@property(nonatomic,strong) NSOperationQueue *queue;
@property(nonatomic,weak) UIViewController *pickerPresenter;
@property(nonatomic) BOOL syncing;
@property(nonatomic) BOOL securityScopeActive;
@end

@implementation DmSaveFolderSync

static NSString *pathForURL(NSURL *url) { return url.path ?: url.absoluteString ?: @"(null)"; }

- (void)logFailure:(NSString *)operation phase:(NSString *)phase source:(NSURL *)source destination:(NSURL *)destination error:(NSError *)error preserved:(BOOL)preserved {
    NSString *file = error.userInfo[@"DmSaveFolderSyncFile"] ?: @"(root)";
    NSString *domain = error.domain ?: @"(none)";
    NSString *sourceURL = error.userInfo[@"DmSaveFolderSyncSourceURL"] ?: pathForURL(source);
    NSString *destinationURL = error.userInfo[@"DmSaveFolderSyncDestinationURL"] ?: pathForURL(destination);
    fprintf(stderr, "[save-sync] %s failed phase=%s file=%s source=%s destination=%s domain=%s code=%ld preserved=%s error=%s\n",
            operation.UTF8String, phase.UTF8String, file.UTF8String, sourceURL.UTF8String, destinationURL.UTF8String,
            domain.UTF8String, (long)error.code, preserved ? "yes" : "no", error.localizedDescription.UTF8String ?: "(none)");
}

- (NSString *)payloadListing:(NSURL *)url {
    NSMutableArray<NSString *> *items = [NSMutableArray array]; NSFileManager *fm = NSFileManager.defaultManager;
    BOOL root = NO; if (![fm fileExistsAtPath:url.path isDirectory:&root] || !root) return @"(missing-root)";
    NSDirectoryEnumerator *e = [fm enumeratorAtURL:url includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *u, NSError *err) { return YES; }];
    for (NSURL *item in e) {
        NSNumber *directory = nil; [item getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (directory.boolValue) continue;
        NSString *relative = [item.path substringFromIndex:url.path.length]; while ([relative hasPrefix:@"/"]) relative = [relative substringFromIndex:1];
        BOOL readable = [fm isReadableFileAtPath:item.path] && [[NSData alloc] initWithContentsOfURL:item options:NSDataReadingMappedIfSafe error:nil] != nil;
        [items addObject:[NSString stringWithFormat:@"%@[%@]", relative, readable ? @"readable" : @"unreadable"]];
    }
    return items.count ? [items componentsJoinedByString:@", "] : @"(empty)";
}

- (void)logVerification:(NSString *)operation source:(NSURL *)source destination:(NSURL *)destination expected:(NSString *)expected actual:(NSString *)actual {
    fprintf(stderr, "[save-sync] %s verification expected=%s actual=%s source-files=%s destination-files=%s\n", operation.UTF8String, expected.UTF8String ?: "(nil)", actual.UTF8String ?: "(nil)", [self payloadListing:source].UTF8String, [self payloadListing:destination].UTF8String);
}

- (BOOL)ensureSecurityScope:(NSError **)error {
    if (self.securityScopeActive) return YES;
    if (!self.selectedFolder || ![self.selectedFolder startAccessingSecurityScopedResource]) {
        if (error) *error = [NSError errorWithDomain:@"DmSaveFolderSync" code:20 userInfo:@{NSLocalizedDescriptionKey: @"Selected folder security scope is unavailable"}];
        return NO;
    }
    self.securityScopeActive = YES;
    return YES;
}

static BOOL validTitleID(NSString *titleID) {
    if (titleID.length != 16) return NO;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    return [[titleID stringByTrimmingCharactersInSet:hex] length] == 0;
}

- (instancetype)initWithLocalSave:(NSURL *)localSave titleID:(NSString *)titleID {
    if (!(self = [super init])) return nil;
    _localSave = localSave; _titleID = [titleID uppercaseString];
    _queue = [NSOperationQueue new]; _queue.maxConcurrentOperationCount = 1;
    _enabled = [NSUserDefaults.standardUserDefaults boolForKey:kEnabled];
    _lastSuccessfulSync = [NSUserDefaults.standardUserDefaults objectForKey:kLastSync];
    _state = DmSaveFolderSyncStateUnconfigured; _statusText = @"No folder selected";
    if (!validTitleID(_titleID)) { _state = DmSaveFolderSyncStateError; _statusText = @"Invalid game title ID"; return self; }
    [self resolveBookmark];
    return self;
}

- (void)notice:(NSString *)message state:(DmSaveFolderSyncState)state {
    self.statusText = message; self.state = state;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:DmSaveFolderSyncNotice object:message];
    });
}
- (void)setEnabled:(BOOL)enabled { _enabled = enabled; [NSUserDefaults.standardUserDefaults setBool:enabled forKey:kEnabled]; }

- (void)resolveBookmark {
    NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:kBookmark];
    if (!data) return;
    BOOL stale = NO; NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:data options:(NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting)
                                      relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
    if (!url || ![url startAccessingSecurityScopedResource]) {
        self.enabled = NO;
        [self notice:@"Selected folder is unavailable; choose it again" state:DmSaveFolderSyncStateUnavailable]; return;
    }
    if (stale) {
        NSData *fresh = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
        if (fresh) [NSUserDefaults.standardUserDefaults setObject:fresh forKey:kBookmark];
    }
    _selectedFolder = url; _selectedFolderName = url.lastPathComponent ?: url.path; _securityScopeActive = YES;
    _state = DmSaveFolderSyncStateReady; _statusText = @"Ready";
}

- (NSURL *)localPayloadURL { return self.localSave; }
- (NSURL *)externalPayloadURL {
    // The picker selects a shared root; only the current title ID is appended.
    return [self.selectedFolder URLByAppendingPathComponent:self.titleID isDirectory:YES];
}
- (NSURL *)gameFolder { return [self externalPayloadURL]; }
- (BOOL)isReservedPayloadComponent:(NSString *)name {
    return [name isEqualToString:@"SaveFolderSync-Recovery"] ||
           [name hasPrefix:@".stage-"] || [name hasPrefix:@".incoming-"] || [name hasPrefix:@".old-"];
}
- (BOOL)hasData:(NSURL *)url {
    for (NSURL *item in [NSFileManager.defaultManager contentsOfDirectoryAtURL:url includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil])
        if (![self isReservedPayloadComponent:item.lastPathComponent]) return YES;
    return NO;
}
- (NSString *)fingerprint:(NSURL *)url { return [self fingerprint:url error:nil]; }
- (BOOL)collectFingerprintEntriesAtURL:(NSURL *)url relativePath:(NSString *)relativePath entries:(NSMutableArray<NSDictionary *> *)entries error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager; NSError *contentsError = nil;
    NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:url includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsUbiquitousItemKey, NSURLUbiquitousItemIsDownloadedKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:&contentsError];
    if (!items) { if (error) *error = contentsError; return NO; }
    for (NSURL *item in items) {
        NSError *resourceError = nil; NSNumber *isDirectory = nil;
        if (![item getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:&resourceError]) { if (error) *error = resourceError; return NO; }
        if ([self isReservedPayloadComponent:item.lastPathComponent]) continue;
        NSString *relative = relativePath.length ? [relativePath stringByAppendingPathComponent:item.lastPathComponent] : item.lastPathComponent;
        if (isDirectory.boolValue) {
            if (![self collectFingerprintEntriesAtURL:item relativePath:relative entries:entries error:error]) return NO;
            continue;
        }
        NSNumber *ubiquitous = nil, *downloaded = nil;
        [item getResourceValue:&ubiquitous forKey:NSURLIsUbiquitousItemKey error:&resourceError];
        [item getResourceValue:&downloaded forKey:NSURLUbiquitousItemIsDownloadedKey error:&resourceError];
        if (ubiquitous.boolValue && !downloaded.boolValue) {
            if (error) *error = [NSError errorWithDomain:@"DmSaveFolderSync" code:11 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Save file is present but not downloaded: %@", relative], @"DmSaveFolderSyncFile": relative}];
            return NO;
        }
        NSData *contents = [[NSData alloc] initWithContentsOfURL:item options:NSDataReadingMappedIfSafe error:&resourceError];
        if (!contents) {
            if (error) *error = [NSError errorWithDomain:@"DmSaveFolderSync" code:17 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Save file is missing or unreadable: %@%@", relative, resourceError.localizedDescription.length ? [NSString stringWithFormat:@" (%@)", resourceError.localizedDescription] : @""], @"DmSaveFolderSyncFile": relative}];
            return NO;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(contents.bytes, (CC_LONG)contents.length, digest);
        [entries addObject:@{@"path": relative, @"digest": [NSData dataWithBytes:digest length:sizeof digest]}];
    }
    return YES;
}
- (NSString *)fingerprint:(NSURL *)url error:(NSError **)error {
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&directory]) return @"empty";
    if (!directory) {
        if (error) *error = [NSError errorWithDomain:@"DmSaveFolderSync" code:16 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Save path is not a directory: %@", url.lastPathComponent ?: url.path]}];
        return nil;
    }
    if (![self hasData:url]) return @"empty";
    NSMutableData *manifest = [NSMutableData data]; NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    if (![self collectFingerprintEntriesAtURL:url relativePath:@"" entries:entries error:error]) return nil;
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"path"] compare:b[@"path"]]; }];
    for (NSDictionary *entry in entries) { [manifest appendData:[entry[@"path"] dataUsingEncoding:NSUTF8StringEncoding]]; [manifest appendData:entry[@"digest"]]; }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(manifest.bytes, (CC_LONG)manifest.length, digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2]; for (NSUInteger i = 0; i < sizeof digest; i++) [out appendFormat:@"%02x", digest[i]]; return out;
}
- (NSUInteger)payloadFileCount:(NSURL *)url {
    NSUInteger count = 0; NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:url includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:^BOOL(NSURL *u, NSError *err) { return YES; }];
    for (NSURL *item in e) {
        NSNumber *directory = nil; [item getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if ([self isReservedPayloadComponent:item.lastPathComponent]) { if (directory.boolValue) [e skipDescendants]; continue; }
        if (!directory.boolValue) count++;
    }
    return count;
}
- (BOOL)copyDirectoryContents:(NSURL *)source to:(NSURL *)destination error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *contentsError = nil;
    NSArray<NSURL *> *items = [fm contentsOfDirectoryAtURL:source includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLIsUbiquitousItemKey, NSURLUbiquitousItemIsDownloadedKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:&contentsError];
    if (!items) { if (error) *error = contentsError; return NO; }
    for (NSURL *item in items) {
        NSError *resourceError = nil; NSNumber *reservedDir = nil;
        if (![item getResourceValue:&reservedDir forKey:NSURLIsDirectoryKey error:&resourceError]) { if (error) *error = resourceError; return NO; }
        if ([self isReservedPayloadComponent:item.lastPathComponent]) continue;
        NSURL *target = [destination URLByAppendingPathComponent:item.lastPathComponent isDirectory:reservedDir.boolValue];
        if (reservedDir.boolValue) {
            if (![fm createDirectoryAtURL:target withIntermediateDirectories:YES attributes:nil error:error]) return NO;
            if (![self copyDirectoryContents:item to:target error:error]) return NO;
        } else {
            NSString *rel = item.lastPathComponent ?: @"(unknown)";
            NSNumber *ubiquitous = nil, *downloaded = nil;
            [item getResourceValue:&ubiquitous forKey:NSURLIsUbiquitousItemKey error:&resourceError];
            [item getResourceValue:&downloaded forKey:NSURLUbiquitousItemIsDownloadedKey error:&resourceError];
            if (ubiquitous.boolValue && !downloaded.boolValue) {
                if (error) *error = [NSError errorWithDomain:@"DmSaveFolderSync" code:11 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Save file is present but not downloaded: %@", rel], @"DmSaveFolderSyncFile": rel}];
                return NO;
            }
            BOOL sourceExists = [fm fileExistsAtPath:item.path];
            if (!sourceExists) {
                if (error) *error = [NSError errorWithDomain:@"DmSaveFolderSync" code:18 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Source save file disappeared before copy: %@", rel], @"DmSaveFolderSyncFile": rel, @"DmSaveFolderSyncSourceURL": item.path, @"DmSaveFolderSyncDestinationURL": target.path}];
                return NO;
            }
            if (![fm copyItemAtURL:item toURL:target error:&resourceError]) {
                if (error) *error = [NSError errorWithDomain:@"DmSaveFolderSync" code:12 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not copy save file %@: %@", rel, resourceError.localizedDescription ?: @"unknown file error"], @"DmSaveFolderSyncFile": rel, @"DmSaveFolderSyncSourceURL": item.path, @"DmSaveFolderSyncDestinationURL": target.path, NSUnderlyingErrorKey: resourceError ?: [NSNull null]}];
                return NO;
            }
        }
    }
    return YES;
}
- (BOOL)copyTree:(NSURL *)source to:(NSURL *)destination error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager; BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:source.path isDirectory:&isDirectory] || !isDirectory) {
        if (error) *error = [NSError errorWithDomain:@"DmSaveFolderSync" code:10 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Source save directory does not exist: %@", source.lastPathComponent ?: source.path], @"DmSaveFolderSyncFile": source.lastPathComponent ?: @"(root)"}];
        return NO;
    }
    if (![fm createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    return [self copyDirectoryContents:source to:destination error:error];
}
- (NSURL *)recoveryRoot {
    return [[[self localPayloadURL] URLByDeletingLastPathComponent] URLByAppendingPathComponent:[NSString stringWithFormat:@"SaveFolderSync-Recovery/%@", self.titleID] isDirectory:YES];
}
- (BOOL)makeRecoverySnapshotForLocal:(NSURL *)local external:(NSURL *)external localFingerprint:(NSString *)localFP externalFingerprint:(NSString *)externalFP error:(NSError **)error {
    if ((!localFP || [localFP isEqualToString:@"empty"]) && (!externalFP || [externalFP isEqualToString:@"empty"])) return YES;
    if (localFP && externalFP && [localFP isEqualToString:externalFP]) return YES;
    NSURL *root = [self recoveryRoot]; NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *existing = [fm contentsOfDirectoryAtURL:root includingPropertiesForKeys:@[NSURLIsDirectoryKey, NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[];
    NSString *identifier = [NSString stringWithFormat:@"snapshot-%@-%@", localFP ?: @"empty", externalFP ?: @"empty"];
    NSURL *snapshot = [root URLByAppendingPathComponent:identifier isDirectory:YES];
    if ([fm fileExistsAtPath:snapshot.path]) return YES;
    if (![fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSURL *staging = [root URLByAppendingPathComponent:[NSString stringWithFormat:@".stage-%@", NSUUID.UUID.UUIDString] isDirectory:YES];
    NSURL *localCopy = [staging URLByAppendingPathComponent:@"local" isDirectory:YES];
    NSURL *externalCopy = [staging URLByAppendingPathComponent:@"external" isDirectory:YES];
    if ([self hasData:local] && ![self copyTree:local to:localCopy error:error]) { [fm removeItemAtURL:staging error:nil]; return NO; }
    if ([self hasData:external] && ![self copyTree:external to:externalCopy error:error]) { [fm removeItemAtURL:staging error:nil]; return NO; }
    if (![fm moveItemAtURL:staging toURL:snapshot error:error]) { [fm removeItemAtURL:staging error:nil]; return NO; }

    NSMutableArray<NSURL *> *snapshots = [NSMutableArray array];
    for (NSURL *url in existing) if ([url.lastPathComponent hasPrefix:@"snapshot-"]) [snapshots addObject:url];
    [snapshots addObject:snapshot];
    if (snapshots.count > kRecoverySnapshotLimit) {
        [snapshots sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            NSDate *ad = nil, *bd = nil; [a getResourceValue:&ad forKey:NSURLContentModificationDateKey error:nil]; [b getResourceValue:&bd forKey:NSURLContentModificationDateKey error:nil];
            return [(ad ?: NSDate.distantPast) compare:(bd ?: NSDate.distantPast)];
        }];
        while (snapshots.count > kRecoverySnapshotLimit) {
            NSURL *oldest = snapshots.firstObject;
            if (![fm removeItemAtURL:oldest error:error]) return NO;
            [snapshots removeObjectAtIndex:0];
        }
    }
    return YES;
}
- (BOOL)replaceTree:(NSURL *)source destination:(NSURL *)destination error:(NSError **)error backup:(NSURL **)backup {
    NSFileManager *fm = NSFileManager.defaultManager; NSURL *stage = [destination URLByAppendingPathExtension:[NSString stringWithFormat:@"stage-%@", NSUUID.UUID.UUIDString]];
    __block BOOL copied = NO; __block NSError *copyError = nil; NSNumber *ubiquitous = nil;
    [source getResourceValue:&ubiquitous forKey:NSURLIsUbiquitousItemKey error:&copyError];
    if (ubiquitous.boolValue) {
        NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
        [coordinator coordinateReadingItemAtURL:source options:0 error:&copyError byAccessor:^(NSURL *u) { copied = [self copyTree:u to:stage error:&copyError]; }];
    } else copied = [self copyTree:source to:stage error:&copyError];
    if (!copied) { if (error) *error = copyError ?: [NSError errorWithDomain:@"DmSaveFolderSync" code:13 userInfo:@{NSLocalizedDescriptionKey: @"Could not read the source save files", @"DmSaveFolderSyncFile": source.lastPathComponent ?: @"(root)"}]; [fm removeItemAtURL:stage error:nil]; return NO; }
    NSURL *old = [destination URLByAppendingPathExtension:[NSString stringWithFormat:@"old-%@", NSUUID.UUID.UUIDString]];
    if ([fm fileExistsAtPath:destination.path] && ![fm moveItemAtURL:destination toURL:old error:error]) { [fm removeItemAtURL:stage error:nil]; return NO; }
    if (![fm moveItemAtURL:stage toURL:destination error:error]) { if ([fm fileExistsAtPath:old.path]) [fm moveItemAtURL:old toURL:destination error:nil]; return NO; }
    if (backup) *backup = old; else [fm removeItemAtURL:old error:nil]; return YES;
}
- (void)syncOnQueue:(BOOL)manual {
    if (!self.enabled || !self.selectedFolder || self.syncing) return; self.syncing = YES;
    [self notice:@"Syncing" state:DmSaveFolderSyncStateReady];
    NSURL *localPayload = [self localPayloadURL]; NSURL *external = [self externalPayloadURL]; NSError *error = nil; BOOL ok = YES;
    if (![self ensureSecurityScope:&error]) { [self logFailure:@"sync" phase:@"security-scope" source:external destination:external error:error preserved:YES]; [self notice:@"Selected folder is unavailable; choose it again" state:DmSaveFolderSyncStateUnavailable]; self.syncing = NO; return; }
    NSString *localFP = [self fingerprint:localPayload error:&error], *externalFP = [self fingerprint:external error:&error];
    if (!localFP || !externalFP) { [self logFailure:@"sync" phase:@"fingerprint" source:localPayload destination:external error:error preserved:YES]; [self notice:error.localizedDescription ?: @"Save files are unavailable; local save preserved" state:DmSaveFolderSyncStateError]; self.syncing = NO; return; }
    BOOL local = localFP && ![localFP isEqualToString:@"empty"], ext = externalFP && ![externalFP isEqualToString:@"empty"];
    NSString *knownLocal = [NSUserDefaults.standardUserDefaults stringForKey:kLocalFingerprint], *knownExternal = [NSUserDefaults.standardUserDefaults stringForKey:kExternalFingerprint];
    BOOL haveBaseline = knownLocal.length && knownExternal.length;
    BOOL localChanged = haveBaseline && ![localFP isEqualToString:knownLocal];
    BOOL externalChanged = haveBaseline && ![externalFP isEqualToString:knownExternal];
    if (local && ext && ![localFP isEqualToString:externalFP] && (!haveBaseline || (localChanged && externalChanged) || (!localChanged && !externalChanged))) {
        [self makeRecoverySnapshotForLocal:localPayload external:external localFingerprint:localFP externalFingerprint:externalFP error:nil];
        [self notice:@"Different saves found on this device and in the selected folder. Choose which saves to use." state:DmSaveFolderSyncStateNeedsResolution]; self.syncing = NO; return;
    }
    BOOL shouldImport = ext && !local;
    if (local && ext && [localFP isEqualToString:externalFP]) shouldImport = NO;
    if (local && ext && externalChanged && !localChanged) shouldImport = YES;
    NSString *outcome = nil; NSUInteger transferred = 0;
    if (shouldImport) {
        transferred = [self payloadFileCount:external]; NSString *expected = externalFP;
        if (local && ![self makeRecoverySnapshotForLocal:localPayload external:external localFingerprint:localFP externalFingerprint:externalFP error:&error]) ok = NO;
        NSURL *localBackup = nil;
        if (ok) ok = [self replaceTree:external destination:localPayload error:&error backup:&localBackup];
        if (!ok) [self logFailure:@"import" phase:@"stage-and-replace" source:external destination:localPayload error:error preserved:YES];
        NSString *sourceAfter = [self fingerprint:external error:&error];
        if (ok && !sourceAfter) { [self logFailure:@"import" phase:@"source-verification" source:external destination:localPayload error:error preserved:YES]; ok = NO; }
        if (ok && ![sourceAfter isEqualToString:expected]) { error = [NSError errorWithDomain:@"DmSaveFolderSync" code:14 userInfo:@{NSLocalizedDescriptionKey: @"Source save changed or disappeared during import; local save preserved"}]; ok = NO; }
        NSString *localAfter = [self fingerprint:localPayload error:&error];
        if (ok && ![localAfter isEqualToString:expected]) { [self logVerification:@"import" source:external destination:localPayload expected:expected actual:localAfter]; error = [NSError errorWithDomain:@"DmSaveFolderSync" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Imported save verification failed; local save preserved"}]; ok = NO; }
        if (!ok && localBackup) { [NSFileManager.defaultManager removeItemAtURL:localPayload error:nil]; [NSFileManager.defaultManager moveItemAtURL:localBackup toURL:localPayload error:nil]; }
        else if (localBackup) [NSFileManager.defaultManager removeItemAtURL:localBackup error:nil];
        if (!ok && error) [self logFailure:@"import" phase:@"verification" source:external destination:localPayload error:error preserved:YES];
        if (ok) outcome = [NSString stringWithFormat:@"Save files imported successfully (%lu files).", (unsigned long)transferred];
    }
    else if (local && (!ext || localChanged)) {
        transferred = [self payloadFileCount:localPayload]; NSString *expected = localFP;
        if (ext && ![localFP isEqualToString:externalFP]) ok = [self makeRecoverySnapshotForLocal:localPayload external:external localFingerprint:localFP externalFingerprint:externalFP error:&error];
        NSURL *externalBackup = nil;
        if (ok) ok = [self replaceTree:localPayload destination:external error:&error backup:&externalBackup];
        if (!ok) [self logFailure:@"export" phase:@"stage-and-replace" source:localPayload destination:external error:error preserved:YES];
        NSString *sourceAfter = [self fingerprint:localPayload error:&error];
        if (ok && ![sourceAfter isEqualToString:expected]) { error = [NSError errorWithDomain:@"DmSaveFolderSync" code:15 userInfo:@{NSLocalizedDescriptionKey: @"Device save changed during export; folder save preserved"}]; ok = NO; }
        NSString *externalAfter = [self fingerprint:external error:&error];
        if (ok && ![externalAfter isEqualToString:expected]) { [self logVerification:@"export" source:localPayload destination:external expected:expected actual:externalAfter]; error = [NSError errorWithDomain:@"DmSaveFolderSync" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Exported save verification failed; folder save preserved"}]; ok = NO; }
        if (!ok && externalBackup) { [NSFileManager.defaultManager removeItemAtURL:external error:nil]; [NSFileManager.defaultManager moveItemAtURL:externalBackup toURL:external error:nil]; }
        else if (externalBackup) [NSFileManager.defaultManager removeItemAtURL:externalBackup error:nil];
        if (!ok && error) [self logFailure:@"export" phase:@"verification" source:localPayload destination:external error:error preserved:YES];
        if (ok) outcome = [NSString stringWithFormat:@"Save files exported (%lu files).", (unsigned long)transferred];
    }
    else if (localFP && externalFP && [localFP isEqualToString:externalFP]) outcome = @"Already Up to Date";
    else if (!local && !ext) outcome = @"Already Up to Date";
    if (ok) {
        NSString *l = [self fingerprint:localPayload], *x = [self fingerprint:external]; [NSUserDefaults.standardUserDefaults setObject:l forKey:kLocalFingerprint]; [NSUserDefaults.standardUserDefaults setObject:x forKey:kExternalFingerprint]; self.lastSuccessfulSync = NSDate.date; [NSUserDefaults.standardUserDefaults setObject:self.lastSuccessfulSync forKey:kLastSync]; [self notice:outcome ?: (manual ? @"Already Up to Date" : @"Already Up to Date") state:DmSaveFolderSyncStateReady];
    } else { [self logFailure:manual ? @"sync" : @"sync" phase:@"transfer" source:localPayload destination:external error:error preserved:YES]; [self notice:error.localizedDescription ?: @"Save folder is unavailable; local save preserved" state:DmSaveFolderSyncStateError]; }
    self.syncing = NO;
}
- (void)startBeforeGameplay {
    if (!self.enabled || !self.selectedFolder) return;
    BOOL hasLocalBaseline = [NSUserDefaults.standardUserDefaults stringForKey:kLocalFingerprint].length != 0;
    BOOL hasExternalBaseline = [NSUserDefaults.standardUserDefaults stringForKey:kExternalFingerprint].length != 0;
    if (!hasLocalBaseline || !hasExternalBaseline) [self syncOnQueue:NO];
    else [self resumeSafely];
}
- (void)resumeSafely { if (!self.enabled || !self.selectedFolder) return; [self.queue addOperationWithBlock:^{ [self syncOnQueue:NO]; }]; }
- (void)saveCommitted { if (!self.enabled || !self.selectedFolder) return; [self.queue addOperationWithBlock:^{ [self syncOnQueue:NO]; }]; }
- (void)syncNow {
    if (!self.enabled || !self.selectedFolder) return;
    [self notice:@"Syncing" state:DmSaveFolderSyncStateReady];
    [self.queue addOperationWithBlock:^{ [self syncOnQueue:YES]; }];
}

- (void)presentFolderPickerFromViewController:(UIViewController *)viewController {
    self.pickerPresenter = viewController; UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.folder"]] asCopy:NO];
    picker.delegate = self; picker.allowsMultipleSelection = NO; [viewController presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject; if (!url || ![url startAccessingSecurityScopedResource]) { [self notice:@"Could not access that folder" state:DmSaveFolderSyncStateUnavailable]; return; }
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    if (!bookmark) { [url stopAccessingSecurityScopedResource]; [self notice:@"Could not persist access to that folder" state:DmSaveFolderSyncStateError]; return; }
    if (self.selectedFolder && self.securityScopeActive) [self.selectedFolder stopAccessingSecurityScopedResource];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kLocalFingerprint];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kExternalFingerprint];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kLastSync];
    self.lastSuccessfulSync = nil;
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kBookmark]; _selectedFolder = url; _selectedFolderName = url.lastPathComponent ?: url.path; self.securityScopeActive = YES; self.state = DmSaveFolderSyncStateReady; self.statusText = @"Folder selected";
    self.enabled = YES;
    [self syncNow];
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { (void)controller; }
- (void)clearSelectedFolder {
    if (self.selectedFolder && self.securityScopeActive) [self.selectedFolder stopAccessingSecurityScopedResource];
    self.securityScopeActive = NO;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kBookmark];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kLocalFingerprint];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kExternalFingerprint];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kLastSync];
    self.selectedFolder = nil; self.selectedFolderName = nil; self.lastSuccessfulSync = nil;
    self.enabled = NO; self.state = DmSaveFolderSyncStateUnconfigured; self.statusText = @"No folder selected";
    [[NSNotificationCenter defaultCenter] postNotificationName:DmSaveFolderSyncNotice object:self.statusText];
}
- (void)resolveByImportingExternal {
    [self notice:@"Syncing" state:DmSaveFolderSyncStateReady];
    self.enabled = NO;
    [self.queue addOperationWithBlock:^{
        NSError *e = nil; NSURL *local = [self localPayloadURL], *external = [self externalPayloadURL];
        if (![self ensureSecurityScope:&e]) { [self logFailure:@"import" phase:@"security-scope" source:external destination:local error:e preserved:YES]; self.enabled = YES; [self notice:@"Selected folder is unavailable; choose it again" state:DmSaveFolderSyncStateUnavailable]; return; }
        NSString *lf = [self fingerprint:local], *xf = [self fingerprint:external]; NSUInteger count = [self payloadFileCount:external];
        if (!xf || [xf isEqualToString:@"empty"]) { e = e ?: [NSError errorWithDomain:@"DmSaveFolderSync" code:21 userInfo:@{NSLocalizedDescriptionKey: @"Folder contains no readable save files"}]; [self logFailure:@"import" phase:@"fingerprint" source:external destination:local error:e preserved:YES]; self.enabled = YES; [self notice:@"Folder contains no readable save files; local save preserved" state:DmSaveFolderSyncStateError]; return; }
        BOOL ok = [self makeRecoverySnapshotForLocal:local external:external localFingerprint:lf externalFingerprint:xf error:&e];
        NSURL *backup = nil;
        if (ok) ok = [self replaceTree:external destination:local error:&e backup:&backup];
        if (ok && ![[self fingerprint:external] isEqualToString:xf]) { e = [NSError errorWithDomain:@"DmSaveFolderSync" code:14 userInfo:@{NSLocalizedDescriptionKey: @"Folder save changed or disappeared during import; local save preserved"}]; ok = NO; }
        NSString *localAfter = ok ? [self fingerprint:local error:&e] : nil;
        if (ok && ![localAfter isEqualToString:xf]) { [self logVerification:@"import" source:external destination:local expected:xf actual:localAfter]; e = [NSError errorWithDomain:@"DmSaveFolderSync" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Folder save verification failed; local save preserved", @"DmSaveFolderSyncExpectedFingerprint": xf ?: @"(nil)", @"DmSaveFolderSyncActualFingerprint": localAfter ?: @"(nil)"}]; ok = NO; }
        if (!ok && backup) { [NSFileManager.defaultManager removeItemAtURL:local error:nil]; [NSFileManager.defaultManager moveItemAtURL:backup toURL:local error:nil]; }
        else if (backup) [NSFileManager.defaultManager removeItemAtURL:backup error:nil];
        if (!ok && e) [self logFailure:@"import" phase:@"verification" source:external destination:local error:e preserved:YES];
        self.enabled = YES;
        if (ok) {
            [NSUserDefaults.standardUserDefaults setObject:xf forKey:kLocalFingerprint]; [NSUserDefaults.standardUserDefaults setObject:xf forKey:kExternalFingerprint]; self.lastSuccessfulSync = NSDate.date; [NSUserDefaults.standardUserDefaults setObject:self.lastSuccessfulSync forKey:kLastSync];
            [self notice:[NSString stringWithFormat:@"Save files imported successfully (%lu files).", (unsigned long)count] state:DmSaveFolderSyncStateReady];
        } else [self notice:e.localizedDescription ?: @"Folder save import failed; local save preserved" state:DmSaveFolderSyncStateError];
    }];
}
- (void)resolveByExportingLocal {
    [self notice:@"Syncing" state:DmSaveFolderSyncStateReady];
    self.enabled = NO;
    [self.queue addOperationWithBlock:^{
        NSError *e = nil; NSURL *local = [self localPayloadURL], *external = [self externalPayloadURL];
        if (![self ensureSecurityScope:&e]) { [self logFailure:@"export" phase:@"security-scope" source:local destination:external error:e preserved:YES]; self.enabled = YES; [self notice:@"Selected folder is unavailable; choose it again" state:DmSaveFolderSyncStateUnavailable]; return; }
        NSString *lf = [self fingerprint:local], *xf = [self fingerprint:external]; NSUInteger count = [self payloadFileCount:local];
        BOOL ok = (!xf || [xf isEqualToString:@"empty"] || [lf isEqualToString:xf]) ? YES : [self makeRecoverySnapshotForLocal:local external:external localFingerprint:lf externalFingerprint:xf error:&e];
        NSURL *backup = nil;
        if (ok) ok = [self replaceTree:local destination:external error:&e backup:&backup];
        if (ok && ![[self fingerprint:local] isEqualToString:lf]) { e = [NSError errorWithDomain:@"DmSaveFolderSync" code:15 userInfo:@{NSLocalizedDescriptionKey: @"Device save changed during export; folder save preserved"}]; ok = NO; }
        if (ok && ![[self fingerprint:external] isEqualToString:lf]) { e = [NSError errorWithDomain:@"DmSaveFolderSync" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Device save verification failed; local save preserved"}]; ok = NO; }
        if (!ok && backup) { [NSFileManager.defaultManager removeItemAtURL:external error:nil]; [NSFileManager.defaultManager moveItemAtURL:backup toURL:external error:nil]; }
        else if (backup) [NSFileManager.defaultManager removeItemAtURL:backup error:nil];
        if (!ok && e) [self logFailure:@"export" phase:@"verification" source:local destination:external error:e preserved:YES];
        self.enabled = YES;
        if (ok) {
            [NSUserDefaults.standardUserDefaults setObject:lf forKey:kLocalFingerprint]; [NSUserDefaults.standardUserDefaults setObject:lf forKey:kExternalFingerprint]; self.lastSuccessfulSync = NSDate.date; [NSUserDefaults.standardUserDefaults setObject:self.lastSuccessfulSync forKey:kLastSync];
            [self notice:[NSString stringWithFormat:@"Save files exported (%lu files).", (unsigned long)count] state:DmSaveFolderSyncStateReady];
        } else [self notice:e.localizedDescription ?: @"Device save export failed; local save preserved" state:DmSaveFolderSyncStateError];
    }];
}
- (void)preserveBoth { [self notice:@"Both saves preserved; synchronization remains disabled" state:DmSaveFolderSyncStateNeedsResolution]; self.enabled = NO; }
@end

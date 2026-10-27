#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, DmSaveFolderSyncState) {
    DmSaveFolderSyncStateUnconfigured = 0,
    DmSaveFolderSyncStateReady,
    DmSaveFolderSyncStateNeedsResolution,
    DmSaveFolderSyncStateUnavailable,
    DmSaveFolderSyncStateError,
};

extern NSString * const DmSaveFolderSyncNotice;

/// Optional Files-provider synchronization for the game's ordinary local save.
/// This class copies complete snapshots to and from a user-selected folder;
/// the host's transactional save commit hook triggers post-save synchronization.
@interface DmSaveFolderSync : NSObject <UIDocumentPickerDelegate>
- (instancetype)initWithLocalSave:(NSURL *)localSave titleID:(NSString *)titleID;
@property(nonatomic,readonly) NSString *titleID;
@property(nonatomic,readonly) NSURL *selectedFolder;
@property(nonatomic,readonly) NSString *selectedFolderName;
@property(nonatomic,readonly) NSString *statusText;
@property(nonatomic,readonly) NSDate *lastSuccessfulSync;
@property(nonatomic,readonly) DmSaveFolderSyncState state;
@property(nonatomic) BOOL enabled;
- (void)presentFolderPickerFromViewController:(UIViewController *)viewController;
- (void)clearSelectedFolder;
- (void)startBeforeGameplay;
- (void)resumeSafely;
- (void)saveCommitted;
- (void)syncNow;
- (void)resolveByImportingExternal;
- (void)resolveByExportingLocal;
- (void)preserveBoth;
@end

#import "DmSaveFolderSync.h"

FOUNDATION_EXPORT DmSaveFolderSync *dm_save_folder_sync(void);
FOUNDATION_EXPORT void dm_save_folder_sync_present(DmSaveFolderSync *sync, UIViewController *viewController);
FOUNDATION_EXPORT void dm_save_folder_sync_clear(DmSaveFolderSync *sync);
FOUNDATION_EXPORT void dm_save_folder_sync_now(DmSaveFolderSync *sync);
FOUNDATION_EXPORT void dm_save_folder_sync_import(DmSaveFolderSync *sync);
FOUNDATION_EXPORT void dm_save_folder_sync_export(DmSaveFolderSync *sync);
FOUNDATION_EXPORT void dm_save_folder_sync_preserve(DmSaveFolderSync *sync);

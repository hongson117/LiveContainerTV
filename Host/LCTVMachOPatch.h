#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Patch MH_EXECUTE → MH_DYLIB, shrink __PAGEZERO, insert LC_ID_DYLIB if possible.
BOOL LCTVPatchExecToDylib(NSString *path, NSError **error);
/// Rewrite @executable_path → @loader_path/<relToAppRoot> in LC_RPATH/LC_LOAD_DYLIB;
/// optionally add LC_RPATH @loader_path/Frameworks (guest main exe).
BOOL LCTVFixGuestLoadPaths(NSString *path, NSString *relToAppRoot, BOOL addLoaderRpath, NSError **error);
NS_ASSUME_NONNULL_END

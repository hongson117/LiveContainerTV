#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Patch MH_EXECUTE → MH_DYLIB, shrink __PAGEZERO, insert LC_ID_DYLIB if possible.
BOOL LCTVPatchExecToDylib(NSString *path, NSError **error);
NS_ASSUME_NONNULL_END

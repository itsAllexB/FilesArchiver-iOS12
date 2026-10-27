// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

// FilesArchiver: the archive engine. Plain Foundation + libarchive, no UIKit, so every call
// can run on a background queue. All paths are plain file URLs; callers do the file coordination.

#import <Foundation/Foundation.h>

extern NSString *const FAErrorDomain;

typedef NS_ENUM(NSInteger, FAErrorCode) {
    FAErrorCancelled = 1,
    FAErrorNeedsPassword,        // encrypted zip entry and no password given
    FAErrorWrongPassword,        // password given but rejected
    FAErrorEncryptedUnsupported, // encrypted 7z / rar: libarchive cannot decrypt these
    FAErrorUnsupported,          // not an archive libarchive understands, or damaged
    FAErrorEmpty,                // nothing (safe) to extract
    FAErrorIO,                   // read/write failure, details in the description
    FAErrorNoSpace,              // stopped to keep FAFreeSpaceReserve bytes free; nothing was kept
};

// Jobs stop (and clean up) before the volume they write to has less than this free.
extern const unsigned long long FAFreeSpaceReserve;

typedef NS_ENUM(NSInteger, FACompressFormat) {
    FACompressFormatZip = 0,
    FACompressFormatTarGz,
    FACompressFormat7z,
};

// Shared state between the UI and a running job.
@interface FAJob : NSObject
@property (atomic) BOOL cancelled;
// Called on an arbitrary queue, at most ~10 times a second. fraction is 0...1, or -1 when unknown.
@property (copy) void (^progressHandler)(double fraction, NSString *currentItem);
// Filled in by extraction: entries that were not extracted, by reason.
@property (atomic) NSUInteger skippedUnsafe;     // could have been written outside: "../", links leading out
@property (atomic) NSUInteger skippedMetadata;   // Mac metadata (__MACOSX, ._*, .DS_Store) when skipped
@property (atomic) NSUInteger skippedLongName;   // a name over 255 bytes
@property (atomic) NSUInteger skippedDeep;       // the whole path is too long for the filesystem
@property (atomic) NSUInteger skippedClash;      // a file is where the archive needs a folder (or a link)
@property (atomic) NSUInteger skippedSpecial;    // devices, pipes, sockets
@property (atomic) NSUInteger failedEntries;     // damaged entries (bad CRC, truncated data); the rest is kept
@property (atomic) NSUInteger renamedClash;      // kept with " 2": the filesystem sees two names as one (NFC/NFD)
@property (atomic) BOOL damaged;                 // reading stopped early; what came before is kept
@end

@interface FAArchiver : NSObject

// File name extensions offered "Uncompress" (lowercase, multi-part ones like tar.gz included).
+ (NSArray<NSString *> *)archiveExtensions;
+ (BOOL)isArchiveURL:(NSURL *)url;

// Extracts `archive` into `directory` (nil: next to the archive). Names are chosen so they are free
// both there and next to the archive, because the UI moves the results next to the archive.
//  intoFolder: YES -> one item is placed as is, several items are wrapped in a folder named after the archive.
//              NO  -> every top-level item is placed next to the archive.
//  Single compressed files (.gz, .bz2, .xz, ...) always become one file named without the extension.
// Returns the URLs of the created top-level items.
+ (NSArray<NSURL *> *)extractArchive:(NSURL *)archive
                         toDirectory:(NSString *)directory
                          intoFolder:(BOOL)intoFolder
                        skipMetadata:(BOOL)skipMetadata
                          passphrase:(NSString *)passphrase
                                 job:(FAJob *)job
                               error:(NSError **)error;

// Compresses `items` (which must share a parent folder) into one archive in `directory`
// (nil: that parent folder).
// Name: "<item name>.<ext>" for one item, "Archive.<ext>" for several; " 2", " 3"... avoid clashes.
+ (NSURL *)compressItems:(NSArray<NSURL *> *)items
                  format:(FACompressFormat)format
             toDirectory:(NSString *)directory
                     job:(FAJob *)job
                   error:(NSError **)error;

+ (NSString *)extensionForFormat:(FACompressFormat)format;

// "Name.zip" -> "Name", "Name.tar.gz" -> "Name", "Name.part1.rar" -> "Name".
+ (NSString *)baseNameForArchiveName:(NSString *)name;
// First name free in all `dirs`: "Name", "Name 2", "Name 3"... (extension kept: "Name 2.zip").
// Names are shortened (whole characters) so they never exceed the 255-byte limit.
+ (NSString *)uniqueName:(NSString *)name inDirectories:(NSArray<NSString *> *)dirs;

@end

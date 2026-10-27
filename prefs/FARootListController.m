// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 itsAllexB

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface FARootListController : PSListController
@end

@implementation FARootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// Files is sandboxed and can only read the settings from the plist file, so write it out before
// telling Files that something changed (PSListController would post the notification first and
// leave the write to cfprefsd's schedule).
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *domain = [specifier propertyForKey:@"defaults"], *key = [specifier propertyForKey:@"key"];
    if (!domain.length || !key.length) {
        [super setPreferenceValue:value specifier:specifier];
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    NSString *note = [specifier propertyForKey:@"PostNotification"];
    if (note.length) CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)note, NULL, NULL, YES);
}

@end

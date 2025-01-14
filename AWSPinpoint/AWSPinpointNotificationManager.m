/*
 Copyright 2010-2017 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 
 Licensed under the Apache License, Version 2.0 (the "License").
 You may not use this file except in compliance with the License.
 A copy of the License is located at
 
 http://aws.amazon.com/apache2.0
 
 or in the "license" file accompanying this file. This file is distributed
 on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 express or implied. See the License for the specific language governing
 permissions and limitations under the License.
 */

#import <Cocoa/Cocoa.h>

#import "AWSPinpointNotificationManager.h"
#import "AWSPinpointTargetingClient.h"
#import "AWSPinpointAnalyticsClient.h"
#import "AWSPinpointService.h"
#import "AWSPinpointEvent.h"
#import "AWSPinpointContext.h"
#import "AWSPinpointConfiguration.h"

static NSString *const AWSCampaignDeepLinkKey = @"deeplink";
static NSString *const AWSAttributeApplicationStateKey = @"applicationState";
static NSString *const AWSAttributeActionIdentifierKey = @"actionIdentifier";
static NSString *const AWSEventTypeOpened = @"opened_notification";
static NSString *const AWSEventTypeReceivedForeground = @"received_foreground";
static NSString *const AWSEventTypeReceivedBackground = @"received_background";
NSString *const AWSDeviceTokenKey = @"com.amazonaws.AWSDeviceTokenKey";
NSString *const AWSDataKey = @"data";
NSString *const AWSPinpointKey = @"pinpoint";
NSString *const AWSPinpointCampaignKey = @"campaign";
NSString *const AWSPinpointJourneyKey = @"journey";

@interface AWSPinpointNotificationManager()
@property (nonatomic, strong) AWSPinpointContext *context;
@property (nonatomic) AWSPinpointPushEventSourceType previousEventSourceType;
@end

@interface AWSPinpointAnalyticsClient()
- (void) setEventSourceAttributes:(NSDictionary*) campaign;
- (void) removeAllGlobalEventSourceAttributes;
@end

@interface AWSPinpointConfiguration()
@property (nonatomic, strong) NSUserDefaults *userDefaults;
@end

@implementation AWSPinpointNotificationManager

- (instancetype)init {
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"You must not initialize this class directly. Access the AWSPinpointNotificationManager from AWSPinpoint."
                                 userInfo:nil];
}

- (instancetype) initWithContext:(AWSPinpointContext*) context {
    if (self = [super init]) {
        _context = context;
        _previousEventSourceType = AWSPinpointPushEventSourceTypeUnknown;
    }
    return self;
}

+ (BOOL)isNotificationEnabled {
    __block BOOL notificationsEnabled;
    [self runOnMainThread:^{
        notificationsEnabled = [[UIApplication sharedApplication] isRegisteredForRemoteNotifications];
    }];
    
    return notificationsEnabled;
}

+ (void) runOnMainThread:(void (^)(void))codeBlock {
    if ([NSThread isMainThread]) {
        codeBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), codeBlock);
    }
}

+ (BOOL)validPinpointPushForNotification:(NSDictionary*) notification {
    if (![notification[AWSDataKey] isKindOfClass:[NSDictionary class]] || ![notification[AWSDataKey][AWSPinpointKey] isKindOfClass:[NSDictionary class]]) {
        return NO;
    } else {
        return YES;
    }
}

#pragma mark - User action methods
- (BOOL)interceptDidFinishLaunchingWithOptions:(nullable NSDictionary *)launchOptions {
    NSDictionary *notificationPayload = launchOptions[UIApplicationLaunchOptionsRemoteNotificationKey];
    if(notificationPayload)
    {
        if (![AWSPinpointNotificationManager validPinpointPushForNotification:notificationPayload]) {
            return YES;
        }
        
        NSDictionary *metadata = [self getMetadataFromUserInfo:notificationPayload];
        AWSPinpointPushEventSourceType eventSourceType = [self getEventSourceTypeFromUserInfo:notificationPayload];
        [self addGlobalEventSourceMetadata:metadata withEventSourceType:eventSourceType];
        
        // Application launch because of notification
        [self recordMessageOpenedEventForNotification:notificationPayload
                                       withIdentifier:nil];
    }
    
    return YES;
}

- (void)interceptDidRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken {
    //Check if device token has changed
    NSData *currentToken = [self.context.keychain dataForKey:AWSDeviceTokenKey];
    if (![currentToken isEqualToData:deviceToken]) {
        [self.context.keychain setData:deviceToken forKey:AWSDeviceTokenKey];
        //Update endpoint
        AWSDDLogInfo(@"Calling endpoint Service to register token");
        
        [self.context.targetingClient updateEndpointProfile];
    }
}

- (void)interceptDidReceiveRemoteNotification:(NSDictionary *)userInfo {
    [self interceptDidReceiveRemoteNotification:userInfo shouldHandleNotificationDeepLink:YES];
}

- (void)interceptDidReceiveRemoteNotification:(NSDictionary *)userInfo
                                    pushEvent:(AWSPinpointPushEvent)pushEvent {
    [self interceptDidReceiveRemoteNotification:userInfo shouldHandleNotificationDeepLink:YES];
}

- (void)interceptDidReceiveRemoteNotification:(NSDictionary *)userInfo
                       fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))handler {
    [self interceptDidReceiveRemoteNotification:userInfo fetchCompletionHandler:handler shouldHandleNotificationDeepLink:YES];
}

- (void)interceptDidReceiveRemoteNotification:(NSDictionary *)userInfo
             shouldHandleNotificationDeepLink:(BOOL) handleDeepLink {
    [self interceptDidReceiveRemoteNotification:userInfo
                                      pushEvent:AWSPinpointPushEventReceived
               shouldHandleNotificationDeepLink:handleDeepLink];
}

- (void)interceptDidReceiveRemoteNotification:(NSDictionary *)userInfo
                                    pushEvent:(AWSPinpointPushEvent)pushEvent
             shouldHandleNotificationDeepLink:(BOOL) handleDeepLink {
    [self handleNotificationReceived:[UIApplication sharedApplication]
                    withNotification:userInfo
                           pushEvent:pushEvent
    shouldHandleNotificationDeepLink:handleDeepLink];
}

- (void)interceptDidReceiveRemoteNotification:(NSDictionary *)userInfo
                       fetchCompletionHandler:(void (^)(UIBackgroundFetchResult result))handler
             shouldHandleNotificationDeepLink:(BOOL) handleDeepLink {
    [self handleNotificationReceived:[UIApplication sharedApplication]
                    withNotification:userInfo
                           pushEvent:AWSPinpointPushEventReceived
    shouldHandleNotificationDeepLink:handleDeepLink];
    //We must rely on the user calling the completion handler because if we call it ourselves as well as the user it would cause a crash due to calling it twice.
}

#pragma mark - Handlers
- (void)handleNotificationDeepLinkForNotification:(NSDictionary*) userInfo {
    if (![AWSPinpointNotificationManager validPinpointPushForNotification:userInfo]) {
        return;
    }
    NSDictionary *amaDict = userInfo[AWSDataKey][AWSPinpointKey];
    if ([amaDict[AWSCampaignDeepLinkKey] isKindOfClass:[NSString class]]) {
        AWSDDLogVerbose(@"Received Deep Link: %@", amaDict[AWSCampaignDeepLinkKey]);
        NSURL *deepLinkURL = [NSURL URLWithString:amaDict[AWSCampaignDeepLinkKey]];
        if ([[UIApplication sharedApplication] canOpenURL:deepLinkURL]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [[UIApplication sharedApplication] openURL:deepLinkURL];
            });
        }
    }
}

- (void)handleNotificationReceived:(UIApplication *) app
                  withNotification:(NSDictionary *) userInfo
                         pushEvent:(AWSPinpointPushEvent)pushEvent
  shouldHandleNotificationDeepLink:(BOOL) shouldHandleNotificationDeepLink {
    UIApplicationState state = [app applicationState];
    NSDictionary *metadata = [self getMetadataFromUserInfo:userInfo];
    AWSPinpointPushEventSourceType eventSourceType = [self getEventSourceTypeFromUserInfo:userInfo];
    
    AWSPinpointPushActionType pushActionType = [self pushActionTypeOfApplicationState:state
                                                                            pushEvent:pushEvent];
    switch (pushActionType) {
        case AWSPinpointPushActionTypeOpened: {
            AWSDDLogVerbose(@"App launched from received notification.");
            [self addGlobalEventSourceMetadata:metadata withEventSourceType:eventSourceType];
            [self recordMessageOpenedEventForNotification:userInfo
                                           withIdentifier:nil];
            if (shouldHandleNotificationDeepLink) {
                [self handleNotificationDeepLinkForNotification:userInfo];
            }
            break;
        }
        case AWSPinpointPushActionTypeReceivedBackground: {
            AWSDDLogVerbose(@"Received notification with app on background.");
            [self addGlobalEventSourceMetadata:metadata withEventSourceType:eventSourceType];
            [self recordMessageReceivedEventForNotification:userInfo
                                         withPushActionType:pushActionType];
            break;
        }
        case AWSPinpointPushActionTypeReceivedForeground: {
            AWSDDLogVerbose(@"Received notification with app on foreground.");

            // Not adding global event source metadata because if the app session is already running,
            // the session should not contribute to the new push notification that is being received
            [self recordMessageReceivedEventForNotification:userInfo
                                         withPushActionType:pushActionType];
            break;
        }
        case AWSPinpointPushActionTypeUnknown: {
            AWSDDLogError(@"Received notification with app in unknown state.");
        }
    }
}

#pragma mark - Event recorders
- (void)recordMessageReceivedEventForNotification:(NSDictionary *) userInfo
                               withPushActionType:(AWSPinpointPushActionType) pushActionType {
    //Silent notification
    AWSPinpointEvent *pushNotificationEvent = [self buildEventFromUserInfo:userInfo
                                                        withPushActionType:pushActionType];
    if (!pushNotificationEvent) {
        AWSDDLogError(@"Not valid Pinpoint push notification");
        return;
    }

    [self addApplicationStateAttributeToEvent:pushNotificationEvent
                         withApplicationState:[[UIApplication sharedApplication] applicationState]];
    NSDictionary *metadata = [self getMetadataFromUserInfo:userInfo];
    [self addEventSourceMetadataForEvent:pushNotificationEvent
                            withMetadata:metadata];
    [self.context.analyticsClient recordEvent:pushNotificationEvent];
}

- (void)recordMessageOpenedEventForNotification:(NSDictionary *) userInfo
                                 withIdentifier:(NSString *) identifier {
    //User tapped on notification
    AWSPinpointEvent *pushNotificationEvent = [self buildEventFromUserInfo:userInfo
                                                        withPushActionType:AWSPinpointPushActionTypeOpened];
    if (!pushNotificationEvent) {
        AWSDDLogError(@"Not valid Pinpoint push notification");
        return;
    }
    if (identifier) {
        [pushNotificationEvent addAttribute:identifier forKey:AWSAttributeActionIdentifierKey];
    }
    [self addApplicationStateAttributeToEvent:pushNotificationEvent
                         withApplicationState:[[UIApplication sharedApplication] applicationState]];
    [self.context.analyticsClient recordEvent:pushNotificationEvent];
}

#pragma mark - Helpers
- (void)addEventSourceMetadataForEvent:(AWSPinpointEvent *) event
                          withMetadata:(NSDictionary *) metadata {
    for (NSString *key in [metadata allKeys]) {
        [event addAttribute:metadata[key] forKey:key];
    }
}

- (void)addGlobalEventSourceMetadata:(NSDictionary *) metadata
                 withEventSourceType:(AWSPinpointPushEventSourceType) eventSourceType {
    if (metadata.count) {
        // Remove previous global event source attributes from _globalAttributes
        // only if event source type changes
        // This is to prevent _globalAttributes containing attributes from multiple event sources (campaign/journey)
        if (eventSourceType != AWSPinpointPushEventSourceTypeUnknown && eventSourceType != self.previousEventSourceType ) {
            [self.context.analyticsClient removeAllGlobalEventSourceAttributes];
            self.previousEventSourceType = eventSourceType;
        }
        [self.context.analyticsClient setEventSourceAttributes:metadata];

        for (NSString *key in [metadata allKeys]) {
            [self.context.analyticsClient addGlobalAttribute:metadata[key] forKey:key];
        }
    }
}

- (void)addApplicationStateAttributeToEvent:(AWSPinpointEvent *) event
                       withApplicationState:(UIApplicationState) state {
    switch (state) {
        case UIApplicationStateActive:
        {
            [event addAttribute:@"UIApplicationStateActive" forKey:AWSAttributeApplicationStateKey];
        }
            break;
        case UIApplicationStateInactive:
        {
            [event addAttribute:@"UIApplicationStateInactive" forKey:AWSAttributeApplicationStateKey];
        }
            break;
        case UIApplicationStateBackground:
        {
            [event addAttribute:@"UIApplicationStateBackground" forKey:AWSAttributeApplicationStateKey];
        }
            break;
        default:
            break;
    }
}

- (AWSPinpointEvent*)buildEventFromUserInfo:(NSDictionary *) userInfo
                         withPushActionType:(AWSPinpointPushActionType) pushActionType {
    NSString *eventTypePrefix = [self getEventTypePrefixFromUserInfo:userInfo];
    NSString *eventTypeSuffix = [self getEventTypeSuffixFromPushActionType:pushActionType];
    if (!eventTypePrefix || !eventTypeSuffix) {
        return nil;
    }
    NSString *eventType = [NSString stringWithFormat: @"_%@.%@", eventTypePrefix, eventTypeSuffix];

    AWSPinpointEvent *pushNotificationEvent  = [self.context.analyticsClient createEventWithEventType:eventType];

    return pushNotificationEvent;
}

- (NSString*)getEventTypePrefixFromUserInfo:(NSDictionary *) userInfo {
    NSString *eventType;
    AWSPinpointPushEventSourceType pushEventSourceType = [self getEventSourceTypeFromUserInfo:userInfo];
    switch (pushEventSourceType) {
        case AWSPinpointPushEventSourceTypeCampaign:
            eventType = AWSPinpointCampaignKey;
            break;
        case AWSPinpointPushEventSourceTypeJourney:
            eventType = AWSPinpointJourneyKey;
            break;
        case AWSPinpointPushEventSourceTypeUnknown:
            AWSDDLogError(@"Cannot determine event type from Push payload");
            break;
    }
    return eventType;
}

- (NSString*)getEventTypeSuffixFromPushActionType:(AWSPinpointPushActionType) pushActionType {
    NSString *eventType;
    switch (pushActionType) {
        case AWSPinpointPushActionTypeOpened:
            eventType = AWSEventTypeOpened;
            break;
        case AWSPinpointPushActionTypeReceivedForeground:
            eventType = AWSEventTypeReceivedForeground;
            break;
        case AWSPinpointPushActionTypeReceivedBackground:
            eventType = AWSEventTypeReceivedBackground;
            break;
        case AWSPinpointPushActionTypeUnknown:
            break;
    }
    return eventType;
}

- (AWSPinpointPushActionType) pushActionTypeOfApplicationState:(UIApplicationState) state {
    return [self pushActionTypeOfApplicationState:state pushEvent:AWSPinpointPushEventReceived];
}

- (AWSPinpointPushActionType) pushActionTypeOfApplicationState:(UIApplicationState) state
                                                     pushEvent:(AWSPinpointPushEvent)pushEvent {
    AWSPinpointPushActionType pushActionType = AWSPinpointPushActionTypeUnknown;
    switch (state) {
        case UIApplicationStateActive:
            pushActionType = pushEvent == AWSPinpointPushEventReceived ?
                AWSPinpointPushActionTypeReceivedForeground :
                AWSPinpointPushActionTypeOpened;
            break;
        case UIApplicationStateBackground:
            pushActionType = AWSPinpointPushActionTypeReceivedBackground;
            break;
        case UIApplicationStateInactive:
            pushActionType = AWSPinpointPushActionTypeOpened;
            break;
        default:
            break;
    }
    return pushActionType;
}

- (AWSPinpointPushEventSourceType)getEventSourceTypeFromUserInfo:(NSDictionary*) userInfo {
    AWSPinpointPushEventSourceType eventType = AWSPinpointPushEventSourceTypeUnknown;
    if ([AWSPinpointNotificationManager validPinpointPushForNotification:userInfo]) {
        NSDictionary *pinpointData = userInfo[AWSDataKey][AWSPinpointKey];
        if (pinpointData[AWSPinpointCampaignKey]) {
            eventType = AWSPinpointPushEventSourceTypeCampaign;
        } else if (pinpointData[AWSPinpointJourneyKey]) {
            eventType = AWSPinpointPushEventSourceTypeJourney;
        }
    }
    return eventType;
}

- (NSDictionary*)getMetadataFromUserInfo:(NSDictionary*) userInfo {
    NSDictionary *metadata = nil;
    if ([AWSPinpointNotificationManager validPinpointPushForNotification:userInfo]) {
        NSDictionary *pinpointData = userInfo[AWSDataKey][AWSPinpointKey];
        if (pinpointData[AWSPinpointCampaignKey]) {
            metadata = pinpointData[AWSPinpointCampaignKey];
            AWSDDLogVerbose(@"Found campaign attributes: %@", metadata);
        } else if (pinpointData[AWSPinpointJourneyKey]) {
            metadata = pinpointData[AWSPinpointJourneyKey];
            AWSDDLogVerbose(@"Found journey attributes: %@", metadata);
        }
    }
    if (!metadata) {
        AWSDDLogError(@"No valid Pinpoint Push payload found");
    }
    return metadata;
}

@end

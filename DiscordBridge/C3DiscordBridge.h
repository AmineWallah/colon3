// Objective-C face of Discord's Social SDK (C++), for Swift. Only compiled into builds that
// include the SDK (see project-discord.yml and scripts/fetch-discord-sdk.sh).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface C3DiscordBridge : NSObject

/// The OAuth2 scopes Rich Presence needs (Client::GetDefaultPresenceScopes).
+ (NSString *)presenceScopes NS_SWIFT_NAME(presenceScopes());

- (instancetype)initWithApplicationID:(uint64_t)applicationID NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(applicationID:));
- (instancetype)init NS_UNAVAILABLE;

/// Client::Status (0 Disconnected, 1 Connecting, 2 Connected, 3 Ready, 4 Reconnecting,
/// 5 Disconnecting, 6 HttpWait), Client::Error and its detail code.
@property (nonatomic, copy, nullable) void (^onStatus)(NSInteger status, NSInteger error, NSInteger detail);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

/// Hands the SDK an OAuth2 access token, then connects. `completion` gets an error message,
/// or nil once the token was accepted.
- (void)connectWithAccessToken:(NSString *)token completion:(void (^)(NSString *_Nullable error))completion
    NS_SWIFT_NAME(connect(accessToken:completion:));
/// A refreshed token for a client that's already connected.
- (void)updateAccessToken:(NSString *)token NS_SWIFT_NAME(updateAccessToken(_:));
- (void)disconnect;
/// Runs the SDK's pending callbacks (on the calling thread). Call it a few times a second.
- (void)runCallbacks;

/// Sets the activity. Times are milliseconds since 1970 (0 to leave out). `listening` uses
/// the Listening activity type, otherwise Playing.
- (void)setPresenceWithTitle:(NSString *)title
                      artist:(NSString *)artist
                       album:(nullable NSString *)album
                    imageURL:(nullable NSString *)imageURL
           startMilliseconds:(int64_t)start
             endMilliseconds:(int64_t)end
                   listening:(BOOL)listening
                  completion:(void (^)(NSString *_Nullable error))completion
    NS_SWIFT_NAME(setPresence(title:artist:album:imageURL:startMilliseconds:endMilliseconds:listening:completion:));
- (void)clearPresence;

@end

NS_ASSUME_NONNULL_END

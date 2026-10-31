// Discord's Social SDK is C++; this wraps the few calls colon3 needs. Only built when the SDK
// is present (project-discord.yml).

#define DISCORDPP_IMPLEMENTATION
#include <discord_partner_sdk/discordpp.h>

#import "C3DiscordBridge.h"

#include <memory>
#include <optional>
#include <string>

static std::string C3String(NSString *text) {
    const char *utf8 = text.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
}

static NSString *C3NSString(const std::string &text) {
    return [NSString stringWithUTF8String:text.c_str()] ?: @"";
}

@implementation C3DiscordBridge {
    std::shared_ptr<discordpp::Client> _client;
    uint64_t _applicationID;
}

+ (NSString *)presenceScopes {
    return C3NSString(discordpp::Client::GetDefaultPresenceScopes());
}

- (instancetype)initWithApplicationID:(uint64_t)applicationID {
    if ((self = [super init])) {
        _applicationID = applicationID;
        _client = std::make_shared<discordpp::Client>();
        _client->SetApplicationId(applicationID);
        // colon3's player owns the AVAudioSession; the SDK (which can do voice chat) must not
        // activate or reconfigure it.
        _client->SetEngineManagedAudioSession(true);

        __weak C3DiscordBridge *weakSelf = self;
        _client->AddLogCallback([weakSelf](auto message, auto severity) {
            C3DiscordBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.onLog) {
                strongSelf.onLog(C3NSString(message));
            }
        }, discordpp::LoggingSeverity::Warning);
        _client->SetStatusChangedCallback([weakSelf](auto status, auto error, auto detail) {
            C3DiscordBridge *strongSelf = weakSelf;
            if (strongSelf && strongSelf.onStatus) {
                strongSelf.onStatus(static_cast<NSInteger>(status), static_cast<NSInteger>(error),
                                    static_cast<NSInteger>(detail));
            }
        });
    }
    return self;
}

- (void)dealloc {
    if (_client) {
        _client->Disconnect();
    }
}

- (void)connectWithAccessToken:(NSString *)token completion:(void (^)(NSString *_Nullable))completion {
    std::shared_ptr<discordpp::Client> client = _client;
    void (^done)(NSString *_Nullable) = [completion copy];
    client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, C3String(token),
                        [client, done](discordpp::ClientResult result) {
        if (result.Successful()) {
            client->Connect();
            done(nil);
        } else {
            done(C3NSString(result.Error()));
        }
    });
}

- (void)updateAccessToken:(NSString *)token {
    _client->UpdateToken(discordpp::AuthorizationTokenType::Bearer, C3String(token),
                         [](discordpp::ClientResult result) {});
}

- (void)disconnect {
    _client->Disconnect();
}

- (void)runCallbacks {
    discordpp::RunCallbacks();
}

- (void)setPresenceWithName:(nullable NSString *)name
                    details:(NSString *)details
                      state:(NSString *)state
                  largeText:(nullable NSString *)largeText
                   imageURL:(nullable NSString *)imageURL
          startMilliseconds:(int64_t)start
            endMilliseconds:(int64_t)end
                  listening:(BOOL)listening
                 completion:(void (^)(NSString *_Nullable))completion {
    discordpp::Activity activity;
    activity.SetType(listening ? discordpp::ActivityTypes::Listening : discordpp::ActivityTypes::Playing);
    if (name.length > 0) {
        activity.SetName(C3String(name));
    }
    activity.SetDetails(C3String(details));
    activity.SetState(C3String(state));
    // The short status next to your name shows the song, not "colon3".
    activity.SetStatusDisplayType(discordpp::StatusDisplayTypes::Details);

    discordpp::ActivityAssets assets;
    if (imageURL.length > 0) {
        assets.SetLargeImage(C3String(imageURL));
    }
    if (largeText.length > 0) {
        assets.SetLargeText(C3String(largeText));
    }
    activity.SetAssets(assets);

    if (start > 0) {
        discordpp::ActivityTimestamps timestamps;
        timestamps.SetStart(static_cast<uint64_t>(start));
        if (end > start) {
            timestamps.SetEnd(static_cast<uint64_t>(end));
        }
        activity.SetTimestamps(timestamps);
    }

    void (^done)(NSString *_Nullable) = [completion copy];
    _client->UpdateRichPresence(activity, [done](discordpp::ClientResult result) {
        done(result.Successful() ? nil : C3NSString(result.Error()));
    });
}

- (void)clearPresence {
    _client->ClearRichPresence();
}

@end

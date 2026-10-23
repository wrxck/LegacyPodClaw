/* routes allowed channel messages to one agent session per chat and sends each reply back to that chat */

#import <Foundation/Foundation.h>
#import "ChannelManager.h"
#import "Agent.h"

@interface OCChannelRouter : NSObject <OCChannelManagerDelegate, OCAgentDelegate>

@property (nonatomic, retain) OCChannelManager *manager;
@property (nonatomic, retain) OCModelConfig *modelConfig;
@property (nonatomic, copy) NSString *systemPrompt;
/* channel runs get this agent's tools, read at the start of each run; ignored while toolsEnabled is off */
@property (nonatomic, assign) OCAgent *toolSource;
/* off by default: chat text is untrusted, so it gets no tools unless the user turns them on */
@property (nonatomic, assign) BOOL toolsEnabled;
@property (nonatomic, assign) NSUInteger maxContextTokens;

/* senders or chats that may talk to the bot; an empty list ignores every message on that channel */
- (void)setAllowedSenders:(NSArray *)senders forChannel:(NSString *)channelId;

/* aborts every run, drops its reply and queued messages, and forgets every chat */
- (void)reset;
/* the same for one channel; a tool call the user already approved still runs, but its result is dropped */
- (void)resetChannel:(NSString *)channelId;

@end

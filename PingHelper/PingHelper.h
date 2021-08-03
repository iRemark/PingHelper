
#import <Foundation/Foundation.h>


NS_ASSUME_NONNULL_BEGIN



@interface PingResult : NSObject

@property (readonly) NSInteger code;
@property (readonly) NSTimeInterval delay;
@property (readonly) NSString * _Nonnull host;

- (NSString *_Nonnull)description;

@end



typedef void (^PingCompleteHandler)(NSArray<PingResult*>* _Nonnull results);
@interface PingHelper : NSObject

+ (void)ping:(NSArray <NSString*>*_Nonnull)hosts
       count:(NSInteger)count
      timeout:(NSTimeInterval)timeout
    complete:(PingCompleteHandler _Nullable)complete;

@end

NS_ASSUME_NONNULL_END

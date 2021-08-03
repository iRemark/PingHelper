
#import "PingHelper.h"

#import <arpa/inet.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <netinet/in.h>
#import <netinet/tcp.h>

#include <AssertMacros.h>

const int kInvalidResponse = -22001;
const int kRequestStoped = -2;

@interface PingModel: NSObject

@property (copy, nonatomic) NSDate *startDate;
@property (copy, nonatomic) NSDate *endDate;

@property (copy, nonatomic) NSString *host;
@property (assign, nonatomic) NSTimeInterval delay;

@end

@implementation PingModel

- (instancetype)initWithHost:(NSString *)host startDate:(NSDate *)date {
    self = [super init];
    if (self) {
        _host = host;
        _startDate = date;
        _delay = 0;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@ delay=%.3f ms", _host, _delay];
}

- (void)calculator {
    _delay = [_endDate timeIntervalSinceDate:_startDate] * 1000;
}

@end



@implementation PingResult

- (NSString *)description {
    if (_code == 0 || _code == kRequestStoped) {
        return [NSString stringWithFormat:@"%@ delay=%.3f ms", _host, _delay];
    }
    return [NSString stringWithFormat:@"%@ ping failed %ld",_host, (long)_code];
}

- (instancetype)init:(NSInteger)code ip:(NSString *)ip delay:(NSTimeInterval)delay {
    if (self = [super init]) {
        _code = code;
        _host = ip;
        _delay = delay;
    }
    return self;
}

@end

// IP header structure:

struct ICMPIPHeader {
    uint8_t versionAndHeaderLength;
    uint8_t differentiatedServices;
    uint16_t totalLength;
    uint16_t identification;
    uint16_t flagsAndFragmentOffset;
    uint8_t timeToLive;
    uint8_t protocol;
    uint16_t headerChecksum;
    uint8_t sourceAddress[4];
    uint8_t destinationAddress[4];
    // options...
    // data...
};

typedef struct ICMPIPHeader ICMPIPHeader;

__Check_Compile_Time(sizeof(ICMPIPHeader) == 20);
__Check_Compile_Time(offsetof(ICMPIPHeader, versionAndHeaderLength) == 0);
__Check_Compile_Time(offsetof(ICMPIPHeader, differentiatedServices) == 1);
__Check_Compile_Time(offsetof(ICMPIPHeader, totalLength) == 2);
__Check_Compile_Time(offsetof(ICMPIPHeader, identification) == 4);
__Check_Compile_Time(offsetof(ICMPIPHeader, flagsAndFragmentOffset) == 6);
__Check_Compile_Time(offsetof(ICMPIPHeader, timeToLive) == 8);
__Check_Compile_Time(offsetof(ICMPIPHeader, protocol) == 9);
__Check_Compile_Time(offsetof(ICMPIPHeader, headerChecksum) == 10);
__Check_Compile_Time(offsetof(ICMPIPHeader, sourceAddress) == 12);
__Check_Compile_Time(offsetof(ICMPIPHeader, destinationAddress) == 16);

typedef struct ICMPICMPPacket {
    uint8_t type;
    uint8_t code;
    uint16_t checksum;
    uint16_t identifier;
    uint16_t sequenceNumber;
    uint8_t payload[0]; // data, variable length
} ICMPICMPPacket;

enum {
    kICMPTypeEchoReply = 0,
    kICMPTypeEchoRequest = 8
};

__Check_Compile_Time(sizeof(ICMPICMPPacket) == 8);
__Check_Compile_Time(offsetof(ICMPICMPPacket, type) == 0);
__Check_Compile_Time(offsetof(ICMPICMPPacket, code) == 1);
__Check_Compile_Time(offsetof(ICMPICMPPacket, checksum) == 2);
__Check_Compile_Time(offsetof(ICMPICMPPacket, identifier) == 4);
__Check_Compile_Time(offsetof(ICMPICMPPacket, sequenceNumber) == 6);

const int kICMPPacketSize = sizeof(ICMPICMPPacket) + 100;

const int kICMPPacketBufferSize = 65535;

static uint16_t ICMP_in_cksum(const void *buffer, size_t bufferLen) {
    size_t bytesLeft;
    int32_t sum;
    const uint16_t *cursor;
    union {
        uint16_t us;
        uint8_t uc[2];
    } last;
    uint16_t answer;

    bytesLeft = bufferLen;
    sum = 0;
    cursor = buffer;

    /*
     * Our algorithm is simple, using a 32 bit accumulator (sum), we add
     * sequential 16 bit words to it, and at the end, fold back all the
     * carry bits from the top 16 bits into the lower 16 bits.
     */
    while (bytesLeft > 1) {
        sum += *cursor;
        cursor += 1;
        bytesLeft -= 2;
    }

    /* mop up an odd byte, if necessary */
    if (bytesLeft == 1) {
        last.uc[0] = *(const uint8_t *)cursor;
        last.uc[1] = 0;
        sum += last.us;
    }

    /* add back carry outs from top 16 bits to low 16 bits */
    sum = (sum >> 16) + (sum & 0xffff); /* add hi 16 to low 16 */
    sum += (sum >> 16); /* add carry */
    answer = (uint16_t)~sum; /* truncate to 16 bits */

    return answer;
}

static ICMPICMPPacket *ICMP_build_packet(uint16_t seq, uint16_t identifier) {
    ICMPICMPPacket *packet = (ICMPICMPPacket *)calloc(kICMPPacketSize, 1);
    packet->type = kICMPTypeEchoRequest;
    packet->code = 0;
    packet->checksum = 0;
    packet->identifier = OSSwapHostToBigInt16(identifier);
    packet->sequenceNumber = OSSwapHostToBigInt16(seq);
    snprintf((char *)packet->payload, kICMPPacketSize - sizeof(ICMPICMPPacket), "qiniu ping test %d", (int)seq);
    packet->checksum = ICMP_in_cksum(packet, kICMPPacketSize);
    return packet;
}

static char *ICMP_icmpInPacket(char *packet, int len) {
    if (len < (sizeof(ICMPIPHeader) + sizeof(ICMPICMPPacket))) {
        return NULL;
    }
    const struct ICMPIPHeader *ipPtr = (const ICMPIPHeader *)packet;
    if ((ipPtr->versionAndHeaderLength & 0xF0) != 0x40 // IPv4
        ||
        ipPtr->protocol != 1) { //ICMP
        return NULL;
    }
    size_t ipHeaderLength = (ipPtr->versionAndHeaderLength & 0x0F) * sizeof(uint32_t);

    if (len < ipHeaderLength + sizeof(ICMPICMPPacket)) {
        return NULL;
    }

    return (char *)packet + ipHeaderLength;
}

//static BOOL ICMP_isValidResponse(char *buffer, int len, int seq, int identifier) {
//    ICMPICMPPacket *icmpPtr = (ICMPICMPPacket *)ICMP_icmpInPacket(buffer, len);
//    if (icmpPtr == NULL) {
//        return NO;
//    }
//    uint16_t receivedChecksum = icmpPtr->checksum;
//    icmpPtr->checksum = 0;
//    uint16_t calculatedChecksum = ICMP_in_cksum(icmpPtr, len - ((char *)icmpPtr - buffer));
//
//    return receivedChecksum == calculatedChecksum &&
//           icmpPtr->type == kICMPTypeEchoReply &&
//           icmpPtr->code == 0 &&
//           OSSwapBigToHostInt16(icmpPtr->identifier) == identifier &&
//           OSSwapBigToHostInt16(icmpPtr->sequenceNumber) <= seq;
//}

static BOOL isValid(char *buffer, int len) {
    ICMPICMPPacket *icmpPtr = (ICMPICMPPacket *)ICMP_icmpInPacket(buffer, len);
    if (icmpPtr == NULL) {
        return NO;
    }
    uint16_t receivedChecksum = icmpPtr->checksum;
    icmpPtr->checksum = 0;
    uint16_t calculatedChecksum = ICMP_in_cksum(icmpPtr, len - ((char *)icmpPtr - buffer));
    
    return receivedChecksum == calculatedChecksum &&
           icmpPtr->type == kICMPTypeEchoReply &&
           icmpPtr->code == 0;
}

@interface PingHelper()

@property (nonatomic) dispatch_queue_t send_que;
@property (nonatomic) dispatch_queue_t recv_que;

@property (nonatomic) NSInteger count;
@property (nonatomic) NSInteger currentCount;

@property (nonatomic) NSTimeInterval timeout;
@property (nonatomic) int sock;

@property (atomic) BOOL stopped;

@property (nonatomic, strong) NSArray <NSString*> *hosts;
@property (nonatomic, strong) NSMutableDictionary *results;

@property (nonatomic, copy) PingCompleteHandler complete;
@property (nonatomic, copy) NSLock *lock;

@end


@implementation PingHelper

- (instancetype)init {
    self = [super init];
    if (self) {
        _send_que = dispatch_queue_create("qnn_que_serial_send", DISPATCH_QUEUE_SERIAL);
        _recv_que = dispatch_queue_create("qnn_que_serial_recv", DISPATCH_QUEUE_SERIAL);
        _results = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        [self setup];
    }
    return self;
}

- (void)setup {
    _sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    setsockopt(_sock, SOL_SOCKET, SO_RCVTIMEO, (char *)&timeout, sizeof(timeout));
}

- (int)run:(NSString *)host {
    const char *hostAddress = [host UTF8String];
    if (hostAddress == NULL) {
        hostAddress = "\0";
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons(30002);
    addr.sin_addr.s_addr = inet_addr(hostAddress);
    if (addr.sin_addr.s_addr == INADDR_NONE) {
        struct hostent *host = gethostbyname(hostAddress);
        if (host == NULL || host->h_addr == NULL) {
            return 0;
        }
        addr.sin_addr = *(struct in_addr *)host->h_addr;
        // [NSString stringWithFormat:@"ping to ip %s ...\n", inet_ntoa(addr.sin_addr)]
    }
    uint16_t identifier = (uint16_t)arc4random();
    return [self sendPacket:&addr seq:_currentCount identifier:identifier];
}

- (int)sendPacket:(struct sockaddr_in *)addr seq:(uint16_t)seq identifier:(uint16_t)identifier {
    ICMPICMPPacket *packet = ICMP_build_packet(seq, identifier);
    int err = 0;
    ssize_t sent = sendto(_sock, packet, 100, 0, (struct sockaddr *)addr, (socklen_t)sizeof(struct sockaddr));
    if (sent < 0) {
        err = errno;
    }
    free(packet);
    return err;
}

- (int)recv {
    struct sockaddr_storage ret_addr;
    socklen_t addrLen = sizeof(ret_addr);
    void *buffer = malloc(kICMPPacketBufferSize);
    int err = 0;
    ssize_t bytesRead = recvfrom(_sock, buffer, kICMPPacketBufferSize, 0,
                                 (struct sockaddr *)&ret_addr, &addrLen);
    if (bytesRead < 0) {
        err = errno;
    } else if (bytesRead == 0) {
        err = EPIPE;
    } else {
        int ttlOut = 0;
        int size = 0;
        int len = (int)bytesRead;
        if (isValid(buffer, len)) {
            ttlOut = ((ICMPIPHeader *)buffer)->timeToLive;
            size = len;
            
            char hoststr[INET_ADDRSTRLEN];
            struct sockaddr_in *sin = (struct sockaddr_in *)&ret_addr;
            inet_ntop(sin->sin_family, &(sin->sin_addr), hoststr, INET_ADDRSTRLEN);
            NSString *host = [[NSString alloc] initWithUTF8String:hoststr];
            
            ICMPICMPPacket *icmpPtr = (ICMPICMPPacket *)ICMP_icmpInPacket(buffer, len);
            int seq = OSSwapBigToHostInt16(icmpPtr->sequenceNumber);
            NSString *key = [NSString stringWithFormat:@"%@", @(seq)];
            PingModel *result = self.results[host][key];
            if (result) {
                result.endDate = [NSDate date];
            }
        }else {
            err = kInvalidResponse;
        }
    }
    free(buffer);
    return err;
}

- (void)calculatePingDelayTime {
    _stopped = YES;
    NSMutableArray *pingResult = [NSMutableArray array];
    for (NSString *ip in self.results.allKeys) {
        NSDictionary *delays = self.results[ip];
        NSTimeInterval sum = 0;
        for (PingModel *result in delays.allValues) {
            [result calculator];
            sum += result.delay;
        }
        NSTimeInterval delay = sum / delays.count;
        PingResult *result;
        if (delay > 0 && delay < 999) {
            result = [[PingResult alloc] init:0 ip:ip delay:delay];
        } else {
            result = [[PingResult alloc] init:-1 ip:ip delay:0];
        }
        [pingResult addObject:result];
    }
    if (self.complete) {
        self.complete(pingResult);
    }
    close(_sock);
}

- (void)ping:(NSArray<NSString *> *)hosts count:(NSInteger)count
      timeout:(NSTimeInterval)timeout complete:(PingCompleteHandler)complete {
    _complete = complete;
    _count = count;
    _timeout = timeout;
    _hosts = hosts;
    
    dispatch_async(_send_que, ^{
        [self send];
    });
    dispatch_async(_recv_que, ^{
        @autoreleasepool {
            while (!self.stopped) {
                [self recv];
            }
        }
    });
}

- (void)send {
    __weak typeof(self) weakSelf = self;
    [self sendPackets:^{
        __strong typeof(self) strongSelf = weakSelf;
        strongSelf.currentCount++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (strongSelf.currentCount == self.count) {
                [strongSelf calculatePingDelayTime];
            } else {
                [strongSelf send];
            }
        });
    }];
}

- (void)sendPackets:(void(^)(void))complete {
    __block int count = 0;
    for (NSString *host in self.hosts) {
        NSDate *now = [NSDate date];
        PingModel *model = [[PingModel alloc] initWithHost:host startDate:now];
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        if (self.results[host]) {
            result = [NSMutableDictionary dictionaryWithDictionary:self.results[host]];
        }
        NSString *key = [NSString stringWithFormat:@"%@", @(_currentCount)];
        result[key] = model;
        self.results[host] = result;
    
        [self run:host];
        count++;
        if (count == self.hosts.count) {
            complete();
        }
    }
}


+ (void)ping:(NSArray <NSString*>*_Nonnull)hosts count:(NSInteger)count
     timeout:(NSTimeInterval)timeout complete:(PingCompleteHandler _Nullable)complete {
    
    PingHelper *helper = [[PingHelper alloc]init];
    [helper ping:hosts count:count timeout:timeout complete:complete];
}

@end

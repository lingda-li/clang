// RUN: %clang_cc1 -analyze -analyzer-checker=core,osx.cocoa.RetainCount,debug.ExprInspection -analyzer-store=region -verify -Wno-objc-root-class %s
// RUN: %clang_cc1 -analyze -analyzer-checker=core,osx.cocoa.RetainCount,debug.ExprInspection -analyzer-store=region -verify -Wno-objc-root-class -fobjc-arc %s

void clang_analyzer_eval(int);

typedef signed char BOOL;
typedef unsigned int NSUInteger;
typedef struct _NSZone NSZone;
@class NSInvocation, NSMethodSignature, NSCoder, NSString, NSEnumerator;
@protocol NSObject  - (BOOL)isEqual:(id)object; @end
@protocol NSCopying  - (id)copyWithZone:(NSZone *)zone; @end
@protocol NSCoding  - (void)encodeWithCoder:(NSCoder *)aCoder; @end
@protocol NSMutableCopying  - (id)mutableCopyWithZone:(NSZone *)zone; @end
@interface NSObject <NSObject> {}
+(id)alloc;
-(id)init;
-(id)autorelease;
-(id)copy;
-(id)retain;
-(oneway void)release;
@end
@interface NSString : NSObject <NSCopying, NSMutableCopying, NSCoding>
- (NSUInteger)length;
-(id)initWithFormat:(NSString *)f,...;
-(BOOL)isEqualToString:(NSString *)s;
+ (id)string;
@end
@interface NSNumber : NSObject {}
+(id)alloc;
-(id)initWithInteger:(int)i;
@end

// rdar://6946338

@interface Test1 : NSObject {
  NSString *text;
}
-(id)myMethod;
@property (nonatomic, assign) NSString *text;
@end


#if !__has_feature(objc_arc)

@implementation Test1

@synthesize text;

-(id)myMethod {
  Test1 *cell = [[[Test1 alloc] init] autorelease];

  NSString *string1 = [[NSString alloc] initWithFormat:@"test %f", 0.0]; // expected-warning {{Potential leak}}
  cell.text = string1;

  return cell;
}

@end


// rdar://8824416

@interface MyNumber : NSObject
{
  NSNumber* _myNumber;
}

- (id)initWithNumber:(NSNumber *)number;

@property (nonatomic, readonly) NSNumber* myNumber;
@property (nonatomic, readonly) NSNumber* newMyNumber;

@end

@implementation MyNumber
@synthesize myNumber=_myNumber;
 
- (id)initWithNumber:(NSNumber *)number
{
  self = [super init];
  
  if ( self )
  {
    _myNumber = [number copy];
  }
  
  return self;
}

- (NSNumber*)newMyNumber
{
  if ( _myNumber )
    return [_myNumber retain];
  
  return [[NSNumber alloc] initWithInteger:1];
}

- (id)valueForUndefinedKey:(NSString*)key
{
  id value = 0;
  
  if ([key isEqualToString:@"MyIvarNumberAsPropertyOverReleased"])
    value = self.myNumber; // _myNumber will be over released, since the value returned from self.myNumber is not retained.
  else if ([key isEqualToString:@"MyIvarNumberAsPropertyOk"])
    value = [self.myNumber retain]; // this line fixes the over release
  else if ([key isEqualToString:@"MyIvarNumberAsNewMyNumber"])
    value = self.newMyNumber; // this one is ok, since value is returned retained
  else 
    value = [[NSNumber alloc] initWithInteger:0];
  
  return [value autorelease]; // expected-warning {{Object autoreleased too many times}}
}

@end

NSNumber* numberFromMyNumberProperty(MyNumber* aMyNumber)
{
  NSNumber* result = aMyNumber.myNumber;
    
  return [result autorelease]; // expected-warning {{Object autoreleased too many times}}
}

#endif


// rdar://6611873

@interface Person : NSObject {
  NSString *_name;
}
@property (retain) NSString * name;
@property (assign) id friend;
@end

@implementation Person
@synthesize name = _name;
@end

#if !__has_feature(objc_arc)
void rdar6611873() {
  Person *p = [[[Person alloc] init] autorelease];
  
  p.name = [[NSString string] retain]; // expected-warning {{leak}}
  p.name = [[NSString alloc] init]; // expected-warning {{leak}}

  p.friend = [[Person alloc] init]; // expected-warning {{leak}}
}
#endif

@interface SubPerson : Person
-(NSString *)foo;
@end

@implementation SubPerson
-(NSString *)foo {
  return super.name;
}
@end


#if !__has_feature(objc_arc)
// <rdar://problem/9241180> Static analyzer doesn't detect uninitialized variable issues for property accesses
@interface RDar9241180
@property (readwrite,assign) id x;
-(id)testAnalyzer1:(int) y;
-(void)testAnalyzer2;
@end

@implementation RDar9241180
@synthesize x;
-(id)testAnalyzer1:(int)y {
    RDar9241180 *o;
    if (y && o.x) // expected-warning {{Property access on an uninitialized object pointer}}
      return o;
    return o; // expected-warning {{Undefined or garbage value returned to caller}}
}
-(void)testAnalyzer2 {
  id y;
  self.x = y;  // expected-warning {{Argument for property setter is an uninitialized value}}
}
@end
#endif


//------
// Property accessor synthesis
//------

extern void doSomethingWithPerson(Person *p);
extern void doSomethingWithName(NSString *name);

void testConsistencyRetain(Person *p) {
  clang_analyzer_eval(p.name == p.name); // expected-warning{{TRUE}}

  id origName = p.name;
  clang_analyzer_eval(p.name == origName); // expected-warning{{TRUE}}
  doSomethingWithPerson(p);
  clang_analyzer_eval(p.name == origName); // expected-warning{{UNKNOWN}}
}

void testConsistencyAssign(Person *p) {
  clang_analyzer_eval(p.friend == p.friend); // expected-warning{{TRUE}}

  id origFriend = p.friend;
  clang_analyzer_eval(p.friend == origFriend); // expected-warning{{TRUE}}
  doSomethingWithPerson(p);
  clang_analyzer_eval(p.friend == origFriend); // expected-warning{{UNKNOWN}}
}

#if !__has_feature(objc_arc)
void testOverrelease(Person *p, int coin) {
  switch (coin) {
  case 0:
    [p.name release]; // expected-warning{{not owned}}
    break;
  case 1:
    [p.friend release]; // expected-warning{{not owned}}
    break;
  case 2: {
    id friend = p.friend;
    doSomethingWithPerson(p);
    [friend release]; // expected-warning{{not owned}}
  }
  }
}

// <rdar://problem/16333368>
@implementation Person (Rdar16333368)

- (void)testDeliberateRelease:(Person *)other {
  doSomethingWithName(self.name);
  [_name release]; // no-warning
  self->_name = 0;

  doSomethingWithName(other->_name);
  [other.name release]; // no-warning
}

- (void)deliberateReleaseFalseNegative {
  // This is arguably a false negative because the result of p.friend shouldn't
  // be released, even though we are manipulating the ivar in between the two
  // actions.
  id name = self.name;
  _name = 0;
  [name release];
}

- (void)testRetainAndRelease {
  [self.name retain];
  [self.name release];
  [self.name release]; // expected-warning{{not owned}}
}

- (void)testRetainAndReleaseIVar {
  [self.name retain];
  [_name release];
  [_name release];
}

@end
#endif

@interface IntWrapper
@property int value;
@end

@implementation IntWrapper
@synthesize value;
@end

void testConsistencyInt(IntWrapper *w) {
  clang_analyzer_eval(w.value == w.value); // expected-warning{{TRUE}}

  int origValue = w.value;
  if (origValue != 42)
    return;

  clang_analyzer_eval(w.value == 42); // expected-warning{{TRUE}}
}

void testConsistencyInt2(IntWrapper *w) {
  if (w.value != 42)
    return;

  clang_analyzer_eval(w.value == 42); // expected-warning{{TRUE}}
}


@interface IntWrapperAuto
@property int value;
@end

@implementation IntWrapperAuto
@end

void testConsistencyIntAuto(IntWrapperAuto *w) {
  clang_analyzer_eval(w.value == w.value); // expected-warning{{TRUE}}

  int origValue = w.value;
  if (origValue != 42)
    return;

  clang_analyzer_eval(w.value == 42); // expected-warning{{TRUE}}
}

void testConsistencyIntAuto2(IntWrapperAuto *w) {
  if (w.value != 42)
    return;

  clang_analyzer_eval(w.value == 42); // expected-warning{{TRUE}}
}


typedef struct {
  int value;
} IntWrapperStruct;

@interface StructWrapper
@property IntWrapperStruct inner;
@end

@implementation StructWrapper
@synthesize inner;
@end

void testConsistencyStruct(StructWrapper *w) {
  clang_analyzer_eval(w.inner.value == w.inner.value); // expected-warning{{TRUE}}

  int origValue = w.inner.value;
  if (origValue != 42)
    return;

  clang_analyzer_eval(w.inner.value == 42); // expected-warning{{TRUE}}
}


@interface OpaqueIntWrapper
@property int value;
@end

// For now, don't assume a property is implemented using an ivar unless we can
// actually see that it is.
void testOpaqueConsistency(OpaqueIntWrapper *w) {
  clang_analyzer_eval(w.value == w.value); // expected-warning{{UNKNOWN}}
}


#if !__has_feature(objc_arc)
// Test quite a few cases of retain/release issues.

@interface RetainCountTesting
@property (strong) id ownedProp;
@property (unsafe_unretained) id unownedProp;
@property (nonatomic, strong) id manualProp;
@end

@implementation RetainCountTesting {
  id _ivarOnly;
}

- (id)manualProp {
  return _manualProp;
}

- (void)testOverreleaseOwnedIvar {
  [_ownedProp retain];
  [_ownedProp release];
  [_ownedProp release];
  [_ownedProp release]; // expected-warning{{used after it is released}}
}

- (void)testOverreleaseUnownedIvar {
  [_unownedProp retain];
  [_unownedProp release];
  [_unownedProp release]; // expected-warning{{not owned at this point by the caller}}
}

- (void)testOverreleaseIvarOnly {
  [_ivarOnly retain];
  [_ivarOnly release];
  [_ivarOnly release];
  [_ivarOnly release]; // expected-warning{{used after it is released}}
}

- (void)testOverreleaseOwnedIvarUse {
  [_ownedProp retain];
  [_ownedProp release];
  [_ownedProp release];
  [_ownedProp myMethod]; // expected-warning{{used after it is released}}
}

- (void)testOverreleaseIvarOnlyUse {
  [_ivarOnly retain];
  [_ivarOnly release];
  [_ivarOnly release];
  [_ivarOnly myMethod]; // expected-warning{{used after it is released}}
}

- (void)testOverreleaseOwnedIvarAutoreleaseOkay {
  [_ownedProp retain];
  [_ownedProp release];
  [_ownedProp autorelease];
} // no-warning

- (void)testOverreleaseIvarOnlyAutoreleaseOkay {
  [_ivarOnly retain];
  [_ivarOnly release];
  [_ivarOnly autorelease];
} // no-warning

- (void)testOverreleaseOwnedIvarAutorelease {
  [_ownedProp retain];
  [_ownedProp release];
  [_ownedProp autorelease];
  [_ownedProp autorelease];
} // expected-warning{{Object autoreleased too many times}}

- (void)testOverreleaseIvarOnlyAutorelease {
  [_ivarOnly retain];
  [_ivarOnly release];
  [_ivarOnly autorelease];
  [_ivarOnly autorelease];
} // expected-warning{{Object autoreleased too many times}}

- (void)testPropertyAccessThenReleaseOwned {
  id owned = [self.ownedProp retain];
  [owned release];
  [_ownedProp release];
  clang_analyzer_eval(owned == _ownedProp); // expected-warning{{TRUE}}
}

- (void)testPropertyAccessThenReleaseOwned2 {
  id fromIvar = _ownedProp;
  id owned = [self.ownedProp retain];
  [owned release];
  [fromIvar release];
  clang_analyzer_eval(owned == fromIvar); // expected-warning{{TRUE}}
}

- (void)testPropertyAccessThenReleaseUnowned {
  id unowned = [self.unownedProp retain];
  [unowned release];
  [_unownedProp release]; // expected-warning{{not owned}}
}

- (void)testPropertyAccessThenReleaseUnowned2 {
  id fromIvar = _unownedProp;
  id unowned = [self.unownedProp retain];
  [unowned release];
  clang_analyzer_eval(unowned == fromIvar); // expected-warning{{TRUE}}
  [fromIvar release]; // expected-warning{{not owned}}
}

- (void)testPropertyAccessThenReleaseManual {
  id prop = [self.manualProp retain];
  [prop release];
  [_manualProp release]; // no-warning
}

- (void)testPropertyAccessThenReleaseManual2 {
  id fromIvar = _manualProp;
  id prop = [self.manualProp retain];
  [prop release];
  clang_analyzer_eval(prop == fromIvar); // expected-warning{{TRUE}}
  [fromIvar release]; // no-warning
}

- (id)getUnownedFromProperty {
  [_ownedProp retain];
  [_ownedProp autorelease];
  return _ownedProp; // no-warning
}

- (id)transferUnownedFromProperty {
  [_ownedProp retain];
  [_ownedProp autorelease];
  return [_ownedProp autorelease]; // no-warning
}

- (id)transferOwnedFromProperty __attribute__((ns_returns_retained)) {
  [_ownedProp retain];
  [_ownedProp autorelease];
  return _ownedProp; // no-warning
}

- (void)testAssignOwned:(id)newValue {
  _ownedProp = newValue;
  [_ownedProp release]; // FIXME: no-warning{{not owned}}
}

- (void)testAssignUnowned:(id)newValue {
  _unownedProp = newValue;
  [_unownedProp release]; // FIXME: no-warning{{not owned}}
}

- (void)testAssignIvarOnly:(id)newValue {
  _ivarOnly = newValue;
  [_ivarOnly release]; // FIXME: no-warning{{not owned}}
}

- (void)testAssignOwnedOkay:(id)newValue {
  _ownedProp = [newValue retain];
  [_ownedProp release]; // no-warning
}

- (void)testAssignUnownedOkay:(id)newValue {
  _unownedProp = [newValue retain];
  [_unownedProp release]; // no-warning
}

- (void)testAssignIvarOnlyOkay:(id)newValue {
  _ivarOnly = [newValue retain];
  [_ivarOnly release]; // no-warning
}

@end
#endif // non-ARC


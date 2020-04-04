#import <CoreMotion/CoreMotion.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import "FreeFall.h"

// Fetch preferences booleans
static NSMutableDictionary *settings;
static BOOL useFreeFall;

// Reference to our FreeFall object
FreeFall *freeFallController;

// Preferences Update
static void refreshPrefs() {
	CFArrayRef keyList = CFPreferencesCopyKeyList(CFSTR("com.chewmieser.freefall"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
	if (keyList) {
		settings = (NSMutableDictionary *)CFBridgingRelease(CFPreferencesCopyMultiple(keyList, CFSTR("com.chewmieser.freefall"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
		CFRelease(keyList);
	} else {
		settings = nil;
	}
	if (!settings) {
		settings = [[NSMutableDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.chewmieser.freefall.plist"];
	}
	useFreeFall = [([settings objectForKey:@"useFreeFall"] ?: @(NO)) boolValue];
	}

static void PreferencesChangedCallback(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
  refreshPrefs();
}

@implementation FreeFall
	@synthesize prefs;
	
	- (id)init{
		if (self=[super init]){
			// Load our preferences
			[self loadPrefs];
			
			// Thanks Ryan Pendleton for silent state code
			notify_register_dispatch("com.apple.springboard.ringerstate", &_ringerStateToken, dispatch_get_main_queue(), ^(int token) {
				[self updateState];
			});
		}
		
		return self;
	}
	
	// Did receive preference reload notification
	- (void)loadPrefs{
		// Destroy the world
		if (prefs) [[self prefs] release];
		AudioServicesDisposeSystemSoundID(fallingSound);
		AudioServicesDisposeSystemSoundID(stoppingSound);
		
		// Load sensitivity preferences
		prefs=[[NSDictionary alloc] initWithContentsOfFile:@"/var/mobile/Library/Preferences/com.chewmieser.freefall.plist"];
		fallSensitivity=[[[self prefs] objectForKey:@"fallingSensitivity"] doubleValue] ?: 0.04;
		stopSensitivity=[[[self prefs] objectForKey:@"stoppingSensitivity"] doubleValue] ?: 6.0;
		
		// Setup falling sound
		fallPref=[[self prefs] objectForKey:@"fallingSound"];
		if (fallPref==nil) fallPref=@"WilhelmScream.wav";
		
		if (![fallPref isEqualToString:@"None"]){
			AudioServicesCreateSystemSoundID((CFURLRef)[NSURL fileURLWithPath:[NSString stringWithFormat:@"/Library/FreeFall/%@",fallPref]],&fallingSound);
		}
		
		// Setup stopping sound
		stopPref=[[self prefs] objectForKey:@"stoppingSound"];
		if (stopPref==nil) stopPref=@"None";
		
		if (![stopPref isEqualToString:@"None"]){
			AudioServicesCreateSystemSoundID((CFURLRef)[NSURL fileURLWithPath:[NSString stringWithFormat:@"/Library/FreeFall/%@",stopPref]],&stoppingSound);
		}
		
		// Setup timer
		[self updateState];
	}
	
	- (void)updateState{
		// Destroy objects
		if (_freeFallExecuteTimer!=nil){[_freeFallExecuteTimer invalidate]; _freeFallExecuteTimer=nil;}
		if (manager) [manager stopAccelerometerUpdates];
		
		// Silent switch toggle
		uint64_t state;
		
		// Are we completely disabled?
		if ((fallingSound!=0 || stoppingSound!=0) && (notify_get_state(_ringerStateToken, &state)==NOTIFY_STATUS_OK && state==1)){
			// Control variables
			fallSoundPlaying=NO;
			stopSoundPlaying=NO;
			
			// Setup CoreMotion
			manager=[[CMMotionManager alloc] init];
			manager.accelerometerUpdateInterval=0.01;
			[manager startAccelerometerUpdates];
			
			// Start the timer after a delay (was causing issues with the Preference Pane)
			[NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(enableTimer:) userInfo:nil repeats:NO];
		}
	}
	
	- (void)updateAccelData:(NSTimer *)timer{
		// Calculate acceleration
		double accel=sqrt(pow(manager.accelerometerData.acceleration.x,2) + pow(manager.accelerometerData.acceleration.y,2) + pow(manager.accelerometerData.acceleration.z,2));
		
		// Handle falling
		if (useFreeFall && accel<fallSensitivity && !fallSoundPlaying){
			falling=YES;
			[NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(dontLetStopPlay:) userInfo:nil repeats:NO];
			fallSoundPlaying=YES;
			[NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(doStopFallPlay:) userInfo:nil repeats:NO];
			
			if (![fallPref isEqualToString:@"None"]) AudioServicesPlaySystemSound(fallingSound);
		}
		
		// Handle stopping
		if (useFreeFall && accel>stopSensitivity && !stopSoundPlaying && falling){
			stopSoundPlaying=YES;
			[NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(doStopStopPlay:) userInfo:nil repeats:NO];
			if (![stopPref isEqualToString:@"None"]) AudioServicesPlaySystemSound(stoppingSound);
		}
	}
	
	- (void)enableTimer:(NSTimer *)timer{
		_freeFallExecuteTimer=[NSTimer scheduledTimerWithTimeInterval:0.01 target:self selector:@selector(updateAccelData:) userInfo:nil repeats:YES];
	}
	
	- (void)doStopFallPlay:(NSTimer *)timer{ fallSoundPlaying=NO; }	
	- (void)doStopStopPlay:(NSTimer *)timer{ stopSoundPlaying=NO; }
    - (void)dontLetStopPlay:(NSTimer *)timer{ falling=NO; }
	
@end
	
static void PreferencesChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo){
	[freeFallController loadPrefs];
}

// Set things up	
__attribute__((constructor)) static void init() {
	freeFallController=[[FreeFall alloc] init];
	
	// Handle preference changes. I’ll clean this later
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, PreferencesChanged, CFSTR("com.chewmieser.freefall.prefs-changed"), NULL, CFNotificationSuspensionBehaviorCoalesce);
}

%ctor {
	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback) PreferencesChangedCallback, CFSTR("com.chewmieser.freefall.prefs-changed"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	refreshPrefs();
}

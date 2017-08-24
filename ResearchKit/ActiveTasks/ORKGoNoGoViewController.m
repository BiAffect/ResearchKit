/*
 Copyright (c) 2017, Roland Rabien. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification,
 are permitted provided that the following conditions are met:
 
 1.  Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.
 
 2.  Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation and/or
 other materials provided with the distribution.
 
 3.  Neither the name of the copyright holder(s) nor the names of any contributors
 may be used to endorse or promote products derived from this software without
 specific prior written permission. No license is granted to the trademarks of
 the copyright holders even if such marks are included in this software.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */


#import "ORKGoNoGoViewController.h"

#import "ORKActiveStepView.h"
#import "ORKGoNoGoContentView.h"

#import "ORKActiveStepViewController_Internal.h"

#import "ORKCollectionResult.h"
#import "ORKGoNoGoResult.h"
#import "ORKGoNoGoStep.h"
#import "ORKResult.h"

#import "ORKHelpers_Internal.h"

#import <AudioToolbox/AudioServices.h>
#import <CoreMotion/CMDeviceMotion.h>


@implementation ORKGoNoGoViewController {
    ORKGoNoGoContentView *_gonogoContentView;
    
    NSMutableArray *_results;
    NSMutableArray *_samples;
    NSTimer *_stimulusTimer;
    NSTimer *_timeoutTimer;
    NSTimeInterval _stimulusTimestamp;
    NSTimeInterval _thresholdTimestamp;
    int _samplesSinceStimulus;
    BOOL _validResult;
    BOOL _timedOut;
    BOOL _shouldIndicateFailure;
    BOOL _testActive;
    BOOL _testEnded;
    NSMutableArray<NSNumber*>* tests;
    BOOL go;
    int _noGoCount;
    int _consecutiveNoGoCount;
}

- (instancetype)initWithStep:(ORKStep *)step {
    self = [super initWithStep:step];
    if (self) {
        self.suspendIfInactive = YES;
    }
    return self;
}

static const NSTimeInterval OutcomeAnimationDuration = 0.3;

#pragma mark - UIViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    [self configureTitle];
    _results = [NSMutableArray new];
    _samples = [NSMutableArray new];

    srand48(time(NULL));
    
    go = [self getNextTestType];
    
    _noGoCount = 0;
    _consecutiveNoGoCount = 0;
    
    _gonogoContentView = [[ORKGoNoGoContentView alloc] initWithColor:go ? self.view.tintColor : UIColor.greenColor];
    [_gonogoContentView setStimulusHidden:YES];
    
    self.activeStepView.activeCustomView = _gonogoContentView;
    self.activeStepView.stepViewFillsAvailableSpace = YES;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!_testEnded) {
        [self start];
        _shouldIndicateFailure = YES;
        _testActive = YES;
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    _testEnded = YES;
    _shouldIndicateFailure = NO;
    _testActive = NO;
    
    [self stopRecorders];
    [_stimulusTimer invalidate];
    _stimulusTimer = nil;
    [_timeoutTimer invalidate];
    _timeoutTimer = nil;
    
    [_gonogoContentView cancelReset];
}

#pragma mark - ORKActiveStepViewController

- (void)start {
    _stimulusTimestamp = 0;
    _thresholdTimestamp = 0;
    _samplesSinceStimulus = 0;
    [_samples removeAllObjects];
    [super start];
    [self startStimulusTimer];
}

#if TARGET_IPHONE_SIMULATOR
- (void)motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (event.type == UIEventSubtypeMotionShake) {
        _thresholdTimestamp = [NSProcessInfo processInfo].systemUptime;
        [self attemptDidFinish];
    }
}

#endif


- (ORKStepResult *)result {
    ORKStepResult *stepResult = [super result];
    stepResult.results = stepResult.results ? [stepResult.results arrayByAddingObjectsFromArray:_results] : _results;
    return stepResult;
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [super applicationWillResignActive:notification];
    _testActive = NO;
    _validResult = NO;
    [_stimulusTimer invalidate];
    _stimulusTimer = nil;
    [_timeoutTimer invalidate];
    _timeoutTimer = nil;
    [self stopRecorders];
    [_gonogoContentView cancelReset];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    [super applicationDidBecomeActive:notification];
    if (!_testEnded) {
        _testActive = YES;
        [self resetAfterDelay:0];
    }
}

#pragma mark - ORKRecorderDelegate

- (void)recorder:(ORKRecorder *)recorder didCompleteWithResult:(ORKResult *)result {
    [self attemptDidFinish];
}

#pragma mark - ORKDeviceMotionRecorderDelegate

- (void)deviceMotionRecorderDidUpdateWithMotion:(CMDeviceMotion *)motion {
    CMAcceleration v = motion.userAcceleration;
    CMRotationRate g = motion.rotationRate;
    
    double vectorMagnitude = sqrt(((v.x * v.x) + (v.y * v.y) + (v.z * v.z)));
    
    if (self.started && _samples != nil) {
        ORKGoNoGoSample *sample = [ORKGoNoGoSample new];
        sample.timestamp = [NSProcessInfo processInfo].systemUptime;
        sample.vectorMagnitude = vectorMagnitude;
        sample.accelX = v.x;
        sample.accelY = v.y;
        sample.accelZ = v.z;
        sample.gyroX  = g.x;
        sample.gyroY  = g.y;
        sample.gyroZ  = g.z;
        [_samples addObject:sample];
    }
    
    if (_stimulusTimestamp > 0) {
        _samplesSinceStimulus++;
    }
    
    if (vectorMagnitude > [self gonogoTimeStep].thresholdAcceleration) {
        _thresholdTimestamp = [NSProcessInfo processInfo].systemUptime;
    }
    if (_samplesSinceStimulus > 100 && _thresholdTimestamp > 0) {
        [self stopRecorders];
    }
}

#pragma mark - ORKGoNoGoStepViewController

- (ORKGoNoGoStep *)gonogoTimeStep {
    return (ORKGoNoGoStep *)self.step;
}

- (void)configureTitle {
    int successCount = 0;
    int errorCount = 0;
    NSTimeInterval lastReactionTime = 0;
    
    for (ORKGoNoGoResult* res in _results) {
        if (res.incorrect == NO) {
            successCount++;
        } else {
            errorCount++;
        }
        if (res.go && !res.incorrect) {
            lastReactionTime = res.timeToThreshold;
        }
    }

    int total = (int)[self gonogoTimeStep].numberOfAttempts;
    int step = MIN(total, successCount + 1);

    NSString *format = ORKLocalizedString(@"GONOGO_TASK_ATTEMPTS_FORMAT", nil);
    NSString *text = [NSString localizedStringWithFormat:format, ORKLocalizedStringFromNumber(@(step)), ORKLocalizedStringFromNumber(@(total))];
    
    if (errorCount > 0) {
        NSString *errorsFormat = ORKLocalizedString(@"GONOGO_TASK_ERRORS_FORMAT", nil);
        NSString *errorsText = [NSString localizedStringWithFormat:errorsFormat, errorCount];
        text = [text stringByAppendingString:errorsText];
    }
    if (lastReactionTime > 0) {
        NSString *reactionFormat = ORKLocalizedString(@"GONOGO_TASK_REACTION_FORMAT", nil);
        NSString *reactionText = [NSString localizedStringWithFormat:reactionFormat, lastReactionTime];
        text = [text stringByAppendingString:reactionText];
    }
    
    [self.activeStepView updateTitle:ORKLocalizedString(@"GONOGO_TASK_ACTIVE_STEP_TITLE", nil) text:text];
}

- (void)attemptDidFinish {
    void (^completion)(void) = ^{
        int successCount = 0;
        for (ORKGoNoGoResult* res in _results) {
            if (res.incorrect == NO) {
                successCount++;
            }
        }
        
        if (successCount == [self gonogoTimeStep].numberOfAttempts) {
            _testEnded = YES;
            [self configureTitle];
            [self performSelector:@selector(finish) withObject:nil afterDelay:2.5];
        } else {
            // If the user cancels the test, there may be animations active,
            // and the animation complete block will start the next test
            // after we've already tried to cancel. Don't let that happen
            if (_testActive) {
                [self resetAfterDelay:2];
            }
        }
    };
    
    if ((go && _validResult) || (!go && _timedOut)) {
        [self indicateResultIncorrect: NO completion:completion];
    } else {
        [self indicateResultIncorrect: YES completion:completion];
    }
    
    _validResult = NO;
    _timedOut = NO;
    [_stimulusTimer invalidate];
    _stimulusTimer = nil;
    [_timeoutTimer invalidate];
    _timeoutTimer = nil;
}

- (void)indicateResultIncorrect:(BOOL)incorrect completion:(void(^)(void))completion {
    
    // Exit early if not recording the failure
    if (incorrect && !_shouldIndicateFailure) {
        return;
    }
    
    // Create a result
    
    NSMutableArray *samples = [[NSMutableArray alloc] init];
    
    // Copy all samples which happen after stimulus is displayed and until threshold is reached
    // Convert timestamp relative to the time the stimulus was displayed
    for (ORKGoNoGoSample *sample in _samples) {
        NSTimeInterval newTimestamp = sample.timestamp - _stimulusTimestamp;
        
        if (newTimestamp >= 0) {
            sample.timestamp = newTimestamp;
            [samples addObject:sample];
        }
    }
        
    NSString *uniqueStep = [NSString stringWithFormat:@"%@.%@", self.step.identifier, [[NSUUID UUID] UUIDString]];
    ORKGoNoGoResult *gonogoResult = [[ORKGoNoGoResult alloc] initWithIdentifier:uniqueStep];
    gonogoResult.timestamp = _stimulusTimestamp;
    gonogoResult.samples = [samples copy];
    gonogoResult.timeToThreshold = go ? _thresholdTimestamp - _stimulusTimestamp : 0;
    gonogoResult.go = go;
    gonogoResult.incorrect = incorrect;
    [_results addObject:gonogoResult];
    
    // Start the animation and play the sound
    if (incorrect) {
        SystemSoundID sound = _timedOut ? [self gonogoTimeStep].timeoutSound : [self gonogoTimeStep].failureSound;
        AudioServicesPlayAlertSound(sound);
        [_gonogoContentView startFailureAnimationWithDuration:OutcomeAnimationDuration completion:completion];
    } else {
        AudioServicesPlaySystemSound([self gonogoTimeStep].successSound);
        [_gonogoContentView startSuccessAnimationWithDuration:OutcomeAnimationDuration completion:completion];
    }
}

- (BOOL)getNextTestType {
    // Never allow more than 2 no go in a row
    if (_consecutiveNoGoCount == 2) {
        _consecutiveNoGoCount = 0;
        return YES;
    }
    
    // Make sure there is always a no go
    int successCount = 0;
    for (ORKGoNoGoResult* res in _results) {
        if (res.incorrect == NO) {
            successCount++;
        }
    }

    if (successCount == [self gonogoTimeStep].numberOfAttempts - 1) {
        if (_noGoCount == 0) {
            _noGoCount++;
            return NO;
        }
    }
    
    BOOL testType = drand48() < 0.667;
    if (!testType)
    {
        _consecutiveNoGoCount++;
        _noGoCount++;
    }
    
    return testType;
}

- (void)resetAfterDelay:(NSTimeInterval)delay {
    ORKWeakTypeOf(self) weakSelf = self;
    
    go = [self getNextTestType];
    
    _gonogoContentView.stimulusColor = go ? self.view.tintColor : UIColor.greenColor;
    [_gonogoContentView resetAfterDelay:delay completion:^{
        [weakSelf configureTitle];
        [weakSelf start];
    }];
}

- (void)startStimulusTimer {
    if (_stimulusTimer != nil) {
        [_stimulusTimer invalidate];
    }
    _stimulusTimer = [NSTimer scheduledTimerWithTimeInterval:[self stimulusInterval] target:self selector:@selector(stimulusTimerDidFire) userInfo:nil repeats:NO];
}

- (void)stimulusTimerDidFire {
    _stimulusTimer = nil;
    _stimulusTimestamp = [NSProcessInfo processInfo].systemUptime;
    [_gonogoContentView setStimulusHidden:NO];
    _validResult = YES;
    [self startTimeoutTimer];
}

- (void)startTimeoutTimer {
    NSTimeInterval timeout = [self gonogoTimeStep].timeout;
    if (timeout > 0) {
        if (_timeoutTimer != nil) {
            [_timeoutTimer invalidate];
        }
        _timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:timeout target:self selector:@selector(timeoutTimerDidFire) userInfo:nil repeats:NO];
    }
}

- (void)timeoutTimerDidFire {
    _timeoutTimer = nil;
    _validResult = NO;
    _timedOut = YES;
    [self stopRecorders];
    
#if TARGET_IPHONE_SIMULATOR
    // Device motion recorder won't work, so manually trigger didfinish
    [self attemptDidFinish];
#endif
}

- (NSTimeInterval)stimulusInterval {
    ORKGoNoGoStep *step = [self gonogoTimeStep];
    NSTimeInterval range = step.maximumStimulusInterval - step.minimumStimulusInterval;
    NSTimeInterval randomFactor = ((NSTimeInterval)rand() / RAND_MAX) * range;
    return randomFactor + step.minimumStimulusInterval;
}

@end

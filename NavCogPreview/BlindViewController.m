/*******************************************************************************
 * Copyright (c) 2014, 2016  IBM Corporation, Carnegie Mellon University and others
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 *******************************************************************************/

#import "BlindViewController.h"
#import "NavSound.h"
#import "NavDeviceTTS.h"
#import "LocationEvent.h"
#import "NavUtil.h"
#import "NavDataStore.h"
#import "SettingViewController.h"
#import "NavBlindWebviewHelper.h"
#import "POIViewController.h"


@interface BlindViewController () {
}

@end

@implementation BlindViewController {
    NavBlindWebviewHelper *helper;
    HLPPreviewer *previewer;
    HLPPreviewCommander *commander;
    HLPLocation *location;
    HLPLocation *targetLocation;
    NSTimer *locationTimer;

    NSArray<NSObject*>* showingFeatures;
    NSDictionary*(^showingStyle)(NSObject* obj);
    NSObject* selectedFeature;
    HLPLocation *center;
    BOOL loaded;
    
    HLPPreviewEvent *current;

    BOOL isAutoProceed;
    NSTimer *autoTimer;
    double stepSpeed;
    double stepCounter;
    double remainingDistance;
}

- (void)dealloc
{
    [helper prepareForDealloc];
    helper.delegate = nil;
    helper = nil;
    
    _settingButton = nil;
    
    [[NSUserDefaults standardUserDefaults] removeObserver:self forKeyPath:@"developer_mode"];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self.devUp setTitle:@"Up" forState:UIControlStateNormal];
    [self.devDown setTitle:@"Down" forState:UIControlStateNormal];
    [self.devLeft setTitle:@"Left" forState:UIControlStateNormal];
    [self.devRight setTitle:@"Right" forState:UIControlStateNormal];
    
    NSString *server = [[NSUserDefaults standardUserDefaults] stringForKey:@"selected_hokoukukan_server"];
    helper = [[NavBlindWebviewHelper alloc] initWithWebview:self.webView server:server];
    helper.userMode = [[NSUserDefaults standardUserDefaults] stringForKey:@"user_mode"];
    helper.delegate = self;
    
    _indicator.accessibilityLabel = NSLocalizedString(@"Loading, please wait", @"");
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _indicator);
    
    [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(checkMapCenter:) userInfo:nil repeats:YES];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(routeChanged:) name:ROUTE_CHANGED_NOTIFICATION object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(voiceOverStatusChanged:) name:UIAccessibilityVoiceOverStatusChanged object:nil];
}

- (void) voiceOverStatusChanged:(NSNotification*)note
{
    [self updateView];
}

- (void) routeChanged:(NSNotification*)note
{
    NSLog(@"%@", NSStringFromSelector(_cmd));
    
    NavDataStore *nds = [NavDataStore sharedDataStore];
    NSLog(@"%@", [nds route]);
    NSLog(@"%@", (nds.to._id == nil)?@"No Dest":@"With Dests");
    
    previewer = [[HLPPreviewer alloc] init];
    previewer.delegate = self;
    _cover.delegate = self;
    
    commander = [[HLPPreviewCommander alloc] init];
    commander.delegate = self;
    
    [previewer startAt:nds.from.location];
}

- (void) checkMapCenter:(NSTimer*)timer
{
    dispatch_async(dispatch_get_main_queue(), ^{
        HLPLocation *loc = [helper getCenter];
        if (loc != nil) {
            [NavDataStore sharedDataStore].mapCenter = loc;
            HLPLocation *cloc = [NavDataStore sharedDataStore].currentLocation;
            if (isnan(cloc.lat) || isnan(cloc.lng)) {
                NSDictionary *param =
                @{
                  @"floor": @(loc.floor),
                  @"lat": @(loc.lat),
                  @"lng": @(loc.lng),
                  @"sync": @(YES)
                  };
                [[NSNotificationCenter defaultCenter] postNotificationName:MANUAL_LOCATION_CHANGED_NOTIFICATION object:self userInfo:param];
                
            }
            [self updateView];
            [timer invalidate];
        }
    });
}

- (void)viewWillAppear:(BOOL)animated
{
}

- (void)viewWillDisappear:(BOOL)animated
{
}

- (void)viewDidAppear:(BOOL)animated
{
    [self updateView];
}

- (void)viewDidDisappear:(BOOL)animated
{
}

#pragma mark - HLPPreivewCommanderDelegate

- (void) playStep
{
    [[NavSound sharedInstance] playStep:nil];
}

- (void) playNoStep
{
    [[NavSound sharedInstance] playNoStep];
}

- (void) vibrate
{
    [[NavSound sharedInstance] vibrate:nil];
}

- (void)speak:(NSString *)text withOptions:(NSDictionary *)options completionHandler:(void (^)())handler
{
    [[NavDeviceTTS sharedTTS] speak:text withOptions:options completionHandler:handler];
}

#pragma mark - HLPPreviewerDelegate

-(void)previewStarted:(HLPPreviewEvent*)event
{
    [self targetLocation:event];
    [commander previewStarted:event];
    current = event;
    remainingDistance = current.next.distanceMoved;
}

-(void)previewUpdated:(HLPPreviewEvent*)event
{
    [self targetLocation:event];
    [commander previewUpdated:event];
    current = event;
    remainingDistance = current.next.distanceMoved;
}

-(void)previewStopped:(HLPPreviewEvent*)event
{
    [commander previewStopped:event];
}

- (void)userMoved:(double)distance
{
    if (isAutoProceed == NO) {
        [commander userMoved:distance];
    }
    if (distance == 0) {
        isAutoProceed = NO;
    }
}

- (void) targetLocation:(HLPPreviewEvent*)event
{
    if (!location) {
        location = [[HLPLocation alloc] init];
        [location update:event.location];
        [location updateOrientation:event.orientation withAccuracy:0];
        targetLocation = [[HLPLocation alloc] init];
        [targetLocation update:location];
    } else {
        if (!targetLocation) {
            targetLocation = [[HLPLocation alloc] init];
        }
        [targetLocation update:event.location];
        [targetLocation updateOrientation:event.orientation withAccuracy:0];
    }
    [self startLocationAnimation];
}

- (void)startLocationAnimation
{
    if (!locationTimer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            locationTimer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer * _Nonnull timer) {
                double r = 0.8;
                [location updateFloor:targetLocation.floor];
                [location updateLat:location.lat*r + targetLocation.lat*(1-r)
                                Lng:location.lng*r + targetLocation.lng*(1-r)];
                
                double diff = [HLPLocation normalizeDegree:targetLocation.orientation - location.orientation];
                double ori = location.orientation + diff * (1-r);

                [location updateOrientation:ori withAccuracy:0];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showLocation];
                });
            }];
        });
    }
}

- (void) showLocation
{
    double orientation = -location.orientation / 180 * M_PI;
    
    [helper sendData:@[@{
                           @"type":@"ORIENTATION",
                           @"z":@(orientation)
                           }]
            withName:@"Sensor"];
    
    [helper sendData:@{
                       @"lat":@(location.lat),
                       @"lng":@(location.lng),
                       @"floor":@(location.floor),
                       @"accuracy":@(1),
                       @"rotate":@(0), // dummy
                       @"orientation":@(999), //dummy
                       @"debug_info":[NSNull null],
                       @"debug_latlng":[NSNull null]
                       }
            withName:@"XYZ"];
}

#pragma mark - PreviewCommandDelegate

- (void)speakAtPoint:(CGPoint)point
{
    isAutoProceed = NO;
    // not implemented
}

- (void)stopSpeaking
{
    isAutoProceed = NO;
    [[NavDeviceTTS sharedTTS] stop:NO];
}

- (void)speakCurrentPOI
{
    isAutoProceed = NO;
    [commander previewCurrent];
}

- (void)selectCurrentPOI
{
    isAutoProceed = NO;
    if (current && current.targetPOIs) {
        POIViewController *vc = [[UIStoryboard storyboardWithName:@"Preview" bundle:nil] instantiateViewControllerWithIdentifier:@"poi_view"];
        vc.pois = current.targetPOIs;
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#define TIMER_INTERVAL (1.0/64.0)

- (void)autoStepForwardSpeed:(double)speed Active:(BOOL)active
{
    NSLog(@"%@ %f, %d", NSStringFromSelector(_cmd), speed, active);
    
    if (!autoTimer) {
        stepCounter = 1;
        autoTimer = [NSTimer scheduledTimerWithTimeInterval:TIMER_INTERVAL target:self selector:@selector(autoStep:) userInfo:nil repeats:YES];
    } else {
        if (speed == 0) {
            [autoTimer invalidate];
            autoTimer = nil;
        }
    }
    
    stepSpeed = speed;
    isAutoProceed = active;
}

- (void)autoStep:(NSTimer*)timer
{
    if (isAutoProceed == NO) {
        [autoTimer invalidate];
        autoTimer = nil;
    }
    
    stepCounter += TIMER_INTERVAL * stepSpeed;
    if (stepCounter >= 1.0) {
        double step_length = [[NSUserDefaults standardUserDefaults] doubleForKey:@"preview_step_length"];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self playStep];
            if (isAutoProceed) {
                targetLocation = [targetLocation offsetLocationByDistance:step_length Bearing:targetLocation.orientation];
            }
        });
        stepCounter -= 1.0;

        if (isAutoProceed) {
            remainingDistance -= step_length;
            if (remainingDistance < 0) {
                [previewer stepForward];
            }
        }
    }
}


- (void)quit
{
    NSString *title = @"Quit Preview";
    NSString *message = @"Are you sure to quit preview?";
    NSString *quit = @"Quit";
    NSString *cancel = @"Cancel";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:quit
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                                                  [previewer stop];
                                                  [NavDataStore sharedDataStore].previewMode = NO;
                                                  [self updateView];
                                              }]];
    [alert addAction:[UIAlertAction actionWithTitle:cancel
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                                              }]];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - PreviewTraverseDelegate

- (void)gotoBegin
{
    isAutoProceed = NO;
    [previewer gotoBegin];
}

- (void)gotoEnd
{
    isAutoProceed = NO;
    [previewer gotoEnd];
}

- (void)stepForward
{
    isAutoProceed = NO;
    [previewer stepForward];
}

- (void)stepBackward
{
    isAutoProceed = NO;
    [previewer stepBackward];
}

- (void)jumpForward
{
    isAutoProceed = NO;
    [previewer jumpForward];
}

- (void)jumpBackward
{
    isAutoProceed = NO;
    [previewer jumpBackward];
}

- (void)faceRight
{
    isAutoProceed = NO;
    [previewer faceRight];
}

- (void)faceLeft
{
    isAutoProceed = NO;
    [previewer faceLeft];
}

#pragma mark - private

- (void) updateView
{
    dispatch_async(dispatch_get_main_queue(), ^{
        NavDataStore *nds = [NavDataStore sharedDataStore];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        
        BOOL hasCenter = [nds mapCenter] != nil;
        
        self.searchButton.enabled = hasCenter;
        if (nds.previewMode) {
            self.cover.hidden = NO;
            [self.cover becomeFirstResponder];
        } else {
            self.cover.hidden = YES;
        }
        
    });
}

- (void) startLoading {
    [_indicator startAnimating];
    _indicator.hidden = NO;
}

- (void) loaded {
    [_indicator stopAnimating];
    _indicator.hidden = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self insertScript];
    });
}

- (void)bridgeInserted
{
}

- (void) insertScript
{
    NSString *jspath = [[NSBundle mainBundle] pathForResource:@"fingerprint" ofType:@"js"];
    NSString *js = [[NSString alloc] initWithContentsOfFile:jspath encoding:NSUTF8StringEncoding error:nil];
    [helper evalScript:js];
}

- (void) showPOIs:(NSArray<HLPObject*>*)pois
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [helper evalScript:@"$hulop.map.clearRoute()"];
        NSArray *route = [pois filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id  _Nullable evaluatedObject, NSDictionary<NSString *,id> * _Nullable bindings) {
            if ([evaluatedObject isKindOfClass:HLPLink.class]) {
                HLPLink *link = (HLPLink*)evaluatedObject;
                return (link.sourceHeight == center.floor || link.targetHeight == center.floor);
            }
            return NO;
        }]];
        
        [helper showRoute:route];
    });
    
    [self showFeatures:pois withStyle:^NSDictionary *(NSObject *obj) {
        if ([obj isKindOfClass:HLPPOI.class]) {
            HLPPOI* p = (HLPPOI*)obj;
            if (isnan(center.floor) || isnan(p.height) || center.floor == p.height){
                NSString *name = @"P";
                if (p.poiCategoryString) {
                    name = [name stringByAppendingString:[p.poiCategoryString substringToIndex:1]];
                }
                
                return @{
                         @"lat": p.geometry.coordinates[1],
                         @"lng": p.geometry.coordinates[0],
                         @"count": name
                         };
            }
        }
        else if ([obj isKindOfClass:HLPFacility.class]) {
            HLPFacility* f = (HLPFacility*)obj;
            /*
             HLPNode *n = [poim nodeForFaciligy:f];
             if (isnan(center.floor) ||
             (n && n.height == center.floor) ||
             (!n && !isnan(f.height) && f.height == center.floor)) {
             
             return @{
             @"lat": f.geometry.coordinates[1],
             @"lng": f.geometry.coordinates[0],
             @"count": @"F"
             };
             }
             */
        }
        return (NSDictionary*)nil;
    }];
}

- (void) clearFeatures
{
    showingFeatures = @[];
    showingStyle = nil;
    selectedFeature = nil;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [helper evalScript:@"$hulop.fp.showFingerprints([]);"];
    });
}

- (void) showFeatures:(NSArray<NSObject*>*)features withStyle:(NSDictionary*(^)(NSObject* obj))styleFunction
{
    showingFeatures = features;
    showingStyle = styleFunction;

    NSMutableArray *temp = [@[] mutableCopy];
    for(NSObject *f in features) {
        NSDictionary *dict = styleFunction(f);
        if (dict) {
            [temp addObject:dict];
        }
    }
    
    NSData *data = [NSJSONSerialization dataWithJSONObject:temp options:0 error:nil];
    NSString* str = [[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
    NSString* script = [NSString stringWithFormat:@"$hulop.fp.showFingerprints(%@);", str];
    //NSLog(@"%@", script);
    dispatch_async(dispatch_get_main_queue(), ^{
        [helper evalScript:script];
    });
}

- (void)checkConnection {
    [_indicator stopAnimating];
    _indicator.hidden = YES;
    _retryButton.hidden = NO;
    _errorMessage.hidden = NO;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


#pragma mark - NavWebviewHelperDelegate

- (void) speak:(NSString*)text withOptions:(NSDictionary*)options {
    //[[NavDeviceTTS sharedTTS] speak:text withOptions:options completionHandler:nil];
}

- (BOOL) isSpeaking {
    //return [[NavDeviceTTS sharedTTS] isSpeaking];
    return NO;
}

- (void) vibrateOnAudioServices {
    //AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

- (void) manualLocationChangedWithOptions:(NSDictionary*)options {
    [[NSNotificationCenter defaultCenter] postNotificationName:MANUAL_LOCATION_CHANGED_NOTIFICATION object:self userInfo:options];
}

- (void) buildingChangedWithOptions:(NSDictionary*)options {
    [[NSNotificationCenter defaultCenter] postNotificationName:BUILDING_CHANGED_NOTIFICATION object:self userInfo:options];
}

- (void) wcuiStateChangedWithOptions:(NSDictionary*)options {
    [[NSNotificationCenter defaultCenter] postNotificationName:WCUI_STATE_CHANGED_NOTIFICATION object:self userInfo:options];
}

- (void) requestRatingWithOptions:(NSDictionary*)options {
    [[NSNotificationCenter defaultCenter] postNotificationName:REQUEST_RATING object:self userInfo:options];
}

- (void) requestOpenURL:(NSURL*)url {
    [[NSNotificationCenter defaultCenter] postNotificationName:REQUEST_OPEN_URL object:self userInfo:@{@"url": url}];
}

#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    // Get the new view controller using [segue destinationViewController].
    // Pass the selected object to the new view controller.
    [segue destinationViewController].restorationIdentifier = segue.identifier;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NavUtil hideWaitingForView:self.view];
    });
}

-(BOOL)shouldPerformSegueWithIdentifier:(NSString *)identifier sender:(id)sender
{
    if ([identifier isEqualToString:@"show_search"]) {
        UIViewController *vc = [[UIStoryboard storyboardWithName:@"Preview" bundle:nil] instantiateViewControllerWithIdentifier:@"search_view"];
        [self.navigationController pushViewController:vc animated:YES];
        return NO;
    }
    return YES;
}

@end
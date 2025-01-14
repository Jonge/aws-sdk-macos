//
// Copyright 2010-2017 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
// http://aws.amazon.com/apache2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//

#import <Cocoa/Cocoa.h>
#import <XCTest/XCTest.h>
#import "AWSLambda.h"
#import "AWSTestUtility.h"

@interface AWSLambdaTests : XCTestCase

@property NSString *echo_function_name;
@property NSString *echo2_function_name;

@end

@implementation AWSLambdaTests

- (void)setUp {
    [super setUp];
    [AWSTestUtility setupSessionCredentialsProvider];
    NSDictionary *testConfig = [AWSTestUtility getIntegrationTestConfigurationForPackageId: @"lambda"];
    self.echo_function_name = testConfig[@"echo_function_name"];
    self.echo2_function_name = testConfig[@"echo2_function_name"];
}

- (void)tearDown {
    [super tearDown];
}

- (void)testGetFunctionFailed {
    AWSLambda *lambda = [AWSLambda defaultLambda];

    AWSLambdaGetFunctionRequest *getFunctionsRequest = [AWSLambdaGetFunctionRequest new];
    getFunctionsRequest.functionName = @"non-exist-function";

    [[[lambda getFunction:getFunctionsRequest] continueWithBlock:^id(AWSTask *task) {
        XCTAssertNotNil(task.error);
        XCTAssertNil(task.result);

        return nil;
    }] waitUntilFinished];
}

- (void)testGetFunction {
    AWSLambda *lambda = [AWSLambda defaultLambda];

    AWSLambdaGetFunctionRequest *getFunctionsRequest = [AWSLambdaGetFunctionRequest new];
    getFunctionsRequest.functionName = [self echo_function_name];

    [[[lambda getFunction:getFunctionsRequest] continueWithBlock:^id(AWSTask *task) {
        if (task.error) {
            XCTFail(@"Error: [%@]", task.error);
        }

        if (task.result) {
            XCTAssertTrue([task.result isKindOfClass:[AWSLambdaGetFunctionResponse class]]);
            AWSLambdaGetFunctionResponse *getFunctionsResponse = task.result;
            XCTAssertNotNil(getFunctionsResponse.code);
            XCTAssertNotNil(getFunctionsResponse.configuration);
        }

        return nil;
    }] waitUntilFinished];
}

- (void)testGetFunctionsContainsInvalidChars {
    AWSLambda *lambda = [AWSLambda defaultLambda];

    AWSLambdaGetFunctionRequest *getFunctionsRequest = [AWSLambdaGetFunctionRequest new];
    getFunctionsRequest.functionName = @"invalid:function:name"; //function name can not contains ':' char

    [[[lambda getFunction:getFunctionsRequest] continueWithBlock:^id(AWSTask *task) {
        XCTAssertNotNil(task.error);
        XCTAssertNil(task.result);

        XCTAssertEqual(task.error.code, AWSLambdaErrorUnknown);
        XCTAssertEqualObjects(task.error.localizedFailureReason, @"ValidationException");

        return nil;
    }] waitUntilFinished];
}

- (void)testListFunctions {
    AWSLambda *lambda = [AWSLambda defaultLambda];
    AWSLambdaListFunctionsRequest *listFunctionsRequest = [AWSLambdaListFunctionsRequest new];
    [[[lambda listFunctions:listFunctionsRequest] continueWithBlock:^id(AWSTask *task) {
        if (task.error) {
            XCTFail(@"Error: [%@]", task.error);
        }

        if (task.result) {
            XCTAssertTrue([task.result isKindOfClass:[AWSLambdaListFunctionsResponse class]]);
            AWSLambdaListFunctionsResponse *listFunctionsResponse = task.result;
            XCTAssertTrue([listFunctionsResponse.functions isKindOfClass:[NSArray class]]);
            NSLog(@"Functions: %@",listFunctionsResponse);
        }

        return nil;
    }] waitUntilFinished];
}

- (void)testInvoke {
    AWSLambda *lambda = [AWSLambda defaultLambda];
    AWSLambdaInvocationRequest *invocationRequest = [AWSLambdaInvocationRequest new];
    invocationRequest.functionName = [self echo_function_name];
    invocationRequest.invocationType = AWSLambdaInvocationTypeRequestResponse;
    NSDictionary *parameters = @{@"key1" : @"value1",
                                 @"key2" : @"value2",
                                 @"key3" : @"value3",
                                 @"isError" : @NO};
    invocationRequest.payload = [NSJSONSerialization dataWithJSONObject:parameters
                                                                options:kNilOptions
                                                                  error:nil];
    invocationRequest.clientContext = [[AWSClientContext new] base64EncodedJSONString];

    [[[lambda invoke:invocationRequest] continueWithBlock:^id(AWSTask *task) {
        XCTAssertNil(task.error);
        XCTAssertNotNil(task.result);
        AWSLambdaInvocationResponse *invocationResponse = task.result;
        XCTAssertTrue([invocationResponse.payload isKindOfClass:[NSDictionary class]]);
        NSDictionary *result = invocationResponse.payload;
        XCTAssertEqualObjects(result[@"key1"], @"value1");
        XCTAssertEqualObjects(result[@"key2"], @"value2");
        XCTAssertEqualObjects(result[@"key3"], @"value3");
        return nil;
    }] waitUntilFinished];
}

- (void)testInvokeWithClockSkew {
    [AWSTestUtility setupSwizzling];
    
    XCTAssertFalse([NSDate aws_getRuntimeClockSkew], @"current RunTimeClockSkew is not zero!");
    [AWSTestUtility setMockDate:[NSDate dateWithTimeIntervalSince1970:3600]];
    
    AWSLambda *lambda = [AWSLambda defaultLambda];
    AWSLambdaInvocationRequest *invocationRequest = [AWSLambdaInvocationRequest new];
    invocationRequest.functionName = [self echo_function_name];
    invocationRequest.invocationType = AWSLambdaInvocationTypeRequestResponse;
    NSDictionary *parameters = @{@"key1" : @"value1",
                                 @"key2" : @"value2",
                                 @"key3" : @"value3",
                                 @"isError" : @NO};
    invocationRequest.payload = [NSJSONSerialization dataWithJSONObject:parameters
                                                                options:kNilOptions
                                                                  error:nil];
    invocationRequest.clientContext = [[AWSClientContext new] base64EncodedJSONString];
    
    [[[lambda invoke:invocationRequest] continueWithBlock:^id(AWSTask *task) {
        XCTAssertNil(task.error);
        XCTAssertNotNil(task.result);
        AWSLambdaInvocationResponse *invocationResponse = task.result;
        XCTAssertTrue([invocationResponse.payload isKindOfClass:[NSDictionary class]]);
        NSDictionary *result = invocationResponse.payload;
        XCTAssertEqualObjects(result[@"key1"], @"value1");
        XCTAssertEqualObjects(result[@"key2"], @"value2");
        XCTAssertEqualObjects(result[@"key3"], @"value3");
        return nil;
    }] waitUntilFinished];
    
    [AWSTestUtility revertSwizzling];
}

- (void)testInvoke2 {
    AWSLambda *lambda = [AWSLambda defaultLambda];

    AWSLambdaInvocationRequest *invocationRequest = [AWSLambdaInvocationRequest new];
    invocationRequest.functionName = [self echo2_function_name];
    invocationRequest.invocationType = AWSLambdaInvocationTypeRequestResponse;
    NSDictionary *parameters = @{@"firstName" : @"testInvokeFunction2",
                                 @"isError" : @NO};
    invocationRequest.payload = [NSJSONSerialization dataWithJSONObject:parameters
                                                                options:kNilOptions
                                                                  error:nil];

    invocationRequest.clientContext = [[AWSClientContext new] base64EncodedJSONString];

    [[[lambda invoke:invocationRequest] continueWithBlock:^id(AWSTask *task) {
        XCTAssertNil(task.error);
        XCTAssertNotNil(task.result);
        AWSLambdaInvocationResponse *invocationResponse = task.result;
        XCTAssertTrue([invocationResponse.payload isKindOfClass:[NSDictionary class]]);
        NSDictionary *result = invocationResponse.payload;
        XCTAssertEqualObjects(@"testInvokeFunction2", result[@"firstName"]);
        return nil;
    }] waitUntilFinished];
}

- (void)testInvokeWithVersion {
    NSString *associatedVersion = [AWSTestUtility getIntegrationTestConfigurationValueForPackageId:@"lambda"
                                                                                         configKey:@"version_alias_associated_version"];
    AWSLambda *lambda = [AWSLambda defaultLambda];
    AWSLambdaInvocationRequest *invocationRequest = [AWSLambdaInvocationRequest new];
    invocationRequest.functionName = [self echo_function_name];
    invocationRequest.qualifier = associatedVersion;
    invocationRequest.invocationType = AWSLambdaInvocationTypeRequestResponse;
    NSDictionary *parameters = @{@"key1" : @"value1",
                                 @"key2" : @"value2",
                                 @"key3" : @"value3",
                                 @"isError" : @NO};
    invocationRequest.payload = [NSJSONSerialization dataWithJSONObject:parameters
                                                                options:kNilOptions
                                                                  error:nil];
    invocationRequest.clientContext = [[AWSClientContext new] base64EncodedJSONString];

    [[[lambda invoke:invocationRequest] continueWithBlock:^id(AWSTask *task) {
        XCTAssertNil(task.error);
        XCTAssertNotNil(task.result);
        AWSLambdaInvocationResponse *invocationResponse = task.result;
        XCTAssertTrue([invocationResponse.payload isKindOfClass:[NSDictionary class]]);
        XCTAssertEqualObjects(invocationResponse.executedVersion, associatedVersion);
        return nil;
    }] waitUntilFinished];
}

- (void)testInvokeWithVersionAlias {
    NSString *versionAliasName = [AWSTestUtility getIntegrationTestConfigurationValueForPackageId:@"lambda"
                                                                                        configKey:@"version_alias_name"];
    NSString *versionAliasAssociatedVersion = [AWSTestUtility getIntegrationTestConfigurationValueForPackageId:@"lambda"
                                                                                                     configKey:@"version_alias_associated_version"];
    AWSLambda *lambda = [AWSLambda defaultLambda];
    AWSLambdaInvocationRequest *invocationRequest = [AWSLambdaInvocationRequest new];
    invocationRequest.functionName = [self echo_function_name];
    invocationRequest.qualifier = versionAliasName;
    invocationRequest.invocationType = AWSLambdaInvocationTypeRequestResponse;
    NSDictionary *parameters = @{@"key1" : @"value1",
                                 @"key2" : @"value2",
                                 @"key3" : @"value3",
                                 @"isError" : @NO};
    invocationRequest.payload = [NSJSONSerialization dataWithJSONObject:parameters
                                                                options:kNilOptions
                                                                  error:nil];
    invocationRequest.clientContext = [[AWSClientContext new] base64EncodedJSONString];
    
    [[[lambda invoke:invocationRequest] continueWithBlock:^id(AWSTask *task) {
        XCTAssertNil(task.error);
        XCTAssertNotNil(task.result);
        AWSLambdaInvocationResponse *invocationResponse = task.result;
        XCTAssertTrue([invocationResponse.payload isKindOfClass:[NSDictionary class]]);
        XCTAssertEqualObjects(invocationResponse.executedVersion, versionAliasAssociatedVersion);
        return nil;
    }] waitUntilFinished];
}

@end

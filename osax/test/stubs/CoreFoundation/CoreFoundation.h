// Minimal stand-in for the unit test of the payload (osax/test/payload_test.c):
// only what payload.m uses, so the test builds without the macOS SDK.
#pragma once
typedef const void *CFTypeRef;
void CFRelease(CFTypeRef cf);

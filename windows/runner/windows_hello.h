#ifndef RUNNER_WINDOWS_HELLO_H_
#define RUNNER_WINDOWS_HELLO_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <string>

// The Windows half of the optional app lock (lib/services/app_lock.dart,
// WindowsHelloAppLock): Windows Hello through UserConsentVerifier, on the
// "com.dhivalabs.secure_shell_go/app_lock" channel, answering with the same
// strings as the Android bridge (AppLockBridge.kt).
//
//  - "support"      -> "available" | "noDeviceCredential" | "unavailable"
//  - "authenticate" -> "success" | "failed" | "cancelled" | "lockedOut" |
//                      "unavailable"
//
// Fails closed. "unavailable" from "authenticate" opens the lock screen, so it
// is answered only when Hello itself says there is nothing to verify against
// (not set up, or switched off by policy). Anything else that stops the
// prompt — an exception, a failed HRESULT, a busy device, a second request
// while one is showing — answers "cancelled", which keeps the lock up with
// its Unlock button live.
//
// The WinRT calls complete on a thread-pool thread, and a MethodResult may
// only be answered on the platform thread, so each answer is posted back to
// the window as kReplyMessage and delivered from FlutterWindow's window
// procedure through HandleReply. Only the window handle, a request id and an
// answer code cross threads; nothing that this object owns does, so a reply
// arriving after it is gone is simply dropped.
class WindowsHello {
 public:
  // Posted to the window with wparam = request id, lparam = Answer.
  static constexpr UINT kReplyMessage = WM_APP + 0x51;

  WindowsHello(flutter::BinaryMessenger* messenger, HWND window);
  ~WindowsHello();

  WindowsHello(const WindowsHello&) = delete;
  WindowsHello& operator=(const WindowsHello&) = delete;

  // Call from the window procedure. Returns true when |message| was a reply
  // for this object, and has been delivered.
  bool HandleReply(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  enum Answer : LPARAM {
    kAvailable = 1,
    kNoDeviceCredential,
    kSupportUnavailable,
    kSuccess,
    kFailed,
    kCancelled,
    kLockedOut,
    kUnavailable,
  };

  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<Result> result);

  void Support(int64_t id);
  void Authenticate(int64_t id, const std::wstring& reason);

  // Keeps |result| until its answer comes back; returns the id to post with.
  int64_t Remember(std::unique_ptr<Result> result);

  static const char* AnswerString(LPARAM answer);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  int64_t next_id_ = 1;
  std::map<int64_t, std::unique_ptr<Result>> pending_;

  // The id of the prompt on screen, or 0. Guards against a second prompt.
  int64_t authenticating_ = 0;
};

#endif  // RUNNER_WINDOWS_HELLO_H_

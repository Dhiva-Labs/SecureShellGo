#include "windows_hello.h"

// Classic COM first, so C++/WinRT can hand out com_ptr for the interop
// interface below.
#include <unknwn.h>

#include <UserConsentVerifierInterop.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Security.Credentials.UI.h>

#include <utility>

namespace {

namespace wf = winrt::Windows::Foundation;
namespace ui = winrt::Windows::Security::Credentials::UI;

constexpr char kChannelName[] = "com.dhivalabs.secure_shell_go/app_lock";

// The prompt's message when Dart sends none.
constexpr wchar_t kDefaultReason[] = L"Unlock SecureShell Go";

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
      static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(static_cast<size_t>(length), L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                        static_cast<int>(utf8.size()), utf16.data(), length);
  return utf16;
}

}  // namespace

WindowsHello::WindowsHello(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<Result> result) {
        HandleMethodCall(call, std::move(result));
      });
}

WindowsHello::~WindowsHello() {
  channel_->SetMethodCallHandler(nullptr);
  // A Dart future still waiting would otherwise wait forever, and with it
  // the lock screen's spinner. "cancelled", never "unavailable": see the
  // header.
  for (auto& entry : pending_) {
    entry.second->Success(flutter::EncodableValue(AnswerString(kCancelled)));
  }
  pending_.clear();
}

void WindowsHello::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<Result> result) {
  const std::string& method = call.method_name();
  if (method == "support") {
    Support(Remember(std::move(result)));
    return;
  }
  if (method == "authenticate") {
    if (authenticating_ != 0) {
      // Already showing. Nothing was tried, so nothing failed.
      result->Success(flutter::EncodableValue(AnswerString(kCancelled)));
      return;
    }
    std::wstring reason = kDefaultReason;
    if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
      const auto found = args->find(flutter::EncodableValue("reason"));
      if (found != args->end()) {
        if (const auto* text = std::get_if<std::string>(&found->second)) {
          const std::wstring converted = Utf16FromUtf8(*text);
          if (!converted.empty()) {
            reason = converted;
          }
        }
      }
    }
    const int64_t id = Remember(std::move(result));
    authenticating_ = id;
    Authenticate(id, reason);
    return;
  }
  // "setSecure" included: Windows needs no screenshot flag. Taskbar and
  // Alt+Tab previews are live, so they show the lock screen once it is up,
  // unlike Android's recent-apps snapshot; and blocking capture would black
  // the window out of every screen share for anyone with the lock on.
  result->NotImplemented();
}

int64_t WindowsHello::Remember(std::unique_ptr<Result> result) {
  const int64_t id = next_id_++;
  pending_[id] = std::move(result);
  return id;
}

void WindowsHello::Support(int64_t id) {
  const HWND window = window_;
  try {
    // Asked here, not just when unlocking: if this Windows cannot raise the
    // window-bound prompt at all, the lock must never be offered. Offered
    // anyway, every unlock would fail closed and the lock would never open.
    auto interop = winrt::get_activation_factory<ui::UserConsentVerifier,
                                                 IUserConsentVerifierInterop>();
    if (!interop) {
      ::PostMessage(window, kReplyMessage, static_cast<WPARAM>(id),
                    kSupportUnavailable);
      return;
    }
    ui::UserConsentVerifier::CheckAvailabilityAsync().Completed(
        [window, id](
            wf::IAsyncOperation<ui::UserConsentVerifierAvailability> const&
                operation,
            wf::AsyncStatus status) {
          LPARAM answer = kSupportUnavailable;
          if (status == wf::AsyncStatus::Completed) {
            try {
              switch (operation.GetResults()) {
                case ui::UserConsentVerifierAvailability::Available:
                // Busy is a moment, not an absence: Hello is there.
                case ui::UserConsentVerifierAvailability::DeviceBusy:
                  answer = kAvailable;
                  break;
                case ui::UserConsentVerifierAvailability::DeviceNotPresent:
                case ui::UserConsentVerifierAvailability::NotConfiguredForUser:
                  answer = kNoDeviceCredential;
                  break;
                default:  // DisabledByPolicy, and anything newer.
                  answer = kSupportUnavailable;
                  break;
              }
            } catch (...) {
              answer = kSupportUnavailable;
            }
          }
          ::PostMessage(window, kReplyMessage, static_cast<WPARAM>(id), answer);
        });
  } catch (...) {
    ::PostMessage(window, kReplyMessage, static_cast<WPARAM>(id),
                  kSupportUnavailable);
  }
}

void WindowsHello::Authenticate(int64_t id, const std::wstring& reason) {
  const HWND window = window_;
  try {
    // The ...ForWindow variant through its interop interface: a desktop app
    // has no CoreWindow, and this one ties the prompt to our window so it
    // opens in front of it rather than somewhere behind.
    auto interop = winrt::get_activation_factory<ui::UserConsentVerifier,
                                                 IUserConsentVerifierInterop>();
    const winrt::hstring message(reason);
    auto operation =
        winrt::capture<wf::IAsyncOperation<ui::UserConsentVerificationResult>>(
            interop, &::IUserConsentVerifierInterop::RequestVerificationForWindowAsync,
            window, reinterpret_cast<HSTRING>(winrt::get_abi(message)));
    operation.Completed(
        [window, id](
            wf::IAsyncOperation<ui::UserConsentVerificationResult> const&
                completed,
            wf::AsyncStatus status) {
          LPARAM answer = kCancelled;
          if (status == wf::AsyncStatus::Completed) {
            try {
              switch (completed.GetResults()) {
                case ui::UserConsentVerificationResult::Verified:
                  answer = kSuccess;
                  break;
                // Hello's own retry limit, after wrong attempts. Counts
                // toward the app's cooldown, like a wrong PIN on Android.
                case ui::UserConsentVerificationResult::RetriesExhausted:
                  answer = kFailed;
                  break;
                // Nothing to verify against: Hello is not set up, or policy
                // has switched it off. The one case that opens the lock — the
                // same as Android with its screen lock removed.
                case ui::UserConsentVerificationResult::DeviceNotPresent:
                case ui::UserConsentVerificationResult::NotConfiguredForUser:
                case ui::UserConsentVerificationResult::DisabledByPolicy:
                  answer = kUnavailable;
                  break;
                default:  // Canceled, DeviceBusy, and anything newer.
                  answer = kCancelled;
                  break;
              }
            } catch (...) {
              answer = kCancelled;
            }
          }
          ::PostMessage(window, kReplyMessage, static_cast<WPARAM>(id), answer);
        });
  } catch (...) {
    // The prompt could not be raised. Stay locked.
    ::PostMessage(window, kReplyMessage, static_cast<WPARAM>(id), kCancelled);
  }
}

bool WindowsHello::HandleReply(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != kReplyMessage) {
    return false;
  }
  const auto id = static_cast<int64_t>(wparam);
  if (id == authenticating_) {
    authenticating_ = 0;
  }
  const auto found = pending_.find(id);
  if (found == pending_.end()) {
    return true;
  }
  std::unique_ptr<Result> result = std::move(found->second);
  pending_.erase(found);
  result->Success(flutter::EncodableValue(AnswerString(lparam)));
  return true;
}

const char* WindowsHello::AnswerString(LPARAM answer) {
  switch (answer) {
    case kAvailable:
      return "available";
    case kNoDeviceCredential:
      return "noDeviceCredential";
    case kSupportUnavailable:
      return "unavailable";
    case kSuccess:
      return "success";
    case kFailed:
      return "failed";
    case kLockedOut:
      return "lockedOut";
    case kUnavailable:
      return "unavailable";
    case kCancelled:
    default:
      return "cancelled";
  }
}

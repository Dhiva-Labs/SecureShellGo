import 'dart:math' as math;
import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/app_settings.dart';

/// The two shapes of pointer a layout is built for. A stylus counts as touch:
/// it has no right button worth relying on and is held like a finger.
enum PointerClass { touch, mouse }

/// What the app has seen the user's hands do: touch, a mouse or trackpad, a
/// hardware keyboard.
///
/// "Desktop" used to mean the operating system, which was wrong in both
/// directions. A Samsung DeX window, or a tablet in a keyboard cover with a
/// trackpad, is Android with a mouse and a keyboard; a Windows tablet is a
/// desktop with nothing but a finger. So layouts ask what is *in hand* — and
/// this is where the answer is kept. Until any pointer has been seen the OS
/// is still the best guess, and [resolve] falls back to it: a desktop means
/// mouse and keyboard, anything else means touch.
///
/// What has been seen stays seen for the life of the process, with two
/// exceptions: [lastPointer], and the keyboard, which lapses when the
/// on-screen keyboard opens again (see [noteSoftKeyboard]). A layout that
/// flipped every time a finger brushed a touch laptop's screen would be worse
/// than one that guessed wrong.
class InputProfile extends ChangeNotifier {
  InputProfile();

  /// The app's own, attached to the bindings by [InputProfileScope].
  static final InputProfile instance = InputProfile();

  bool _touchSeen = false;
  bool _mouseSeen = false;
  bool _keyboardSeen = false;
  bool _softKeyboardOpen = false;
  PointerClass? _lastPointer;
  bool _attached = false;

  bool get touchSeen => _touchSeen;
  bool get mouseSeen => _mouseSeen;
  bool get keyboardSeen => _keyboardSeen;

  /// The class of the most recent pointer, or null before the first.
  PointerClass? get lastPointer => _lastPointer;

  bool get attached => _attached;

  /// Starts listening to every pointer event and every hardware key event in
  /// the app. Idempotent.
  ///
  /// A global pointer route rather than a `Listener` at the top of the tree:
  /// it hears the event whoever wins it, including inside dialogs and
  /// overlays that a widget above the navigator would not sit over.
  void attach() {
    if (_attached) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handlePointer);
    HardwareKeyboard.instance.addHandler(_handleKey);
    _attached = true;
  }

  void detach() {
    if (!_attached) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handlePointer);
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _attached = false;
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }

  void _handlePointer(PointerEvent event) {
    // Added/removed arrive for a mouse the moment the cursor crosses into the
    // window, before the user has done anything with it; only an event that
    // means the pointer is being used counts.
    if (event is PointerDownEvent ||
        event is PointerHoverEvent ||
        event is PointerScrollEvent ||
        event is PointerPanZoomStartEvent) {
      notePointer(event.kind);
    }
  }

  bool _handleKey(KeyEvent event) {
    // With the on-screen keyboard up, it is the likeliest source of any key
    // there is — see [noteSoftKeyboard].
    if (!_softKeyboardOpen && isHardwareKeyEvidence(event)) noteHardwareKey();
    // Only watching: the event carries on to whoever handles it.
    return false;
  }

  /// Records a pointer of [kind] being used. Public for tests and for
  /// anything that learns of a pointer some other way.
  void notePointer(PointerDeviceKind kind) {
    final pointer = classify(kind);
    if (pointer == null) return;
    final wasTouch = _touchSeen;
    final wasMouse = _mouseSeen;
    final wasLast = _lastPointer;
    switch (pointer) {
      case PointerClass.touch:
        _touchSeen = true;
      case PointerClass.mouse:
        _mouseSeen = true;
    }
    _lastPointer = pointer;
    if (wasTouch != _touchSeen ||
        wasMouse != _mouseSeen ||
        wasLast != _lastPointer) {
      notifyListeners();
    }
  }

  /// Records a key typed on a hardware keyboard.
  void noteHardwareKey() {
    if (_keyboardSeen) return;
    _keyboardSeen = true;
    notifyListeners();
  }

  /// Records the on-screen keyboard opening or closing. [InputProfileScope]
  /// calls this from the view's insets.
  ///
  /// The keys [isHardwareKeyEvidence] trusts are the ones a phone's keyboard
  /// does not send — but the soft keyboards made for terminals do. Hacker's
  /// Keyboard and Unexpected Keyboard send Esc, Tab, Ctrl, the arrows and
  /// the function keys as key events, exactly as a hardware keyboard would,
  /// and nothing in a [KeyEvent] tells the two apart. So while one is on
  /// screen no key counts, and opening one lets the keyboard seen before
  /// lapse: whoever is typing has gone back to the glass. The next key from a
  /// real keyboard, with the on-screen one away, brings it straight back.
  void noteSoftKeyboard(bool open) {
    if (open == _softKeyboardOpen) return;
    _softKeyboardOpen = open;
    if (open && _keyboardSeen) {
      _keyboardSeen = false;
      notifyListeners();
    }
  }

  /// Forgets everything seen, back to the OS fallback. For tests.
  @visibleForTesting
  void reset() {
    _touchSeen = false;
    _mouseSeen = false;
    _keyboardSeen = false;
    _softKeyboardOpen = false;
    _lastPointer = null;
    notifyListeners();
  }

  static PointerClass? classify(PointerDeviceKind kind) => switch (kind) {
        PointerDeviceKind.touch ||
        PointerDeviceKind.stylus ||
        PointerDeviceKind.invertedStylus =>
          PointerClass.touch,
        PointerDeviceKind.mouse ||
        PointerDeviceKind.trackpad =>
          PointerClass.mouse,
        PointerDeviceKind.unknown => null,
      };

  /// Whether [event] could only have come from a hardware keyboard.
  ///
  /// Soft keyboards commit text through the IME, but many of them also send
  /// a few keys as key events — Backspace, Enter, the arrows of a space-bar
  /// cursor swipe — and Android delivers volume and back buttons the same
  /// way. None of those prove a keyboard, so this counts only what a phone's
  /// own keyboard never sends: a printable character, a modifier, Escape,
  /// Tab, the function and paging keys. A terminal user's soft keyboard
  /// sends those too, which is why nothing counts while one is open — see
  /// [noteSoftKeyboard]. A false positive is cheap anyway: the key bar comes
  /// back the moment the soft keyboard opens, see [InputDevices.showsKeyBar].
  static bool isHardwareKeyEvidence(KeyEvent event) {
    if (event is! KeyDownEvent || event.synthesized) return false;
    if (event.deviceType != KeyEventDeviceType.keyboard) return false;
    final character = event.character;
    if (character != null &&
        character.isNotEmpty &&
        character.trim().isNotEmpty &&
        character.codeUnitAt(0) >= 0x20) {
      return true;
    }
    return _keyboardOnlyKeys.contains(event.logicalKey);
  }

  static final Set<LogicalKeyboardKey> _keyboardOnlyKeys = {
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.insert,
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  };

  /// What a screen on [platform] should assume, given what has been seen.
  InputDevices resolve(
    TargetPlatform platform, {
    bool softKeyboardOpen = false,
  }) {
    final desktop = switch (platform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows =>
        true,
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia =>
        false,
    };
    final anyPointer = _touchSeen || _mouseSeen;
    return InputDevices(
      touch: anyPointer ? _touchSeen : !desktop,
      mouse: anyPointer ? _mouseSeen : desktop,
      // A desktop keeps its keyboard until a finger is the only pointer it
      // has seen — a Windows tablet, not a laptop someone touched once.
      keyboard: _keyboardSeen || (desktop && (_mouseSeen || !_touchSeen)),
      pointer: _lastPointer ??
          (desktop ? PointerClass.mouse : PointerClass.touch),
      softKeyboardOpen: softKeyboardOpen,
    );
  }

  /// The devices in hand for the screen at [context], rebuilding it when they
  /// change.
  ///
  /// With no [InputProfileScope] above — widget tests, mostly — nothing has
  /// been seen, so this is the OS fallback for the theme's platform: the same
  /// answer the old platform checks gave, which is what keeps those tests
  /// meaning what they meant.
  static InputDevices of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_InputProfileInherited>();
    final platform = Theme.of(context).platform;
    if (scope == null) return _unseen.resolve(platform);
    return scope.notifier!.resolve(
      platform,
      softKeyboardOpen: scope.softKeyboardOpen,
    );
  }

  static final InputProfile _unseen = InputProfile();
}

/// A snapshot of [InputProfile] for one platform: what to lay a screen out
/// for.
@immutable
class InputDevices {
  const InputDevices({
    required this.touch,
    required this.mouse,
    required this.keyboard,
    required this.pointer,
    this.softKeyboardOpen = false,
  });

  /// Touch has been seen (or nothing has, on a phone or tablet): every
  /// control needs a 48dp target.
  final bool touch;

  /// A mouse or trackpad has been seen (or nothing has, on a desktop):
  /// right-click menus, split panes and drag-and-drop are worth offering.
  final bool mouse;

  /// A hardware keyboard has been typed on (or this is a desktop that touch
  /// has not shown to be a tablet): fields can take focus as they appear,
  /// shortcuts are worth naming, and the extra-keys rows can go.
  final bool keyboard;

  /// The kind of pointer used last.
  final PointerClass pointer;

  /// The on-screen keyboard is up. Typing on glass whatever else is
  /// attached — so the extra-keys row belongs on screen with it.
  final bool softKeyboardOpen;

  /// Whether a row of extra keys (the terminal's Esc/Tab/Ctrl, the editor's
  /// brackets) should show under [mode].
  bool showsKeyBar(KeyBarMode mode) => switch (mode) {
        KeyBarMode.always => true,
        KeyBarMode.never => false,
        KeyBarMode.auto => !keyboard || softKeyboardOpen,
      };

  @override
  bool operator ==(Object other) =>
      other is InputDevices &&
      other.touch == touch &&
      other.mouse == mouse &&
      other.keyboard == keyboard &&
      other.pointer == pointer &&
      other.softKeyboardOpen == softKeyboardOpen;

  @override
  int get hashCode =>
      Object.hash(touch, mouse, keyboard, pointer, softKeyboardOpen);

  @override
  String toString() => 'InputDevices(touch: $touch, mouse: $mouse, '
      'keyboard: $keyboard, pointer: ${pointer.name}, '
      'softKeyboardOpen: $softKeyboardOpen)';
}

/// Puts an [InputProfile] in reach of [InputProfile.of] for everything below,
/// and gives every Material control a 48dp target once touch has been seen.
///
/// Goes in `MaterialApp.builder`, above the navigator, so every route and
/// dialog is under it. With no [profile] it uses [InputProfile.instance] and
/// attaches it to the bindings; a test hands in its own and drives it.
class InputProfileScope extends StatefulWidget {
  const InputProfileScope({super.key, this.profile, required this.child});

  final InputProfile? profile;
  final Widget child;

  /// Insets taller than this are a soft keyboard. Shorter ones are the strip
  /// some Android keyboards keep on screen while a hardware keyboard is
  /// connected — a language switcher, not something to type on.
  static const double softKeyboardMinHeight = 100;

  @override
  State<InputProfileScope> createState() => _InputProfileScopeState();
}

class _InputProfileScopeState extends State<InputProfileScope> {
  InputProfile get _profile => widget.profile ?? InputProfile.instance;

  ThemeData? _base;
  ThemeData? _touchTheme;

  /// What [InputProfile.noteSoftKeyboard] was last told, or is about to be.
  bool? _softKeyboardNoted;

  @override
  void initState() {
    super.initState();
    if (widget.profile == null) InputProfile.instance.attach();
  }

  @override
  void didUpdateWidget(InputProfileScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.profile == null) InputProfile.instance.attach();
    if (widget.profile != oldWidget.profile) _softKeyboardNoted = null;
  }

  /// [base] with the targets touch needs: padded tap targets, and no
  /// compact density, which would take 8dp back off them. Cached, because
  /// this rebuilds on every frame of the soft keyboard sliding in.
  ///
  /// This is where the AWS style's tight console density goes on a touch
  /// screen, and that is meant: a control a finger misses is worse than a
  /// looser layout. Rows of a fixed height that hold buttons grow with them
  /// rather than clipping the target to the row.
  ThemeData _forTouch(ThemeData base) {
    if (!identical(base, _base)) {
      _base = base;
      final density = base.visualDensity;
      _touchTheme = base.copyWith(
        materialTapTargetSize: MaterialTapTargetSize.padded,
        visualDensity: VisualDensity(
          horizontal: math.max(0, density.horizontal),
          vertical: math.max(0, density.vertical),
        ),
      );
    }
    return _touchTheme!;
  }

  void _noteSoftKeyboard(bool open) {
    if (open == _softKeyboardNoted) return;
    _softKeyboardNoted = open;
    final profile = _profile;
    // After the frame: a keyboard that lapses notifies the profile's
    // listeners, and this is the middle of a build. Nothing is lost by the
    // wait — a soft keyboard sends no keys in the frame it first appears.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => profile.noteSoftKeyboard(open));
  }

  @override
  Widget build(BuildContext context) {
    final softKeyboardOpen = (MediaQuery.maybeViewInsetsOf(context)?.bottom ??
            0) >
        InputProfileScope.softKeyboardMinHeight;
    _noteSoftKeyboard(softKeyboardOpen);
    return _InputProfileInherited(
      notifier: _profile,
      softKeyboardOpen: softKeyboardOpen,
      child: ListenableBuilder(
        listenable: _profile,
        child: widget.child,
        builder: (context, child) {
          final theme = Theme.of(context);
          final touch = _profile.resolve(theme.platform).touch;
          // A Theme either way: swapping the wrapper in and out would move
          // the navigator to a new place in the tree and lose every route.
          return Theme(data: touch ? _forTouch(theme) : theme, child: child!);
        },
      ),
    );
  }
}

class _InputProfileInherited extends InheritedNotifier<InputProfile> {
  const _InputProfileInherited({
    required super.notifier,
    required this.softKeyboardOpen,
    required super.child,
  });

  final bool softKeyboardOpen;

  @override
  bool updateShouldNotify(_InputProfileInherited oldWidget) =>
      oldWidget.softKeyboardOpen != softKeyboardOpen ||
      super.updateShouldNotify(oldWidget);
}

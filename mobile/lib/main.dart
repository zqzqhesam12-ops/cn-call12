import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'firebase_options.dart';

import 'services/call_session.dart';
import 'services/firebase_messaging_service.dart';
import 'services/account_api.dart';
import 'services/rtc_call_manager.dart';

import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _telecomChannel = MethodChannel('cn_call/call');
const MethodChannel _telecomEventsChannel =
    MethodChannel('cn_call/telecom_events');

enum CnSetupState { unconfigured, checking, ready }

const _cnSetupPrefKey = 'cn_call_setup_complete_v1';
const String _cnCallDeveloperPhone = '780331040';

void _installTelecomEventHandler() {
  _telecomEventsChannel.setMethodCallHandler((call) async {
    final arguments = Map<Object?, Object?>.from(call.arguments as Map);
    // Android uses this event only to wake/bring the Flutter activity forward.
    // Rendering and all call decisions remain in Flutter; it must never create
    // a Telecom/InCallUI call.
    if (call.method == 'muteChanged') {
      final callId = arguments['callId']?.toString() ?? '';
      if (callId.isNotEmpty && RtcCallManager.instance.currentCallId == callId) {
        await RtcCallManager.instance.mute(arguments['isMuted'] == true);
      }
      return;
    }
    if (call.method == 'active') {
      // Native Telecom call reached ACTIVE (media ready); keep the in-app
      // CallScreen bound to the same native call â€” no Flutter LiveKit of its
      // own for this callId.
      final callId = arguments['callId']?.toString() ?? '';
      if (callId.isNotEmpty) {
        await RtcCallManager.instance.onNativeCallActive();
      }
      return;
    }
    if (call.method == 'ended') {
      // Native Telecom call ended (setDisconnected already reached; the single
      // terminal frame was sent by the native engine). Flutter mirrors local
      // state only.
      final callId = arguments['callId']?.toString() ?? '';
      if (callId.isNotEmpty) {
        await RtcCallManager.instance.handleNativeCallEnded(callId);
      }
      return;
    }
  });
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  _installTelecomEventHandler();

  RtcCallManager.instance.startListening();

  runApp(const CNCallApp());
}

class CNCallApp extends StatefulWidget {
  const CNCallApp({super.key});

  @override
  State<CNCallApp> createState() => _CNCallAppState();
}

class _CNCallAppState extends State<CNCallApp> {
  bool _loading = true;
  bool _hasSession = false;

  @override
  void initState() {
    super.initState();

    CallSession.instance.onSessionInvalidated = _handleSessionInvalidated;
    _restoreSession();
  }

  void _handleSessionInvalidated() {
    if (!mounted) return;
    setState(() {
      _hasSession = false;
    });
  }

  @override
  void dispose() {
    CallSession.instance.onSessionInvalidated = null;
    super.dispose();
  }

  Future<void> _restoreSession() async {
    // Fresh isolate: no live Flutter call can exist yet, so a lingering
    // `flutter` WS-owner marker or active-call marker from a previous process
    // (crash / OS kill mid-call) is stale. Clear it BEFORE restoreSession's
    // socket.connect() so the next native acquisition/call is never refused.
    await CallSession.instance.clearStaleStateForFreshStartup();

    final restored = await CallSession.instance.restoreSession();

    if (restored) {
      await FirebaseMessagingService.instance.refreshTokenForCurrentUser();
    }

    if (!mounted) return;

    setState(() {
      _hasSession = restored;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CN CALL',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF050505),
        useMaterial3: true,
      ),
      home: _loading
          ? const Scaffold(
              body: Center(
                child: CircularProgressIndicator(color: Color(0xFF00E676)),
              ),
            )
          : _hasSession
          ? const HomeScreen()
          : const LoginScreen(),
    );
  }
}

// ============================================================
// LOGIN
// ============================================================

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with WidgetsBindingObserver {
  final userIdController = TextEditingController();
  final passwordController = TextEditingController();

  bool hidePassword = true;

  CnSetupState _setupState = CnSetupState.checking;
  bool _phoneAccountEnabled = false;
  bool _hasPromptedPhoneAccount = false;
  bool _setupCheckInProgress = false;
  bool _startupPermissionFlowStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _startupPermissionFlowStarted) return;
      _startupPermissionFlowStarted = true;
      _runStartupPermissionFlow();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    userIdController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _verifySetup();
    }
  }

  Future<void> _verifySetup() async {
    if (_setupCheckInProgress) return;
    _setupCheckInProgress = true;
    if (mounted) setState(() => _setupState = CnSetupState.checking);

    var hasPermission = true;
    try {
      hasPermission =
          await _telecomChannel.invokeMethod<bool>('hasStartupPermissions') ??
          false;
    } on PlatformException {
      hasPermission = false;
    }

    var accountEnabled = false;
    if (hasPermission) {
      try {
        await _telecomChannel.invokeMethod<bool>('registerCNCallPhoneAccount');
      } on PlatformException {
        // Registration is best-effort; enablement is what gates the login.
      }
      try {
        accountEnabled =
            await _telecomChannel.invokeMethod<bool>(
                  'isCNCallPhoneAccountEnabled',
                ) ??
                false;
      } on PlatformException {
        accountEnabled = false;
      }
    }

    _setupCheckInProgress = false;
    if (!mounted) return;

    if (hasPermission && accountEnabled) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_cnSetupPrefKey, true);
      if (!mounted) return;
      setState(() {
        _setupState = CnSetupState.ready;
        _phoneAccountEnabled = true;
      });
    } else {
      setState(() {
        _phoneAccountEnabled = accountEnabled;
        _setupState = CnSetupState.unconfigured;
      });
    }
  }

  Future<void> _runStartupPermissionFlow() async {
    try {
      await _telecomChannel.invokeMethod<bool>('requestStartupPermissions');
    } on PlatformException {
      // _verifySetup reports the incomplete permission state and setup can retry.
    }
    // Start Firebase initialization without blocking the Phone Account setup UI.
    // The initialization continues in parallel while Telecom setup is verified.
    final firebaseInitialization =
        FirebaseMessagingService.instance.initialize();

    if (mounted) {
      await _verifySetup();

      var hasPermissions = false;
      try {
        hasPermissions =
            await _telecomChannel.invokeMethod<bool>('hasStartupPermissions') ??
            false;
      } on PlatformException {
        hasPermissions = false;
      }

      if (hasPermissions && !_phoneAccountEnabled && !_hasPromptedPhoneAccount) {
        _hasPromptedPhoneAccount = true;
        _showPhoneAccountDialog();
      }
    }

    // Preserve startup initialization completion without delaying the popup.
    await firebaseInitialization;
  }
  void _showPhoneAccountDialog() {
    if (!mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.grey.shade800),
          ),
          title: const Row(
            children: [
              Icon(
                Icons.phone_in_talk_outlined,
                color: Color(0xFF00E676),
                size: 24,
              ),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'تفعيل حساب CN CALL للمكالمات',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          content: const Text(
            'يلزم تفعيل "حساب المكالمات" لـ CN CALL من إعدادات النظام لضمان استقبال وإجراء المكالمات عبر واجهة الهاتف الرسمية.',
            style: TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _configurePhoneAccount();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A85A),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'تفعيل الحساب',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _configurePhoneAccount() async {
    try {
      await _telecomChannel.invokeMethod<bool>('registerCNCallPhoneAccount');
      final enabled =
          await _telecomChannel.invokeMethod<bool>(
                'isCNCallPhoneAccountEnabled',
              ) ??
              false;

      if (!mounted) return;
      setState(() {
        _phoneAccountEnabled = enabled;
      });

      if (!enabled) {
        await _telecomChannel.invokeMethod<bool>('openTelecomCallSettings');
      } else {
        _message('حساب CN CALL مفعّل', success: true);
      }
    } on PlatformException catch (error) {
      if (!mounted) return;
      _message('تعذر إعداد Phone Account: ${error.message ?? error.code}');
    }
  }

  void openRegister() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RegisterScreen()),
    );
  }

  Future<void> login() async {
    if (_setupState != CnSetupState.ready) {
      _message('أكمل إعداد CN CALL أولًا ثم سجّل الدخول');
      return;
    }

    final userId = userIdController.text.trim();
    final password = passwordController.text;

    if (userId.isEmpty) {
      _message('أدخل ID المستخدم');
      return;
    }

    if (int.tryParse(userId) == null) {
      _message('ID المستخدم يجب أن يكون أرقامًا فقط');
      return;
    }

    if (password.isEmpty) {
      _message('أدخل كلمة المرور');
      return;
    }

    final result = await AccountApi.login(userId: userId, password: password);

    if (!mounted) return;

    final success = result['success'] == true;

    if (!success) {
      _message(
        result['message']?.toString() ?? 'ID المستخدم أو كلمة المرور غير صحيحة',
      );
      return;
    }

    final user = result['user'];

    if (user is! Map) {
      _message('بيانات المستخدم غير صالحة');
      return;
    }

    final loggedUserId = user['user_id']?.toString();
    final username = user['username']?.toString();
    final accessToken = result['access_token']?.toString();
    final isDeveloper = user['is_developer'] == true;
    final developerBadge = user['developer_badge']?.toString().trim();

    if (loggedUserId == null ||
        loggedUserId.isEmpty ||
        username == null ||
        username.isEmpty ||
        accessToken == null ||
        accessToken.isEmpty) {
      _message('بيانات المستخدم ناقصة');
      return;
    }

    await CallSession.instance.login(
      id: loggedUserId,
      name: username,
      token: accessToken,
      isDeveloper: isDeveloper,
      developerBadge: developerBadge,
    );

    await FirebaseMessagingService.instance.refreshTokenForCurrentUser();

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
  }

  void _message(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: success
            ? const Color(0xFF00A85A)
            : Colors.red.shade800,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF050505),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 40,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Column(
                  children: [
                    _Logo(),

                    const SizedBox(height: 24),

                    const Text(
                      'CN CALL',
                      style: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),

                    const SizedBox(height: 8),

                    Text(
                      'مكالمات صوتية بدون أرقام هاتف',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 14,
                      ),
                    ),

                    const SizedBox(height: 42),

                    _Field(
                      controller: userIdController,
                      label: 'ID المستخدم',
                      hint: 'أدخل ID المستخدم',
                      icon: Icons.badge_outlined,
                      keyboardType: TextInputType.number,
                    ),

                    const SizedBox(height: 16),

                    _Field(
                      controller: passwordController,
                      label: 'كلمة المرور',
                      hint: 'أدخل كلمة المرور',
                      icon: Icons.lock_outline,
                      obscureText: hidePassword,
                      suffix: IconButton(
                        onPressed: () {
                          setState(() {
                            hidePassword = !hidePassword;
                          });
                        },
                        icon: Icon(
                          hidePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    _PrimaryButton(
                      text: 'تسجيل الدخول',
                      onPressed: login,
                    ),

                    const SizedBox(height: 12),

                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton(
                        onPressed: openRegister,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.grey.shade800),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        child: const Text(
                          'إنشاء حساب جديد',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 28),

                    _Footer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// HOME
// ============================================================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final callIdController = TextEditingController();

  final List<Map<String, String>> _contacts = [];
  final List<Map<String, dynamic>> _callHistory = [];

  bool _loadingData = true;
  Timer? _registrationPollTimer;
  bool _registrationFetchInProgress = false;
  bool _registrationDialogOpen = false;
  bool _registrationDecisionBusy = false;
  final Set<String> _notifiedRegistrationRequestIds = <String>{};
  List<Map<String, dynamic>> _pendingRegistrationRequests = [];

  @override
  void initState() {
    super.initState();

    _loadLocalData();
    _loadMissedCalls();

    if (CallSession.instance.isDeveloper) {
      unawaited(_refreshRegistrationRequests(showAlert: true));
      _registrationPollTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _refreshRegistrationRequests(showAlert: true),
      );
    }

    final rtcManager = RtcCallManager.instance;
    rtcManager.startListening();

    rtcManager.onDisconnected = () {
      // Native Telecom handles incoming UI teardown.
    };

  }


  Future<void> _refreshRegistrationRequests({
    bool showAlert = false,
    bool forceAlert = false,
  }) async {
    if (!CallSession.instance.isDeveloper || _registrationFetchInProgress) return;
    _registrationFetchInProgress = true;
    try {
      final requests = await AccountApi.pendingRegistrationRequests();
      if (!mounted) return;
      setState(() {
        _pendingRegistrationRequests = requests;
      });

      if (!showAlert || _registrationDialogOpen) return;
      Map<String, dynamic>? nextRequest;
      for (final request in requests) {
        final id = request['request_id']?.toString() ?? '';
        if (id.isEmpty) continue;
        if (forceAlert || !_notifiedRegistrationRequestIds.contains(id)) {
          nextRequest = request;
          _notifiedRegistrationRequestIds.add(id);
          break;
        }
      }

      if (nextRequest != null) {
        unawaited(_showRegistrationRequestDialog(nextRequest));
      } else if (forceAlert && requests.isEmpty) {
        _message('لا توجد طلبات تسجيل جديدة قيد المراجعة');
      }
    } finally {
      _registrationFetchInProgress = false;
    }
  }

  Future<void> _showRegistrationRequestDialog(
    Map<String, dynamic> request,
  ) async {
    if (!mounted || _registrationDialogOpen) return;
    _registrationDialogOpen = true;
    final requestId = request['request_id']?.toString() ?? '';
    final userId = request['user_id']?.toString() ?? '';
    final username = request['username']?.toString() ?? 'بدون اسم';
    final requestedAt = int.tryParse(request['requested_at']?.toString() ?? '');
    final requestedTime = requestedAt == null
        ? ''
        : DateTime.fromMillisecondsSinceEpoch(requestedAt).toLocal().toString().substring(0, 16);

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: const Color(0xFF151515),
          title: const Row(
            children: [
              Icon(Icons.verified_user_outlined, color: Color(0xFF00E676)),
              SizedBox(width: 10),
              Expanded(child: Text('طلب تسجيل برقم حقيقي')),
            ],
          ),
          content: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('اسم المستخدم: $username'),
                const SizedBox(height: 8),
                SelectableText('رقم الهاتف: $userId'),
                if (requestedTime.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('وقت الطلب: $requestedTime', style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                ],
                const SizedBox(height: 12),
                const Text('لا يُنشأ الحساب إلا بعد قبولك للطلب.'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: _registrationDecisionBusy
                  ? null
                  : () => _decideRegistrationRequest(requestId, false),
              child: const Text('رفض', style: TextStyle(color: Colors.redAccent)),
            ),
            FilledButton.icon(
              onPressed: _registrationDecisionBusy
                  ? null
                  : () => _decideRegistrationRequest(requestId, true),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF00A85A)),
              icon: const Icon(Icons.check),
              label: const Text('قبول الرقم'),
            ),
          ],
        );
      },
    );

    _registrationDialogOpen = false;
    if (mounted) unawaited(_refreshRegistrationRequests(showAlert: true));
  }

  Future<void> _decideRegistrationRequest(
    String requestId,
    bool approve,
  ) async {
    if (requestId.isEmpty || _registrationDecisionBusy) return;
    setState(() => _registrationDecisionBusy = true);
    final result = await AccountApi.decideRegistrationRequest(
      requestId: requestId,
      approve: approve,
    );
    if (!mounted) return;
    setState(() => _registrationDecisionBusy = false);
    if (result['success'] == true) {
      Navigator.of(context, rootNavigator: true).pop();
      _message(
        result['message']?.toString() ?? (approve ? 'تم قبول الطلب' : 'تم رفض الطلب'),
        success: true,
      );
    } else {
      _message(result['message']?.toString() ?? 'تعذر حفظ قرار الإدارة');
    }
  }

  void _message(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: success ? const Color(0xFF00A85A) : Colors.red.shade800,
      ),
    );
  }

  Future<void> _loadLocalData() async {
    final prefs = await SharedPreferences.getInstance();

    // طھظ†ط¸ظٹظپ ط¨ظٹط§ظ†ط§طھ ط§ظ„طھط¬ط§ط±ط¨ ط§ظ„ظ‚ط¯ظٹظ…ط© ظ…ط±ط© ظˆط§ط­ط¯ط©.
    const cleanupKey = 'cn_call_real_data_cleanup_v1';
    final cleaned = prefs.getBool(cleanupKey) ?? false;

    if (!cleaned) {
      await prefs.remove('cn_call_contacts');
      await prefs.remove('cn_call_history');
      await prefs.setBool(cleanupKey, true);
    }

    final contacts = prefs.getStringList('cn_call_contacts') ?? [];

    final loadedContacts = <Map<String, String>>[];

    for (final item in contacts) {
      final parts = item.split('|');

      if (parts.length >= 2) {
        loadedContacts.add({
          'id': parts[0],
          'name': parts.sublist(1).join('|'),
        });
      }
    }

    final history = prefs.getStringList('cn_call_history') ?? [];

    final loadedHistory = <Map<String, dynamic>>[];

    for (final item in history) {
      final parts = item.split('|');

      if (parts.length >= 4) {
        loadedHistory.add({
          'id': parts[0],
          'name': parts[1],
          'incoming': parts[2] == '1',
          'time': parts.sublist(3).join('|'),
        });
      }
    }

    if (!mounted) return;

    setState(() {
      _contacts
        ..clear()
        ..addAll(loadedContacts);

      _callHistory
        ..clear()
        ..addAll(loadedHistory);

      _loadingData = false;
    });
  }

  Future<void> _loadMissedCalls() async {
    final userId = CallSession.instance.userId;
    if (userId == null || userId.isEmpty) return;

    final missed = await AccountApi.missedCalls(userId: userId);
    if (!mounted || missed.isEmpty) return;

    for (final call in missed) {
      final callerId = call['caller_id']?.toString() ?? '';
      final callerName = call['caller_name']?.toString() ?? 'مستخدم CN CALL';
      if (callerId.isEmpty) continue;
      await _addHistory(name: callerName, id: callerId, incoming: true);
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('لديك مكالمة فائتة')),
    );
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setStringList(
      'cn_call_history',
      _callHistory
          .map(
            (item) =>
                '${item['id']}|${item['name']}|${item['incoming'] == true ? '1' : '0'}|${item['time']}',
          )
          .toList(),
    );
  }

  Future<void> _addHistory({
    required String name,
    required String id,
    required bool incoming,
  }) async {
    final now = DateTime.now();

    final time =
        '${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';

    final item = <String, dynamic>{
      'id': id,
      'name': name,
      'incoming': incoming,
      'time': time,
    };

    if (mounted) {
      setState(() {
        _callHistory.insert(0, item);

        if (_callHistory.length > 50) {
          _callHistory.removeLast();
        }
      });
    }

    await _saveHistory();
  }



  @override
  void dispose() {
    _registrationPollTimer?.cancel();
    callIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF050505),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text(
            'CN CALL',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5),
          ),
          actions: [
            IconButton(
              tooltip: 'تسجيل الخروج',
              onPressed: () async {
                final navigator = Navigator.of(context);

                final shouldLogout = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) {
                    return AlertDialog(
                      backgroundColor: const Color(0xFF151515),
                      title: const Text(
                        'تسجيل الخروج',
                        textDirection: TextDirection.rtl,
                      ),
                      content: const Text(
                        'هل تريد تسجيل الخروج من الحساب الحالي؟',
                        textDirection: TextDirection.rtl,
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: const Text('إلغاء'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.red,
                          ),
                          child: const Text('تسجيل الخروج'),
                        ),
                      ],
                    );
                  },
                );

                if (shouldLogout != true || !mounted) return;

                await CallSession.instance.logout();

                if (!mounted) return;

                navigator.pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
              icon: const Icon(Icons.logout_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: _loadingData
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 30),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151515),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: const Color(0xFF00E676)
                                .withValues(alpha: .18),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 58,
                              height: 58,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF00E676)
                                    .withValues(alpha: .12),
                              ),
                              child: const Icon(
                                Icons.person,
                                color: Color(0xFF00E676),
                                size: 30,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'مرحباً بك',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    CallSession.instance.displayName ??
                                        'مستخدم CN CALL',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'ID: ${CallSession.instance.userId ?? ''}',
                                    style: const TextStyle(
                                      color: Color(0xFF00E676),
                                      fontSize: 13,
                                    ),
                                  ),
                                  if (CallSession.instance.isDeveloper &&
                                      CallSession.instance.developerBadge != null) ...[
                                    const SizedBox(height: 7),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.verified_rounded,
                                          color: Color(0xFF00E676),
                                          size: 16,
                                        ),
                                        const SizedBox(width: 5),
                                        Text(
                                          CallSession.instance.developerBadge!,
                                          style: const TextStyle(
                                            color: Color(0xFF00E676),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),
                      if (CallSession.instance.isDeveloper)
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: const Color(0xFF151515),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0xFF00E676).withValues(alpha: .30)),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.fact_check_outlined, color: Color(0xFF00E676), size: 28),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text('طلبات التسجيل', style: TextStyle(fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 3),
                                    Text(
                                      '\${_pendingRegistrationRequests.length} طلب قيد المراجعة',
                                      style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'مراجعة طلبات التسجيل',
                                onPressed: () => _refreshRegistrationRequests(
                                  showAlert: true,
                                  forceAlert: true,
                                ),
                                icon: const Icon(Icons.arrow_forward_ios, color: Color(0xFF00E676)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
          ),
        ),
      );
  }
}

// ============================================================
// REGISTER
// ============================================================

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  static const _pendingIdKey = 'cn_call_registration_request_id';
  static const _pendingTokenKey = 'cn_call_registration_request_token';
  static const _pendingPhoneKey = 'cn_call_registration_request_phone';
  static const _pendingNameKey = 'cn_call_registration_request_name';

  final userIdController = TextEditingController();
  final usernameController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  bool hidePassword = true;
  bool hideConfirmPassword = true;
  bool _useRealPhone = false;
  bool _submitting = false;
  bool _pollInProgress = false;
  bool _approvalGranted = false;
  Timer? _requestPollTimer;
  String? _pendingRequestId;
  String? _pendingRequestToken;
  String? _statusBanner;

  @override
  void initState() {
    super.initState();
    _restorePendingRequest();
  }

  Future<void> _restorePendingRequest() async {
    final prefs = await SharedPreferences.getInstance();
    final requestId = prefs.getString(_pendingIdKey);
    final requestToken = prefs.getString(_pendingTokenKey);
    if (requestId == null || requestId.isEmpty ||
        requestToken == null || requestToken.isEmpty) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _pendingRequestId = requestId;
      _pendingRequestToken = requestToken;
      _useRealPhone = true;
      userIdController.text = prefs.getString(_pendingPhoneKey) ?? '';
      usernameController.text = prefs.getString(_pendingNameKey) ?? '';
      _statusBanner = 'طلبك قيد المراجعة. أكّد رقمك من خلال الرقم أدناه.';
    });
    _startRequestPolling();
  }

  void _startRequestPolling() {
    _requestPollTimer?.cancel();
    _requestPollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _pollRegistrationStatus(),
    );
    unawaited(_pollRegistrationStatus());
  }

  @override
  void dispose() {
    _requestPollTimer?.cancel();
    userIdController.dispose();
    usernameController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> createAccount() async {
    if (_submitting) return;
    if (_pendingRequestId != null) {
      await _pollRegistrationStatus();
      return;
    }
    if (_approvalGranted) {
      await _continueAfterApproval();
      return;
    }

    final userId = userIdController.text.trim();
    final username = usernameController.text.trim();
    final password = passwordController.text;
    final confirmPassword = confirmPasswordController.text;

    if (username.isEmpty || password.isEmpty || confirmPassword.isEmpty ||
        (_useRealPhone && userId.isEmpty)) {
      _message('أكمل جميع البيانات المطلوبة');
      return;
    }

    if (_useRealPhone && !RegExp(r'^\d{9,15}$').hasMatch(userId)) {
      _message('أدخل رقم الهاتف بالأرقام فقط، من 9 إلى 15 رقمًا');
      return;
    }

    if (username.length < 3) {
      _message('اسم المستخدم يجب أن يكون 3 أحرف على الأقل');
      return;
    }

    if (password.length < 6) {
      _message('كلمة المرور يجب أن تكون 6 أحرف على الأقل');
      return;
    }

    if (password != confirmPassword) {
      _message('كلمتا المرور غير متطابقتين');
      return;
    }

    setState(() {
      _submitting = true;
      _statusBanner = null;
    });

    if (_useRealPhone) {
      final result = await AccountApi.requestPhoneRegistration(
        userId: userId,
        username: username,
        password: password,
      );
      if (!mounted) return;
      if (result['success'] != true) {
        setState(() => _submitting = false);
        _message(result['message']?.toString() ?? 'تعذر إرسال طلب الموافقة');
        return;
      }

      final requestId = result['request_id']?.toString() ?? '';
      final requestToken = result['request_token']?.toString() ?? '';
      if (requestId.isEmpty || requestToken.isEmpty) {
        setState(() => _submitting = false);
        _message('وصل رد غير مكتمل من الخادم. حاول مرة أخرى.');
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingIdKey, requestId);
      await prefs.setString(_pendingTokenKey, requestToken);
      await prefs.setString(_pendingPhoneKey, userId);
      await prefs.setString(_pendingNameKey, username);

      setState(() {
        _submitting = false;
        _pendingRequestId = requestId;
        _pendingRequestToken = requestToken;
        _statusBanner = 'تم إرسال طلبك. أكّد رقمك بالاتصال أو الرسالة أدناه، ثم انتظر الموافقة.';
      });
      _startRequestPolling();
      return;
    }

    final result = await AccountApi.registerUnique(
      username: username,
      password: password,
    );
    if (!mounted) return;
    if (result['success'] != true) {
      setState(() => _submitting = false);
      _message(result['message']?.toString() ?? 'تعذر إنشاء الحساب');
      return;
    }

    final allocatedId = result['user_id']?.toString() ?? '';
    if (!RegExp(r'^79\d{7}$').hasMatch(allocatedId)) {
      setState(() => _submitting = false);
      _message('أنشأ الخادم حسابًا لكن الرقم المستلم غير صالح. تواصل مع الإدارة.');
      return;
    }

    await _completeLogin(
      userId: allocatedId,
      password: password,
      fallbackName: username,
      successMessage: 'تم إنشاء الحساب. رقمك الفريد: $allocatedId',
    );
  }

  Future<void> _pollRegistrationStatus() async {
    if (_pollInProgress || _pendingRequestId == null ||
        _pendingRequestToken == null) {
      return;
    }
    _pollInProgress = true;
    try {
      final result = await AccountApi.registrationRequestStatus(
        requestId: _pendingRequestId!,
        requestToken: _pendingRequestToken!,
      );
      if (!mounted || result['success'] != true) return;

      final status = result['status']?.toString() ?? 'pending';
      if (status == 'pending' || status == 'processing') {
        if (_statusBanner == null ||
            !_statusBanner!.contains('قيد المراجعة')) {
          setState(() {
            _statusBanner = 'طلبك قيد المراجعة. انتظر موافقة الإدارة داخل التطبيق.';
          });
        }
        return;
      }

      _requestPollTimer?.cancel();
      _requestPollTimer = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_pendingIdKey);
      await prefs.remove(_pendingTokenKey);
      await prefs.remove(_pendingPhoneKey);
      await prefs.remove(_pendingNameKey);

      if (status == 'approved') {
        final approvedId = result['user_id']?.toString() ?? userIdController.text.trim();
        setState(() {
          _pendingRequestId = null;
          _pendingRequestToken = null;
          _approvalGranted = true;
          _statusBanner = 'وافقت الإدارة على الرقم $approvedId. أدخل كلمة المرور لإكمال تسجيل الدخول.';
          userIdController.text = approvedId;
          _useRealPhone = true;
        });
        if (passwordController.text.isNotEmpty) {
          await _continueAfterApproval();
        }
      } else if (status == 'rejected') {
        setState(() {
          _pendingRequestId = null;
          _pendingRequestToken = null;
          _approvalGranted = false;
          _statusBanner = result['message']?.toString() ?? 'تم رفض طلب الرقم من الإدارة.';
        });
        _message(_statusBanner!);
      }
    } finally {
      _pollInProgress = false;
    }
  }

  Future<void> _continueAfterApproval() async {
    final userId = userIdController.text.trim();
    final password = passwordController.text;
    final username = usernameController.text.trim();
    if (userId.isEmpty || password.isEmpty) {
      _message('تمت الموافقة. أدخل رقم الهاتف وكلمة المرور لإكمال الدخول.');
      return;
    }
    setState(() => _submitting = true);
    await _completeLogin(
      userId: userId,
      password: password,
      fallbackName: username,
      successMessage: 'تم قبول رقم الهاتف وتسجيل الدخول بنجاح',
    );
  }

  Future<void> _completeLogin({
    required String userId,
    required String password,
    required String fallbackName,
    required String successMessage,
  }) async {
    final loginResult = await AccountApi.login(
      userId: userId,
      password: password,
    );
    if (!mounted) return;

    if (loginResult['success'] != true) {
      setState(() => _submitting = false);
      _message(
        loginResult['message']?.toString() ??
            'تم تجهيز الحساب، لكن تعذر تسجيل الدخول. استخدم الرقم وكلمة المرور.',
      );
      return;
    }

    final user = loginResult['user'];
    if (user is! Map) {
      setState(() => _submitting = false);
      _message('بيانات المستخدم غير صالحة');
      return;
    }

    final loggedUserId = user['user_id']?.toString();
    final loggedUsername = user['username']?.toString() ?? fallbackName;
    final accessToken = loginResult['access_token']?.toString();
    final isDeveloper = user['is_developer'] == true;
    final developerBadge = user['developer_badge']?.toString().trim();

    if (loggedUserId == null || loggedUserId.isEmpty ||
        accessToken == null || accessToken.isEmpty) {
      setState(() => _submitting = false);
      _message('بيانات الجلسة ناقصة');
      return;
    }

    await CallSession.instance.login(
      id: loggedUserId,
      name: loggedUsername,
      token: accessToken,
      isDeveloper: isDeveloper,
      developerBadge: developerBadge,
    );
    await FirebaseMessagingService.instance.refreshTokenForCurrentUser();
    if (!mounted) return;

    _requestPollTimer?.cancel();
    _requestPollTimer = null;
    _message(successMessage, success: true);
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const HomeScreen()),
      (route) => false,
    );
  }

  void _message(String text, {bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: success
            ? const Color(0xFF00A85A)
            : Colors.red.shade800,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pending = _pendingRequestId != null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF050505),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 40),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 430),
                child: Column(
                  children: [
                    _Logo(),
                    const SizedBox(height: 22),
                    const Text(
                      'إنشاء حساب',
                      style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'اختر طريقة الحصول على رقم CN CALL',
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF151515),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: Colors.grey.shade800),
                      ),
                      child: Column(
                        children: [
                          RadioListTile<bool>(
                            value: false,
                            groupValue: _useRealPhone,
                            onChanged: (value) {
                              if (value == null || pending || _approvalGranted) return;
                              setState(() {
                                _useRealPhone = value;
                                _statusBanner = null;
                              });
                            },
                            activeColor: const Color(0xFF00E676),
                            title: const Text('رقم فريد من CN CALL'),
                            subtitle: const Text('رقم عشوائي من 9 أرقام يبدأ بـ 79'),
                          ),
                          Divider(color: Colors.grey.shade800, height: 1),
                          RadioListTile<bool>(
                            value: true,
                            groupValue: _useRealPhone,
                            onChanged: (value) {
                              if (value == null || pending || _approvalGranted) return;
                              setState(() {
                                _useRealPhone = value;
                                _statusBanner = null;
                              });
                            },
                            activeColor: const Color(0xFF00E676),
                            title: const Text('استخدام رقم هاتفي الحقيقي'),
                            subtitle: const Text('يتطلب موافقة إدارة CN CALL قبل إنشاء الحساب'),
                          ),
                        ],
                      ),
                    ),
                    if (_useRealPhone) ...[
                      const SizedBox(height: 16),
                      _Field(
                        controller: userIdController,
                        label: 'رقم الهاتف الحقيقي',
                        hint: 'أدخل رقم هاتفك',
                        icon: Icons.phone_android_outlined,
                        keyboardType: TextInputType.phone,
                      ),
                    ],
                    const SizedBox(height: 16),
                    _Field(
                      controller: usernameController,
                      label: 'اسم المستخدم',
                      hint: 'الاسم الذي سيظهر للآخرين أثناء المكالمة',
                      icon: Icons.person_outline,
                    ),
                    const SizedBox(height: 16),
                    _Field(
                      controller: passwordController,
                      label: 'كلمة المرور',
                      hint: '6 أحرف على الأقل',
                      icon: Icons.lock_outline,
                      obscureText: hidePassword,
                      suffix: IconButton(
                        onPressed: () => setState(() => hidePassword = !hidePassword),
                        icon: Icon(hidePassword ? Icons.visibility_off : Icons.visibility),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _Field(
                      controller: confirmPasswordController,
                      label: 'تأكيد كلمة المرور',
                      hint: 'أعد كتابة كلمة المرور',
                      icon: Icons.lock_reset_outlined,
                      obscureText: hideConfirmPassword,
                      suffix: IconButton(
                        onPressed: () => setState(() => hideConfirmPassword = !hideConfirmPassword),
                        icon: Icon(hideConfirmPassword ? Icons.visibility_off : Icons.visibility),
                      ),
                    ),
                    if (_statusBanner != null) ...[
                      const SizedBox(height: 18),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E676).withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF00E676).withValues(alpha: .35)),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Icon(Icons.info_outline, color: Color(0xFF00E676)),
                            const SizedBox(width: 10),
                            Expanded(child: Text(_statusBanner!, style: const TextStyle(height: 1.4))),
                          ],
                        ),
                      ),
                    ],
                    if (pending && !_approvalGranted) ...[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E676).withValues(alpha: .08),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: const Color(0xFF00E676).withValues(alpha: .35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              'تأكيد رقم الهاتف',
                              style: TextStyle(
                                color: Color(0xFF00E676),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            const Text(
                              'اتصل أو أرسل رسالة إلى الرقم التالي من رقم الهاتف الذي سجّلته، ثم انتظر موافقة الإدارة.',
                              style: TextStyle(height: 1.4),
                            ),
                            const SizedBox(height: 10),
                            SelectableText(
                              _cnCallDeveloperPhone,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    _PrimaryButton(
                      text: _submitting
                          ? 'جارٍ التنفيذ...'
                          : pending
                              ? 'فحص حالة طلب الموافقة'
                              : _approvalGranted
                                  ? 'إكمال تسجيل الدخول'
                                  : _useRealPhone
                                      ? 'إرسال طلب الموافقة'
                                      : 'إنشاء الحساب والحصول على رقم',
                      onPressed: _submitting
                          ? () {}
                          : pending
                              ? _pollRegistrationStatus
                              : _approvalGranted
                                  ? _continueAfterApproval
                                  : createAccount,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text(
                        'لدي حساب بالفعل',
                        style: TextStyle(color: Color(0xFF00E676)),
                      ),
                    ),
                    const SizedBox(height: 20),
                    _Footer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SHARED UI
// ============================================================

class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 88,
      height: 88,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xFF00E676).withValues(alpha: .10),
        border: Border.all(color: const Color(0xFF00E676), width: 2),
      ),
      child: const Icon(Icons.call, size: 40, color: Color(0xFF00E676)),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final Widget? suffix;

  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textDirection: TextDirection.ltr,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon),
        suffixIcon: suffix,
        filled: true,
        fillColor: const Color(0xFF151515),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: const BorderSide(color: Color(0xFF00E676)),
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final String text;
  final VoidCallback onPressed;

  const _PrimaryButton({required this.text, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF00E676),
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'CAFEE NET',
          style: TextStyle(
            color: Colors.grey.shade800.withValues(alpha: .45),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 2.2,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          'هشام الريمي',
          style: TextStyle(
            color: Colors.grey.shade800.withValues(alpha: .35),
            fontSize: 9,
            fontWeight: FontWeight.w500,
            letterSpacing: .8,
          ),
        ),
      ],
    );
  }
}





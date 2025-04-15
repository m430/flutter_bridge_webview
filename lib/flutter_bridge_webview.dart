import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:uuid/uuid.dart';

typedef H5MessageHandler = Future<dynamic> Function(
  String action,
  dynamic payload,
);

abstract class FlutterBridgeWebViewController {
  Future<dynamic> sendMessageToH5(String action, [dynamic payload]);
  Future<void> reload();
}

class FlutterBridgeWebView extends StatefulWidget {
  final String initialUrl;
  final H5MessageHandler messageHandler;
  final String jsChannelName;
  final Function(FlutterBridgeWebViewController controller)?
      onWebViewCreated; // 修改回调参数类型
  final Function(int progress)? onProgress;
  final Function(String url)? onPageStarted;
  final Function(String url)? onPageFinished;
  final Function(WebResourceError error)? onWebResourceError;
  final NavigationDelegate? navigationDelegate;

  const FlutterBridgeWebView({
    super.key,
    required this.initialUrl,
    required this.messageHandler,
    this.jsChannelName = "FlutterBridge",
    this.onWebViewCreated,
    this.onProgress,
    this.onPageStarted,
    this.onPageFinished,
    this.onWebResourceError,
    this.navigationDelegate,
  });

  @override
  State<FlutterBridgeWebView> createState() => _FlutterBridgeWebViewState();
}

class _FlutterBridgeWebViewState extends State<FlutterBridgeWebView>
    implements FlutterBridgeWebViewController {
  late WebViewController _webViewController;
  bool _isWebViewLoading = true;
  final Uuid _uuid = const Uuid();
  final Map<String, Completer<dynamic>> _pendingH5Callbacks = {};

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  void _initializeWebView() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0x00000000))
      ..addJavaScriptChannel(
        widget.jsChannelName,
        onMessageReceived: _handleJavaScriptMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            widget.onProgress?.call(progress);
          },
          onPageStarted: (String url) {
            debugPrint('FlutterBridgeWebView: 页面开始加载: $url');
            if (mounted) {
              setState(() => _isWebViewLoading = true);
            }
            widget.onPageStarted?.call(url);
          },
          onPageFinished: (String url) {
            debugPrint('FlutterBridgeWebView: 页面加载完成: $url');
            if (mounted) {
              setState(() => _isWebViewLoading = false);
            }
            try {
              _webViewController.runJavaScript('''
                    if (window.${widget.jsChannelName} && typeof window.${widget.jsChannelName}.flutterSdkReady === "function") { 
                      window.${widget.jsChannelName}.flutterSdkReady();
                      console.log('flutter====>jsChannelName', typeof window.${widget.jsChannelName}.postMessage)
                    }
                  ''');
            } catch (e) {
              debugPrint('FlutterBridgeWebView: 调用 H5 flutterSdkReady 时出错: $e');
            }
            widget.onPageFinished?.call(url);
            widget.onWebViewCreated?.call(this);
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('FlutterBridgeWebView: 页面资源错误: ${error.description}');
            if (mounted) {
              setState(() => _isWebViewLoading = false);
            }
            widget.onWebResourceError?.call(error);
          },
          onNavigationRequest: widget.navigationDelegate?.onNavigationRequest ??
              (NavigationRequest request) {
                debugPrint('FlutterBridgeWebView: 允许导航到 ${request.url}');
                return NavigationDecision.navigate;
              },
        ),
      )
      ..loadRequest(Uri.parse(widget.initialUrl));
  }

  // --- 通信逻辑
  void _handleJavaScriptMessage(JavaScriptMessage message) {
    debugPrint("FlutterBridgeWebView: 收到 H5 消息: ${message.message}");
    try {
      final decodedMessage =
          jsonDecode(message.message) as Map<String, dynamic>;
      final String action = decodedMessage['action'] as String? ?? '';
      final dynamic payload = decodedMessage['payload'];
      final String? callbackId = decodedMessage['callbackId'] as String?;
      final bool isResponse = decodedMessage['isResponse'] as bool? ?? false;

      if (action.isEmpty) {
        debugPrint("FlutterBridgeWebView: 收到来自 H5 的空 action 消息。");
        return;
      }

      if (isResponse) {
        _handleH5Response(decodedMessage);
      } else {
        _handleH5Request(action, payload, callbackId);
      }
    } catch (e, s) {
      debugPrint("FlutterBridgeWebView: 解码/处理 H5 消息时出错: $e\n$s"); // 修改日志类名
    }
  }

  Future<void> _handleH5Request(
      String action, dynamic payload, String? callbackId) async {
    try {
      final result = await widget.messageHandler(action, payload);
      if (callbackId != null) {
        _sendResponseToH5(action, callbackId, true, result);
      }
    } catch (error, stackTrace) {
      debugPrint(
          "FlutterBridgeWebView: H5 消息处理器处理 action '$action' 时出错: $error\n$stackTrace"); // 修改日志类名
      if (callbackId != null) {
        _sendResponseToH5(action, callbackId, false, error.toString());
      }
    }
  }

  void _handleH5Response(Map<String, dynamic> responseMessage) {
    final String? callbackId = responseMessage['callbackId'] as String?;
    if (callbackId == null) {
      debugPrint("FlutterBridgeWebView: 收到 H5 响应但没有 callbackId。");
      return;
    }

    final completer = _pendingH5Callbacks.remove(callbackId);
    if (completer == null || completer.isCompleted) {
      debugPrint("FlutterBridgeWebView: 收到未知或已完成的 callbackId 的响应: $callbackId");
      return;
    }

    final bool success = responseMessage['success'] as bool? ?? false;
    final dynamic payload = responseMessage['payload'];
    final String? error = responseMessage['error'] as String?;

    if (success) {
      completer.complete(payload);
    } else {
      completer.completeError(Exception(error ?? "H5 操作失败，无具体错误信息。"));
    }
  }

  void _sendResponseToH5(
    String originalAction,
    String callbackId,
    bool success,
    dynamic dataOrError,
  ) {
    final responseMessage = {
      'action': originalAction,
      'callbackId': callbackId,
      'isResponse': true,
      'success': success,
      'payload': success ? dataOrError : null,
      'error': !success ? dataOrError.toString() : null,
    };
    _sendMessageToJs(responseMessage);
  }

  void _sendMessageToJs(Map<String, dynamic> message) {
    final jsonMessage = jsonEncode(message);
    final escapedJsonMessage = jsonMessage
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('"', '\\"')
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r');

    final jsCall = """
      if (window.FlutterBridgeJS && typeof window.FlutterBridgeJS.receiveMessage === 'function') {
        window.FlutterBridgeJS.receiveMessage('$escapedJsonMessage');
      } else {
        console.error('Flutter bridge or receiveMessage function not ready in H5.');
      }
    """;
    try {
      _webViewController.runJavaScript(jsCall).catchError((e) {
        debugPrint("FlutterBridgeWebView: 执行 JS 发送消息时捕获异步错误: $e"); // 修改日志类名
      });
    } catch (e) {
      debugPrint("FlutterBridgeWebView: 执行 JS 发送消息时捕获同步错误: $e"); // 修改日志类名
    }
    debugPrint("FlutterBridgeWebView: 发送消息到 H5: $jsonMessage"); // 修改日志类名
  }

  @override
  Future<dynamic> sendMessageToH5(String action, [dynamic payload]) {
    if (!mounted) {
      return Future.error(
          StateError("WebView is not mounted. Cannot send message."));
    }

    final callbackId = _uuid.v4();
    final completer = Completer<dynamic>();
    _pendingH5Callbacks[callbackId] = completer;

    final message = {
      'action': action,
      'payload': payload,
      'callbackId': callbackId,
      'isResponse': false,
    };

    _sendMessageToJs(message);

    // 设置超时
    return completer.future.timeout(const Duration(seconds: 3), onTimeout: () {
      _pendingH5Callbacks.remove(callbackId);
      throw TimeoutException("等待 H5 对 action '$action' 的响应超时");
    }).catchError((e) {
      _pendingH5Callbacks.remove(callbackId);
      throw e;
    });
  }

  @override
  Future<void> reload() {
    if (!mounted) {
      return Future.error(StateError("WebView is not mounted. Cannot reload."));
    }
    try {
      return _webViewController.reload();
    } catch (e) {
      return Future.error(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        WebViewWidget(controller: _webViewController),
        if (_isWebViewLoading)
          const Positioned.fill(
            child: Center(
              child: CircularProgressIndicator(),
            ),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _pendingH5Callbacks.forEach((key, completer) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(
            'WebView disposed before H5 response received for callbackId: $key'));
      }
    });
    _pendingH5Callbacks.clear();
    // 注意：WebViewController 的 dispose 是由 WebViewWidget 自动管理的，通常不需要手动调用
    super.dispose();
  }
}

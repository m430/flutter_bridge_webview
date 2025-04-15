# Flutter Bridge WebView

基于webview_flutter的Flutter WebView插件，支持iOS和Android平台, 支持通过[flutter-bridge-js](https://github.com/m430/flutter-bridge-js)进行双向通信。


## Getting started

## Usage

### 1. 初始化

1. 在Flutter项目中进行初始化：

```dart
// webview控制器
FlutterBridgeWebViewController? _bridgeController;

FlutterBridgeWebView(
  // 初始化H5地址
  initialUrl: h5Url,
  // 处理H5中js发送过来的消息
  messageHandler: _handleH5Message,
  onWebViewCreated: (controller) {
    setState(() {
      _bridgeController = controller; // 保存控制器引用
    });
  },
),
```
1. 完成H5中JS-SDK的初始化，参考[flutter-bridge-js](URL_ADDRESS.com/m430/flutter-bridge-js)。

## 2. 发送消息给H5

```dart
// 发送消息给H5
_bridgeController?.sendMessageToH5('action', [dynamic payload]);
```